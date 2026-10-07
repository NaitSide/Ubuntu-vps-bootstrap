#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

readonly PROJECT_NAME="Ubuntu VPS Bootstrap"
readonly LOG_FILE="/var/log/ubuntu-vps-bootstrap.log"
readonly STATE_FILE="/etc/ubuntu-vps-bootstrap.conf"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly MANAGED_SSH_CONFIG="$SSHD_DROPIN_DIR/00-ubuntu-vps-bootstrap.conf"
readonly CLOUD_INIT_CONFIG="/etc/cloud/cloud.cfg.d/99-zz-ubuntu-vps-bootstrap-hostname.cfg"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-ubuntu-vps-bootstrap.conf"

exec 3>&1 4>&2

TEMP_KEY_FILE=""
LOGGING_STARTED="no"
INSTALL_COMPLETE="no"

ui() {
    printf '%s\n' "$*" >&3
}

fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    if [ "$LOGGING_STARTED" = "yes" ]; then
        printf 'Ошибка: %s\n' "$*" >&3
    fi
    return 1
}

cleanup() {
    local exit_code="$?"
    trap - EXIT

    if [ -n "$TEMP_KEY_FILE" ]; then
        rm -f "$TEMP_KEY_FILE"
    fi

    if [ "$exit_code" -ne 0 ] && [ "$INSTALL_COMPLETE" != "yes" ]; then
        ui
        ui "============================================================"
        ui "❌ Настройка VPS не завершена."
        if [ "$LOGGING_STARTED" = "yes" ]; then
            ui "Подробности: $LOG_FILE"
        fi
        ui "============================================================"
        ui
    fi

    exit "$exit_code"
}

trap cleanup EXIT

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "не найдена обязательная команда '$1'."
}

validate_hostname() {
    local value="$1"
    local label='[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'

    [ "${#value}" -le 64 ] && [[ "$value" =~ ^${label}(\.${label})*$ ]]
}

validate_username() {
    local value="$1"
    [ "$value" != "root" ] && [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_port_number() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1024 ] && [ "$value" -le 65535 ]
}

port_is_listening() {
    local port="$1"
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
}

generate_ssh_port() {
    local candidate
    for _attempt in $(seq 1 200); do
        candidate="$(shuf -i 20000-29999 -n 1)"
        if ! port_is_listening "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

validate_timezone() {
    local value="$1"
    if [ "$value" = "UTC" ]; then
        return 0
    fi
    [[ "$value" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] &&
        [ -f "/usr/share/zoneinfo/$value" ]
}

validate_public_key() {
    local key="$1"

    if [[ "$key" == *"PRIVATE KEY"* ]]; then
        fail "обнаружен приватный ключ. Вставьте только открытую часть ключа."
        return 1
    fi

    if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
        fail "открытый SSH-ключ имеет неподдерживаемый формат."
        return 1
    fi

    printf '%s\n' "$key" > "$TEMP_KEY_FILE"
    chmod 0600 "$TEMP_KEY_FILE"
    ssh-keygen -l -f "$TEMP_KEY_FILE" >/dev/null 2>&1 || {
        fail "ssh-keygen не смог прочитать открытый ключ."
        return 1
    }
}

read_existing_managed_port() {
    local port=""
    if [ -f "$MANAGED_SSH_CONFIG" ]; then
        port="$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$MANAGED_SSH_CONFIG")"
    fi
    if validate_port_number "$port"; then
        printf '%s' "$port"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    fail "запустите Bootstrap от root или через sudo."
    exit 1
fi

if [ ! -r /dev/tty ]; then
    fail "не найден интерактивный терминал /dev/tty."
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    fail "не удалось определить операционную систему."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
    fail "поддерживается только Ubuntu. Обнаружено: ${PRETTY_NAME:-неизвестная система}."
    exit 1
fi

if [ "${VERSION_ID:-}" != "24.04" ]; then
    ui
    ui "************************************************************"
    ui "⚠️ Обнаружена ${PRETTY_NAME:-Ubuntu неизвестной версии}."
    ui "Скрипт не тестировался на этой версии Ubuntu."
    ui "Рекомендуемая версия: Ubuntu 24.04 LTS."
    ui "************************************************************"
    ui

    read -r -p "Продолжить? [y/N]: " OS_CONFIRM </dev/tty
    case "$(trim "$OS_CONFIRM")" in
        y|Y|yes|YES|Yes|д|Д|да|ДА|Да) ;;
        *)
            ui "Настройка отменена. Изменения не применялись."
            exit 0
            ;;
    esac
fi

for required_command in awk grep sed sort mktemp hostname hostnamectl getent systemctl \
    timedatectl ssh-keygen shuf seq ss useradd usermod passwd visudo apt-get install \
    modprobe sysctl date; do
    require_command "$required_command"
done

if ! getent group sudo >/dev/null 2>&1; then
    fail "в системе отсутствует группа sudo."
    exit 1
fi

CURRENT_HOSTNAME="$(hostname)"
DEFAULT_HOSTNAME="${CURRENT_HOSTNAME%%.*}"
read -r -p "Введите hostname [${DEFAULT_HOSTNAME}]: " NEW_HOSTNAME </dev/tty
NEW_HOSTNAME="$(trim "${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}")"
if ! validate_hostname "$NEW_HOSTNAME"; then
    fail "hostname должен состоять из DNS-меток и содержать не более 64 символов."
    exit 1
fi

read -r -p "Введите имя пользователя: " NEW_USER </dev/tty
NEW_USER="$(trim "$NEW_USER")"
if [ -z "$NEW_USER" ]; then
    fail "имя пользователя не может быть пустым."
    exit 1
fi
if ! validate_username "$NEW_USER"; then
    fail "имя пользователя должно начинаться с маленькой буквы или '_' и содержать только a-z, 0-9, '_', '-'."
    exit 1
fi

USER_EXISTS="no"
if id "$NEW_USER" >/dev/null 2>&1; then
    USER_EXISTS="yes"
    EXISTING_UID="$(id -u "$NEW_USER")"
    if [ "$EXISTING_UID" -lt 1000 ] || [ "$EXISTING_UID" -ge 60000 ]; then
        fail "существующий пользователь '$NEW_USER' является системной учётной записью. Выберите другое имя."
        exit 1
    fi
fi

TEMP_KEY_FILE="$(mktemp)"
ui
ui "Вставьте открытый SSH-ключ одной строкой."
ui "Обычно он начинается с ssh-ed25519, ecdsa-... или ssh-rsa."
ui "Никогда не вставляйте сюда приватный ключ."
read -r -p "Открытый SSH-ключ: " SSH_PUBLIC_KEY </dev/tty
SSH_PUBLIC_KEY="$(trim "$SSH_PUBLIC_KEY")"
if [ -z "$SSH_PUBLIC_KEY" ] || ! validate_public_key "$SSH_PUBLIC_KEY"; then
    exit 1
fi
SSH_KEY_FINGERPRINT="$(ssh-keygen -l -f "$TEMP_KEY_FILE" | awk '{print $2 " (" $4 ")"}')"

EXISTING_MANAGED_PORT="$(read_existing_managed_port || true)"
if [ -n "$EXISTING_MANAGED_PORT" ]; then
    DEFAULT_SSH_PORT="$EXISTING_MANAGED_PORT"
else
    DEFAULT_SSH_PORT="$(generate_ssh_port)" || {
        fail "не удалось подобрать свободный SSH-порт."
        exit 1
    }
fi

read -r -p "Введите SSH-порт [${DEFAULT_SSH_PORT}]: " SSH_PORT </dev/tty
SSH_PORT="$(trim "${SSH_PORT:-$DEFAULT_SSH_PORT}")"
if ! validate_port_number "$SSH_PORT"; then
    fail "SSH-порт должен быть целым числом от 1024 до 65535."
    exit 1
fi
if port_is_listening "$SSH_PORT" && [ "$SSH_PORT" != "$EXISTING_MANAGED_PORT" ]; then
    fail "порт $SSH_PORT уже занят другим процессом."
    exit 1
fi

read -r -p "Введите часовой пояс [Europe/Moscow]: " TIMEZONE </dev/tty
TIMEZONE="$(trim "${TIMEZONE:-Europe/Moscow}")"
if ! validate_timezone "$TIMEZONE"; then
    fail "часовой пояс '$TIMEZONE' не найден. Список: timedatectl list-timezones"
    exit 1
fi

ui
ui "============================================================"
ui "Будут применены следующие настройки:"
ui
ui "Hostname:           $NEW_HOSTNAME"
ui "Пользователь:       $NEW_USER"
if [ "$USER_EXISTS" = "yes" ]; then
    ui "                    существующий authorized_keys будет заменён"
fi
ui "SSH-ключ:           $SSH_KEY_FINGERPRINT"
ui "SSH-порт:           $SSH_PORT"
ui "Часовой пояс:       $TIMEZONE"
ui "Вход под root:      будет отключён"
ui "Вход по паролю:     будет отключён"
ui "Авторизация:        только SSH-ключ"
ui "UFW:                будет включён"
ui "Fail2ban:           будет включён"
ui "BBR:                будет включён"
ui "============================================================"

read -r -p "Применить указанные настройки? [y/N]: " CONFIRM </dev/tty
case "$(trim "$CONFIRM")" in
    y|Y|yes|YES|Yes|д|Д|да|ДА|Да) ;;
    *)
        ui "Настройка отменена. Изменения не применялись."
        exit 0
        ;;
esac

install -o root -g root -m 0600 /dev/null "$LOG_FILE"
LOGGING_STARTED="yes"
{
    printf '=== %s ===\n' "$PROJECT_NAME"
    printf 'Запуск: %s\n' "$(date --iso-8601=seconds)"
    printf 'Система: %s\n' "${PRETTY_NAME:-Ubuntu}"
    printf 'Hostname: %s\n' "$NEW_HOSTNAME"
    printf 'Пользователь: %s\n' "$NEW_USER"
    printf 'Fingerprint ключа: %s\n' "$SSH_KEY_FINGERPRINT"
    printf 'SSH-порт: %s\n' "$SSH_PORT"
    printf 'Часовой пояс: %s\n\n' "$TIMEZONE"
} >> "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

ui
ui "🚀 $PROJECT_NAME"
ui
ui "[1/7] Проверка системы..."

ui "[2/7] Настройка hostname..."

if [ -d /etc/cloud ]; then
    install -d -o root -g root -m 0755 /etc/cloud/cloud.cfg.d
    cat > "$CLOUD_INIT_CONFIG" <<'EOF'
# Hostname и /etc/hosts управляются Ubuntu VPS Bootstrap.
preserve_hostname: true
manage_etc_hosts: false
EOF
    chmod 0644 "$CLOUD_INIT_CONFIG"
fi

update_hostname_hosts() {
    local hosts_file="$1" temp_file
    temp_file="$(mktemp)"

    if ! awk -v new_name="$NEW_HOSTNAME" -v old_name="$CURRENT_HOSTNAME" '
        function remember(name) {
            name = tolower(name)
            obsolete[name] = 1
            sub(/\..*$/, "", name)
            obsolete[name] = 1
        }
        BEGIN {
            remember(old_name); remember(new_name)
            seen[tolower(new_name)] = 1
            short_name = new_name
            sub(/\..*$/, "", short_name)
            seen[tolower(short_name)] = 1
        }
        NR == FNR {
            sub(/#.*/, "")
            if ($1 == "127.0.1.1" && NF >= 2 && $2 !~ /^#/) remember($2)
            next
        }
        $1 != "127.0.1.1" { print; next }
        {
            comment = index($0, "#")
            if (comment) {
                print substr($0, comment)
                $0 = substr($0, 1, comment - 1)
            }
            for (i = 2; i <= NF; i++) {
                key = tolower($i)
                if ((!(key in obsolete) || key ~ /^(localhost|localhost\.localdomain|ip6-localhost|ip6-loopback)$/) && !seen[key]++)
                    aliases = aliases " " $i
            }
        }
        END {
            printf "127.0.1.1\t%s", new_name
            if (short_name != new_name) printf " %s", short_name
            print aliases
        }
    ' "$hosts_file" "$hosts_file" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    cat "$temp_file" > "$hosts_file"
    rm -f "$temp_file"
}

update_hostname_hosts /etc/hosts
hostnamectl --static --transient set-hostname "$NEW_HOSTNAME"
if [ "$(hostname)" != "$NEW_HOSTNAME" ] || [ "$(cat /etc/hostname)" != "$NEW_HOSTNAME" ] ||
    ! getent -s files hosts "$NEW_HOSTNAME" >/dev/null || ! getent hosts "$NEW_HOSTNAME" >/dev/null; then
    fail "hostname или его локальное разрешение не соответствует '$NEW_HOSTNAME'."
    exit 1
fi

ui "[3/7] Создание пользователя и установка SSH-ключа..."

if [ "$USER_EXISTS" != "yes" ]; then
    useradd -m -s /bin/bash "$NEW_USER"
else
    usermod -s /bin/bash "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"
passwd -l "$NEW_USER" >/dev/null 2>&1 || true

SUDOERS_FILE="/etc/sudoers.d/90-ubuntu-vps-bootstrap-$NEW_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$NEW_USER" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ "$USER_HOME" = "/" ]; then
    fail "не удалось определить домашний каталог пользователя '$NEW_USER'."
    exit 1
fi

SSH_DIR="$USER_HOME/.ssh"
install -d -o "$NEW_USER" -g "$NEW_USER" -m 0700 "$SSH_DIR"
install -o "$NEW_USER" -g "$NEW_USER" -m 0600 "$TEMP_KEY_FILE" "$SSH_DIR/authorized_keys"

ui "[4/7] Установка системных пакетов..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq \
    openssh-server fail2ban ufw iproute2 sudo

ui "[5/7] Настройка SSH..."

# Служебный скрипт применяет SSH, UFW и Fail2ban с автоматическим откатом.
cat > /usr/local/sbin/vps-bootstrap-apply <<'VPS_BOOTSTRAP_APPLY'
#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

SSH_PORT="${SSH_PORT:?SSH_PORT is required}"
NEW_USER="${NEW_USER:?NEW_USER is required}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
MANAGED_SSH_CONFIG="$SSHD_DROPIN_DIR/00-ubuntu-vps-bootstrap.conf"
FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/99-ubuntu-vps-bootstrap.local"

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запустите скрипт от root." >&2
    exit 1
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Ошибка: некорректный SSH-порт '$SSH_PORT'." >&2
    exit 1
fi

SSHD_BIN="$(command -v sshd || true)"
if [ -z "$SSHD_BIN" ]; then
    echo "Ошибка: команда sshd не найдена." >&2
    exit 1
fi

install -d -o root -g root -m 0755 /run/sshd

if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE="ssh.service"
elif systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE="sshd.service"
else
    echo "Ошибка: systemd-служба SSH не найдена." >&2
    exit 1
fi

SSH_SOCKET_UNIT=""
for unit in ssh.socket sshd.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        SSH_SOCKET_UNIT="$unit"
        break
    fi
done

SSH_SERVICE_WAS_ACTIVE="no"
SSH_SERVICE_WAS_ENABLED="no"
if systemctl is-active --quiet "$SSH_SERVICE"; then
    SSH_SERVICE_WAS_ACTIVE="yes"
fi
if systemctl is-enabled --quiet "$SSH_SERVICE"; then
    SSH_SERVICE_WAS_ENABLED="yes"
fi

SSH_SOCKET_WAS_ACTIVE="no"
SSH_SOCKET_WAS_ENABLED="no"
if [ -n "$SSH_SOCKET_UNIT" ]; then
    systemctl is-active --quiet "$SSH_SOCKET_UNIT" && SSH_SOCKET_WAS_ACTIVE="yes"
    systemctl is-enabled --quiet "$SSH_SOCKET_UNIT" && SSH_SOCKET_WAS_ENABLED="yes"
fi

FAIL2BAN_WAS_ACTIVE="no"
FAIL2BAN_WAS_ENABLED="no"
if systemctl is-active --quiet fail2ban; then
    FAIL2BAN_WAS_ACTIVE="yes"
fi
if systemctl is-enabled --quiet fail2ban; then
    FAIL2BAN_WAS_ENABLED="yes"
fi

ROLLBACK_DIR="$(mktemp -d /run/ubuntu-vps-bootstrap.XXXXXX)"
BACKUP_READY="no"
APPLY_OK="no"
UFW_WAS_ACTIVE="no"

rollback() {
    local exit_code="$1"

    if [ "$APPLY_OK" = "yes" ]; then
        rm -rf "$ROLLBACK_DIR"
        return 0
    fi

    if [ "$BACKUP_READY" != "yes" ]; then
        rm -rf "$ROLLBACK_DIR"
        return "$exit_code"
    fi

    trap - EXIT
    set +e
    echo "Ошибка: настройка SSH не завершена. Восстанавливаем исходное состояние..." >&2

    cp -a "$ROLLBACK_DIR/sshd_config" "$SSHD_CONFIG"
    rm -rf "$SSHD_DROPIN_DIR"
    if [ -d "$ROLLBACK_DIR/sshd_config.d" ]; then
        cp -a "$ROLLBACK_DIR/sshd_config.d" "$SSHD_DROPIN_DIR"
    else
        mkdir -p "$SSHD_DROPIN_DIR"
    fi

    if [ -d "$ROLLBACK_DIR/ufw" ]; then
        rm -rf /etc/ufw
        cp -a "$ROLLBACK_DIR/ufw" /etc/ufw
    fi
    if [ -d "$ROLLBACK_DIR/fail2ban-jail.d" ]; then
        rm -rf /etc/fail2ban/jail.d
        cp -a "$ROLLBACK_DIR/fail2ban-jail.d" /etc/fail2ban/jail.d
    fi

    if [ -n "$SSH_SOCKET_UNIT" ]; then
        if [ "$SSH_SOCKET_WAS_ENABLED" = "yes" ]; then
            systemctl enable "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
        else
            systemctl disable "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
        fi

        if [ "$SSH_SOCKET_WAS_ACTIVE" = "yes" ]; then
            systemctl stop "$SSH_SERVICE" >/dev/null 2>&1 || true
            systemctl start "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
        else
            systemctl stop "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
            if [ "$SSH_SERVICE_WAS_ACTIVE" = "yes" ]; then
                "$SSHD_BIN" -t >/dev/null 2>&1 || true
                systemctl restart "$SSH_SERVICE" >/dev/null 2>&1 || true
            else
                systemctl stop "$SSH_SERVICE" >/dev/null 2>&1 || true
            fi
        fi
    else
        if [ "$SSH_SERVICE_WAS_ACTIVE" = "yes" ]; then
            "$SSHD_BIN" -t >/dev/null 2>&1 || true
            systemctl restart "$SSH_SERVICE" >/dev/null 2>&1 || true
        else
            systemctl stop "$SSH_SERVICE" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$SSH_SERVICE_WAS_ENABLED" = "yes" ]; then
        systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
    else
        systemctl disable "$SSH_SERVICE" >/dev/null 2>&1 || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        if [ "$UFW_WAS_ACTIVE" = "yes" ]; then
            ufw --force enable >/dev/null 2>&1 || true
            ufw --force reload >/dev/null 2>&1 || true
        else
            ufw --force disable >/dev/null 2>&1 || true
        fi
    fi

    if [ "$FAIL2BAN_WAS_ENABLED" = "yes" ]; then
        systemctl enable fail2ban >/dev/null 2>&1 || true
    else
        systemctl disable fail2ban >/dev/null 2>&1 || true
    fi
    if [ "$FAIL2BAN_WAS_ACTIVE" = "yes" ]; then
        systemctl restart fail2ban >/dev/null 2>&1 || true
    else
        systemctl stop fail2ban >/dev/null 2>&1 || true
    fi
    rm -rf "$ROLLBACK_DIR"
    echo "Исходное состояние восстановлено." >&2
    exit "$exit_code"
}

trap 'rollback $?' EXIT

cp -a "$SSHD_CONFIG" "$ROLLBACK_DIR/sshd_config"
if [ -d "$SSHD_DROPIN_DIR" ]; then
    cp -a "$SSHD_DROPIN_DIR" "$ROLLBACK_DIR/sshd_config.d"
fi
if [ -d /etc/ufw ]; then
    cp -a /etc/ufw "$ROLLBACK_DIR/ufw"
fi
if [ -d /etc/fail2ban/jail.d ]; then
    cp -a /etc/fail2ban/jail.d "$ROLLBACK_DIR/fail2ban-jail.d"
fi
if ufw status 2>/dev/null | grep -q '^Status: active'; then
    UFW_WAS_ACTIVE="yes"
fi
BACKUP_READY="yes"

OLD_SSH_PORT=""
if [ -f "$MANAGED_SSH_CONFIG" ]; then
    OLD_SSH_PORT="$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$MANAGED_SSH_CONFIG")"
fi

clean_ssh_config_file() {
    local file="$1" temp_file
    temp_file="$(mktemp)"

    if ! awk -v source_file="$file" '
        function managed(key) {
            return key ~ /^(port|listenaddress|permitrootlogin|permitemptypasswords|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|authenticationmethods|hostbasedauthentication|gssapiauthentication)$/
        }
        BEGIN { inside_match = 0 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        {
            key = tolower($1)
            if (key == "match") {
                inside_match = 1
                print
                next
            }
            if (inside_match && (managed(key) || key == "include")) {
                printf "Ошибка: управляемый параметр найден в Match-блоке: %s:%d\n", source_file, FNR > "/dev/stderr"
                exit 42
            }
            if (!inside_match && managed(key)) next
            print
        }
    ' "$file" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    cat "$temp_file" > "$file"
    rm -f "$temp_file"
}

normalize_dropin_include() {
    local temp_file
    temp_file="$(mktemp)"
    {
        echo "Include /etc/ssh/sshd_config.d/*.conf"
        echo
        awk '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
            {
                key = tolower($1)
                if (key != "include") { print; next }
                output = ""
                for (i = 2; i <= NF; i++) {
                    token = $i
                    normalized = token
                    gsub(/^"|"$/, "", normalized)
                    if (normalized == "/etc/ssh/sshd_config.d/*.conf") continue
                    output = output == "" ? token : output " " token
                }
                if (output != "") print "Include " output
            }
        ' "$SSHD_CONFIG"
    } > "$temp_file"
    cat "$temp_file" > "$SSHD_CONFIG"
    rm -f "$temp_file"
}

mkdir -p "$SSHD_DROPIN_DIR"
clean_ssh_config_file "$SSHD_CONFIG"

shopt -s nullglob
for config_file in "$SSHD_DROPIN_DIR"/*.conf; do
    [ "$config_file" = "$MANAGED_SSH_CONFIG" ] && continue
    clean_ssh_config_file "$config_file"
    if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$config_file"; then
        rm -f "$config_file"
    fi
done
shopt -u nullglob

normalize_dropin_include

cat > "$MANAGED_SSH_CONFIG" <<EOF
# SSH policy managed by Ubuntu VPS Bootstrap
Port $SSH_PORT
PermitRootLogin no
PermitEmptyPasswords no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
HostbasedAuthentication no
GSSAPIAuthentication no
EOF
chmod 0644 "$MANAGED_SSH_CONFIG"

"$SSHD_BIN" -t

GLOBAL_EFFECTIVE="$ROLLBACK_DIR/sshd-global.txt"
CONTEXT_EFFECTIVE="$ROLLBACK_DIR/sshd-context.txt"
"$SSHD_BIN" -T > "$GLOBAL_EFFECTIVE"
"$SSHD_BIN" -T -C "user=$NEW_USER,host=$(hostname),addr=127.0.0.1,laddr=127.0.0.1,lport=$SSH_PORT" > "$CONTEXT_EFFECTIVE"

assert_effective_value() {
    local file="$1" key="$2" expected="$3" actual
    actual="$(awk -v key="$key" '$1 == key {print $2; exit}' "$file")"
    if [ "$actual" != "$expected" ]; then
        echo "Ошибка: $key='$actual', ожидалось '$expected'." >&2
        return 1
    fi
}

for effective_file in "$GLOBAL_EFFECTIVE" "$CONTEXT_EFFECTIVE"; do
    assert_effective_value "$effective_file" permitrootlogin no
    assert_effective_value "$effective_file" permitemptypasswords no
    assert_effective_value "$effective_file" pubkeyauthentication yes
    assert_effective_value "$effective_file" passwordauthentication no
    assert_effective_value "$effective_file" kbdinteractiveauthentication no
    assert_effective_value "$effective_file" authenticationmethods publickey
    assert_effective_value "$effective_file" hostbasedauthentication no
    assert_effective_value "$effective_file" gssapiauthentication no
done

mapfile -t EFFECTIVE_PORTS < <(awk '$1 == "port" {print $2}' "$GLOBAL_EFFECTIVE" | sort -u)
if [ "${#EFFECTIVE_PORTS[@]}" -ne 1 ] || [ "${EFFECTIVE_PORTS[0]:-}" != "$SSH_PORT" ]; then
    echo "Ошибка: итоговые SSH-порты: ${EFFECTIVE_PORTS[*]:-не определены}." >&2
    exit 1
fi

while read -r listen_address; do
    [ -z "$listen_address" ] && continue
    case "$listen_address" in
        *:"$SSH_PORT") ;;
        *)
            echo "Ошибка: ListenAddress использует другой порт: $listen_address" >&2
            exit 1
            ;;
    esac
done < <(awk '$1 == "listenaddress" {print $2}' "$GLOBAL_EFFECTIVE")

mkdir -p "$(dirname "$FAIL2BAN_CONFIG")"
cat > "$FAIL2BAN_CONFIG" <<EOF
# SSH protection managed by Ubuntu VPS Bootstrap
[sshd]
enabled = true
port = $SSH_PORT
EOF
chmod 0644 "$FAIL2BAN_CONFIG"
fail2ban-client -t >/dev/null 2>&1

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT/tcp" comment "Ubuntu VPS Bootstrap SSH" >/dev/null
ufw --force enable >/dev/null

if [ -n "$SSH_SOCKET_UNIT" ] && { systemctl is-active --quiet "$SSH_SOCKET_UNIT" || systemctl is-enabled --quiet "$SSH_SOCKET_UNIT"; }; then
    systemctl stop "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
    systemctl disable "$SSH_SOCKET_UNIT" >/dev/null 2>&1 || true
fi

systemctl enable "$SSH_SERVICE" >/dev/null 2>&1
systemctl restart "$SSH_SERVICE"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

FAIL2BAN_READY="no"
for _attempt in $(seq 1 10); do
    if fail2ban-client status sshd >/dev/null 2>&1; then
        FAIL2BAN_READY="yes"
        break
    fi
    sleep 0.5
done
if [ "$FAIL2BAN_READY" != "yes" ]; then
    echo "Ошибка: Fail2ban не запустил jail sshd." >&2
    exit 1
fi

ACTIVE_SSH_PORTS=()
for _attempt in $(seq 1 10); do
    mapfile -t ACTIVE_SSH_PORTS < <(
        ss -lntpH 2>/dev/null \
            | awk '$0 ~ /sshd/ {print $4}' \
            | sed -E 's/^.*:([0-9]+)$/\1/' \
            | sort -u
    )
    if [ "${#ACTIVE_SSH_PORTS[@]}" -eq 1 ] && [ "${ACTIVE_SSH_PORTS[0]:-}" = "$SSH_PORT" ]; then
        break
    fi
    sleep 0.5
done

if [ "${#ACTIVE_SSH_PORTS[@]}" -ne 1 ] || [ "${ACTIVE_SSH_PORTS[0]:-}" != "$SSH_PORT" ]; then
    echo "Ошибка: sshd фактически слушает: ${ACTIVE_SSH_PORTS[*]:-ничего}." >&2
    exit 1
fi

# Старые правила удаляются только после успешного запуска SSH на новом порту.
ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
if [ "$SSH_PORT" != "22" ]; then
    ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
fi
if [[ "$OLD_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$OLD_SSH_PORT" != "$SSH_PORT" ] && [ "$OLD_SSH_PORT" != "22" ]; then
    ufw --force delete allow "$OLD_SSH_PORT/tcp" >/dev/null 2>&1 || true
fi
ufw --force reload >/dev/null

systemctl is-active --quiet "$SSH_SERVICE"
systemctl is-active --quiet fail2ban
ufw status | grep -q '^Status: active'

APPLY_OK="yes"
VPS_BOOTSTRAP_APPLY
chmod 0755 /usr/local/sbin/vps-bootstrap-apply

# Команда аудита читает выбранные значения из безопасного state-файла.
cat > /usr/local/sbin/vps-bootstrap-audit <<'VPS_BOOTSTRAP_AUDIT'
#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

STATE_FILE="/etc/ubuntu-vps-bootstrap.conf"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
MANAGED_SSH_CONFIG="$SSHD_DROPIN_DIR/00-ubuntu-vps-bootstrap.conf"
DETAILS="no"

case "${1:-}" in
    "") ;;
    --details) DETAILS="yes" ;;
    -h|--help)
        echo "Использование: sudo vps-bootstrap-audit [--details]"
        echo "  без параметров  — краткий аудит"
        echo "  --details       — полный технический отчёт"
        exit 0
        ;;
    *)
        echo "Ошибка: неизвестный параметр '$1'." >&2
        echo "Использование: sudo vps-bootstrap-audit [--details]" >&2
        exit 2
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запустите аудит через sudo." >&2
    exit 1
fi

if [ ! -r "$STATE_FILE" ]; then
    echo "Ошибка: не найден state-файл $STATE_FILE." >&2
    exit 1
fi

SSH_PORT="$(awk -F= '$1 == "SSH_PORT" {print $2; exit}' "$STATE_FILE")"
NEW_USER="$(awk -F= '$1 == "ADMIN_USER" {print $2; exit}' "$STATE_FILE")"
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Ошибка: state-файл содержит некорректные значения." >&2
    exit 1
fi

SSHD_BIN="$(command -v sshd || true)"
if [ -z "$SSHD_BIN" ]; then
    echo "Ошибка: команда sshd не найдена." >&2
    exit 1
fi

SSH_SERVICE=""
for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        SSH_SERVICE="$unit"
        break
    fi
done

SSH_SOCKET_UNIT=""
for unit in ssh.socket sshd.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        SSH_SOCKET_UNIT="$unit"
        break
    fi
done

ERRORS=0
SYNTAX_OK="no"
if "$SSHD_BIN" -t >/dev/null 2>&1; then
    SYNTAX_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

GLOBAL_EFFECTIVE=""
CONTEXT_EFFECTIVE=""
if [ "$SYNTAX_OK" = "yes" ]; then
    GLOBAL_EFFECTIVE="$($SSHD_BIN -T)"
    CONTEXT_EFFECTIVE="$($SSHD_BIN -T -C "user=$NEW_USER,host=$(hostname),addr=127.0.0.1,laddr=127.0.0.1,lport=$SSH_PORT")"
fi

get_value() {
    local source="$1" key="$2"
    printf '%s\n' "$source" | awk -v key="$key" '$1 == key {print $2; exit}'
}

mapfile -t EFFECTIVE_PORTS < <(
    printf '%s\n' "$GLOBAL_EFFECTIVE" | awk '$1 == "port" {print $2}' | sort -u
)
mapfile -t ACTIVE_SSH_PORTS < <(
    ss -lntpH 2>/dev/null \
        | awk '$0 ~ /sshd/ {print $4}' \
        | sed -E 's/^.*:([0-9]+)$/\1/' \
        | sort -u
)

CONFIG_FILE_OK="no"
if [ -f "$MANAGED_SSH_CONFIG" ]; then
    CONFIG_FILE_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

SSH_SERVICE_STATE="not-found"
SSH_SERVICE_ENABLED="not-found"
SSH_SERVICE_OK="no"
if [ -n "$SSH_SERVICE" ]; then
    SSH_SERVICE_STATE="$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)"
    SSH_SERVICE_ENABLED="$(systemctl is-enabled "$SSH_SERVICE" 2>/dev/null || true)"
    if [ "$SSH_SERVICE_STATE" = "active" ] && [[ "$SSH_SERVICE_ENABLED" == enabled* ]]; then
        SSH_SERVICE_OK="yes"
    else
        ERRORS=$((ERRORS + 1))
    fi
else
    ERRORS=$((ERRORS + 1))
fi

SSH_SOCKET_STATE="not-installed"
SSH_SOCKET_ENABLED="not-installed"
SSH_SOCKET_OK="yes"
if [ -n "$SSH_SOCKET_UNIT" ]; then
    SSH_SOCKET_STATE="$(systemctl is-active "$SSH_SOCKET_UNIT" 2>/dev/null || true)"
    SSH_SOCKET_ENABLED="$(systemctl is-enabled "$SSH_SOCKET_UNIT" 2>/dev/null || true)"
    if [ "$SSH_SOCKET_STATE" = "active" ] || [[ "$SSH_SOCKET_ENABLED" == enabled* ]]; then
        SSH_SOCKET_OK="no"
        ERRORS=$((ERRORS + 1))
    fi
fi

EFFECTIVE_PORT_OK="no"
if [ "${#EFFECTIVE_PORTS[@]}" -eq 1 ] && [ "${EFFECTIVE_PORTS[0]:-}" = "$SSH_PORT" ]; then
    EFFECTIVE_PORT_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

ACTIVE_PORT_OK="no"
if [ "${#ACTIVE_SSH_PORTS[@]}" -eq 1 ] && [ "${ACTIVE_SSH_PORTS[0]:-}" = "$SSH_PORT" ]; then
    ACTIVE_PORT_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

ROOT_LOGIN_OK="$([ "$(get_value "$CONTEXT_EFFECTIVE" permitrootlogin)" = "no" ] && echo yes || echo no)"
PASSWORD_LOGIN_OK="$([ "$(get_value "$CONTEXT_EFFECTIVE" passwordauthentication)" = "no" ] && echo yes || echo no)"
KEYBOARD_LOGIN_OK="$([ "$(get_value "$CONTEXT_EFFECTIVE" kbdinteractiveauthentication)" = "no" ] && echo yes || echo no)"
AUTH_METHOD_OK="$([ "$(get_value "$CONTEXT_EFFECTIVE" authenticationmethods)" = "publickey" ] && echo yes || echo no)"
for check in "$ROOT_LOGIN_OK" "$PASSWORD_LOGIN_OK" "$KEYBOARD_LOGIN_OK" "$AUTH_METHOD_OK"; do
    [ "$check" = "yes" ] || ERRORS=$((ERRORS + 1))
done

UFW_OK="no"
if ufw status 2>/dev/null | grep -q '^Status: active' &&
    ufw status 2>/dev/null | grep -Eq "^${SSH_PORT}/tcp[[:space:]]+ALLOW"; then
    UFW_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

FAIL2BAN_OK="no"
if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    FAIL2BAN_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

BBR_OK="no"
if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = "bbr" ]; then
    BBR_OK="yes"
else
    ERRORS=$((ERRORS + 1))
fi

status_line() {
    local label="$1" ok="$2" success_text="$3" error_text="$4"
    if [ "$ok" = "yes" ]; then
        printf '✅ %-27s %s\n' "$label:" "$success_text"
    else
        printf '❌ %-27s %s\n' "$label:" "$error_text"
    fi
}

echo "🔐 Аудит Ubuntu VPS Bootstrap"
echo
echo "Сервер: $(hostname)"
echo
status_line "Конфигурация SSH" "$SYNTAX_OK" "корректна" "содержит ошибку"
status_line "Управляемый конфиг" "$CONFIG_FILE_OK" "подключён" "не найден"
status_line "SSH-служба" "$SSH_SERVICE_OK" "запущена и включена" "не запущена или не включена"
status_line "Socket activation" "$SSH_SOCKET_OK" "отключён" "активен"
status_line "SSH-порт" "$EFFECTIVE_PORT_OK" "$SSH_PORT" "${EFFECTIVE_PORTS[*]:-не определён}"
status_line "Фактически слушается" "$ACTIVE_PORT_OK" "только $SSH_PORT" "${ACTIVE_SSH_PORTS[*]:-ничего}"
status_line "Вход под root" "$ROOT_LOGIN_OK" "отключён" "разрешён или не определён"
status_line "Вход по паролю" "$PASSWORD_LOGIN_OK" "отключён" "разрешён или не определён"
status_line "Keyboard-interactive" "$KEYBOARD_LOGIN_OK" "отключён" "разрешён или не определён"
status_line "Авторизация" "$AUTH_METHOD_OK" "только SSH-ключ" "не ограничена SSH-ключом"
status_line "UFW" "$UFW_OK" "включён, порт $SSH_PORT разрешён" "неактивен или нет правила порта"
status_line "Fail2ban" "$FAIL2BAN_OK" "sshd jail работает" "не работает"
status_line "BBR" "$BBR_OK" "включён" "не включён"

if [ "$DETAILS" = "yes" ]; then
    FILTER='^(port|listenaddress|permitrootlogin|permitemptypasswords|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|hostbasedauthentication|gssapiauthentication)[[:space:]]'
    echo
    echo "============================================================"
    echo "ТЕХНИЧЕСКИЕ ПОДРОБНОСТИ"
    echo "============================================================"
    echo
    echo "### Управляемый SSH-конфиг"
    sed -n '1,200p' "$MANAGED_SSH_CONFIG" 2>/dev/null || true
    echo
    echo "### Итоговые параметры SSH"
    printf '%s\n' "$CONTEXT_EFFECTIVE" | grep -Ei "$FILTER" || true
    echo
    echo "### Слушающие SSH-порты"
    ss -lntp 2>/dev/null | grep sshd || true
    echo
    echo "### UFW"
    ufw status verbose 2>/dev/null || true
    echo
    echo "### Fail2ban"
    fail2ban-client status sshd 2>/dev/null || true
    echo
    echo "### BBR"
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control 2>/dev/null || true
    echo
    echo "### Службы"
    echo "SSH: ${SSH_SERVICE:-не найдена}; состояние=$SSH_SERVICE_STATE; автозапуск=$SSH_SERVICE_ENABLED"
    echo "Socket: ${SSH_SOCKET_UNIT:-не используется}; состояние=$SSH_SOCKET_STATE; автозапуск=$SSH_SOCKET_ENABLED"
fi

echo
if [ "$ERRORS" -eq 0 ]; then
    echo "✅ Настройки Bootstrap применены корректно."
    if [ "$DETAILS" != "yes" ]; then
        echo "Подробный отчёт: sudo vps-bootstrap-audit --details"
    fi
else
    echo "❌ Обнаружены отклонения: $ERRORS."
    if [ "$DETAILS" != "yes" ]; then
        echo "Подробный отчёт: sudo vps-bootstrap-audit --details"
    fi
    exit 1
fi
VPS_BOOTSTRAP_AUDIT
chmod 0755 /usr/local/sbin/vps-bootstrap-audit

ui "[6/7] Настройка UFW, Fail2ban, BBR и часового пояса..."

cat > "$SYSCTL_CONFIG" <<'EOF'
# Network settings managed by Ubuntu VPS Bootstrap
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
chmod 0644 "$SYSCTL_CONFIG"
modprobe tcp_bbr
sysctl -p "$SYSCTL_CONFIG" >/dev/null
timedatectl set-timezone "$TIMEZONE"

SSH_PORT="$SSH_PORT" NEW_USER="$NEW_USER" /usr/local/sbin/vps-bootstrap-apply

cat > "$STATE_FILE" <<EOF
SSH_PORT=$SSH_PORT
ADMIN_USER=$NEW_USER
TIMEZONE=$TIMEZONE
EOF
chmod 0600 "$STATE_FILE"

ui "[7/7] Финальная проверка..."

/usr/local/sbin/vps-bootstrap-audit

if [ "$(hostname)" != "$NEW_HOSTNAME" ] ||
    [ "$(hostnamectl --static)" != "$NEW_HOSTNAME" ] ||
    [ "$(cat /etc/hostname)" != "$NEW_HOSTNAME" ] ||
    ! getent -s files hosts "$NEW_HOSTNAME" >/dev/null ||
    ! systemctl is-active --quiet fail2ban ||
    ! ufw status | grep -q '^Status: active'; then
    fail "финальная проверка системных настроек не пройдена."
    exit 1
fi

SERVER_ADDRESS=""
if [ -n "${SSH_CONNECTION:-}" ]; then
    SERVER_ADDRESS="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $3}')"
fi
if [ -z "$SERVER_ADDRESS" ]; then
    SERVER_ADDRESS="смотрите в панели провайдера"
fi

INSTALL_COMPLETE="yes"

ui
ui "============================================================"
ui "✅ Первоначальная настройка VPS успешно завершена"
ui
printf '%-20s %s\n' "Адрес сервера:" "$SERVER_ADDRESS" >&3
printf '%-20s %s\n' "Hostname:" "$NEW_HOSTNAME" >&3
printf '%-20s %s\n' "Пользователь:" "$NEW_USER" >&3
printf '%-20s %s\n' "SSH-порт:" "$SSH_PORT" >&3
printf '%-20s %s\n' "Авторизация:" "только SSH-ключ" >&3
printf '%-20s %s\n' "UFW:" "включён" >&3
printf '%-20s %s\n' "Fail2ban:" "работает" >&3
printf '%-20s %s\n' "BBR:" "включён" >&3
printf '%-20s %s\n' "Часовой пояс:" "$TIMEZONE" >&3
ui
ui "Сохраните эти данные в надёжном месте."
ui "Не закрывайте текущую сессию, пока не проверите"
ui "новое подключение в Termius."
ui
ui "Проверка: sudo vps-bootstrap-audit"
ui "Журнал:   $LOG_FILE"
ui "============================================================"
ui
