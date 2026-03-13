#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="amnezia-wg-easy"
APP_DIR="/opt/${APP_NAME}"
DATA_DIR="${APP_DIR}/data"
BACKUP_DIR="${APP_DIR}/backups"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

IMAGE_DEFAULT="ghcr.io/stevefoxru/amnezia-wg-easy"

LANG_DEFAULT="en"
WEBUI_HOST_DEFAULT="0.0.0.0"
WEBUI_PORT_DEFAULT="1240"
WG_PORT_DEFAULT="730"
WG_DEFAULT_DNS_DEFAULT="8.8.8.8,8.8.4.4"
WG_DEFAULT_ADDRESS_DEFAULT="10.66.0.x"

JC_DEFAULT="1"
JMIN_DEFAULT="1"
JMAX_DEFAULT="3"

CHECK_UPDATE_DEFAULT="true"
UI_TRAFFIC_STATS_DEFAULT="true"
UI_CHART_TYPE_DEFAULT="3"
USE_GRAVATAR_DEFAULT="true"
UI_ENABLE_SORT_CLIENTS_DEFAULT="true"
ENABLE_PROMETHEUS_METRICS_DEFAULT="true"
WG_PERSISTENT_KEEPALIVE_DEFAULT="25"
WG_ENABLE_EXPIRES_TIME_DEFAULT="true"
DICEBEAR_TYPE_DEFAULT="adventurer"
WG_ENABLE_ONE_TIME_LINKS_DEFAULT="true"
MAX_AGE_DEFAULT="43200"

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
BOLD="\033[1m"
NC="\033[0m"

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[*]${NC} $*"; }

cleanup_on_error() {
  err "Скрипт остановлен из-за ошибки."
}
trap cleanup_on_error ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти скрипт с sudo:"
    echo "  sudo bash install.sh"
    exit 1
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || { err "Не найден /etc/os-release"; exit 1; }
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || { err "Скрипт рассчитан на Ubuntu. Обнаружено: ${ID:-unknown}"; exit 1; }

  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Скрипт оптимизирован под Ubuntu 24.04, у тебя ${VERSION_ID:-unknown}."
    warn "Продолжаю."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

docker_ok() {
  command_exists docker && docker --version >/dev/null 2>&1
}

compose_ok() {
  docker compose version >/dev/null 2>&1
}

ensure_base_packages() {
  log "Проверяю зависимости"
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    openssl \
    apache2-utils \
    iproute2 \
    net-tools \
    tar \
    gzip \
    coreutils >/dev/null
}

install_docker_if_needed() {
  if docker_ok && compose_ok; then
    log "Docker и Docker Compose уже установлены"
    return
  fi

  warn "Docker и/или Docker Compose не найдены"
  log "Устанавливаю Docker"

  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

show_docker_versions() {
  echo
  docker --version || true
  docker compose version || true
  echo
}

port_in_use_any() {
  local port="$1"
  ss -lntupH 2>/dev/null | awk '{print $5}' | grep -qE "(^|:)$port$"
}

find_free_port() {
  local port="$1"
  while port_in_use_any "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

detect_public_ip() {
  local ip=""
  local urls=(
    "https://api.ipify.org"
    "https://ifconfig.me"
    "https://icanhazip.com"
  )

  for url in "${urls[@]}"; do
    ip="$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  echo ""
}

generate_password() {
  openssl rand -base64 24 | tr -d '=+/' | cut -c1-22
}

generate_bcrypt_hash() {
  local password="$1"
  htpasswd -bnBC 12 "" "$password" | tr -d ':\n'
}

escape_compose_dollars() {
  sed 's/\$/$$/g'
}

ask_default() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "$prompt [$default]: " answer
  echo "${answer:-$default}"
}

ask_yes_no() {
  local prompt="$1"
  local default="$2"
  local answer

  while true; do
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) echo "Введи y/n" ;;
    esac
  done
}

prepare_dirs() {
  mkdir -p "$APP_DIR" "$DATA_DIR" "$BACKUP_DIR"
  chmod 700 "$APP_DIR" "$DATA_DIR"
  chmod 755 "$BACKUP_DIR"
}

stack_exists() {
  [[ -f "$COMPOSE_FILE" ]]
}

env_key_exists() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] && grep -qE "^${key}=" "$ENV_FILE"
}

read_env_value() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"

  touch "$ENV_FILE"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i -E "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

extract_password_hash_from_compose() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    grep -E 'PASSWORD_HASH:' "$COMPOSE_FILE" | head -n1 | sed 's/.*PASSWORD_HASH:[[:space:]]*"\(.*\)".*/\1/' || true
  fi
}

set_password_hash_in_compose() {
  local escaped_hash="$1"

  if grep -q 'PASSWORD_HASH:' "$COMPOSE_FILE"; then
    sed -i -E 's|(PASSWORD_HASH:[[:space:]]*").*(")|\1'"${escaped_hash}"'\2|' "$COMPOSE_FILE"
  else
    err "Не удалось найти PASSWORD_HASH в docker-compose.yml"
    return 1
  fi
}

open_ufw_ports() {
  local webui_port="$1"
  local wg_port="$2"

  if command_exists ufw; then
    log "Открываю порты в UFW: ${webui_port}/tcp и ${wg_port}/udp"
    ufw allow "${webui_port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${wg_port}/udp" >/dev/null 2>&1 || true
  else
    warn "UFW не установлен, шаг пропущен"
  fi
}

close_ufw_ports_if_possible() {
  local webui_port="$1"
  local wg_port="$2"

  if command_exists ufw; then
    log "Удаляю правила UFW для ${webui_port}/tcp и ${wg_port}/udp"
    ufw delete allow "${webui_port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${wg_port}/udp" >/dev/null 2>&1 || true
  fi
}

start_stack() {
  cd "$APP_DIR"
  log "Скачиваю образ"
  docker compose pull
  log "Запускаю контейнер"
  docker compose up -d
}

restart_stack() {
  cd "$APP_DIR"
  log "Перезапускаю контейнер"
  docker compose up -d
}

post_checks() {
  cd "$APP_DIR"
  echo
  docker compose ps || true
  echo
}

write_env() {
  cat >"$ENV_FILE" <<EOF
LANG=${LANG_DEFAULT}

WEBUI_HOST=${WEBUI_HOST_DEFAULT}
PORT=${WEBUI_PORT}
WG_PORT=${WG_PORT}

CHECK_UPDATE=${CHECK_UPDATE_DEFAULT}
WG_HOST=${WG_HOST}

WG_DEFAULT_DNS=${WG_DEFAULT_DNS}
WG_DEFAULT_ADDRESS=${WG_DEFAULT_ADDRESS}

JC=${JC_DEFAULT}
JMIN=${JMIN_DEFAULT}
JMAX=${JMAX_DEFAULT}

UI_TRAFFIC_STATS=${UI_TRAFFIC_STATS_DEFAULT}
UI_CHART_TYPE=${UI_CHART_TYPE_DEFAULT}
USE_GRAVATAR=${USE_GRAVATAR_DEFAULT}
UI_ENABLE_SORT_CLIENTS=${UI_ENABLE_SORT_CLIENTS_DEFAULT}

ENABLE_PROMETHEUS_METRICS=${ENABLE_PROMETHEUS_METRICS_DEFAULT}

WG_PERSISTENT_KEEPALIVE=${WG_PERSISTENT_KEEPALIVE_DEFAULT}
WG_ENABLE_EXPIRES_TIME=${WG_ENABLE_EXPIRES_TIME_DEFAULT}

DICEBEAR_TYPE=${DICEBEAR_TYPE_DEFAULT}
WG_ENABLE_ONE_TIME_LINKS=${WG_ENABLE_ONE_TIME_LINKS_DEFAULT}

MAX_AGE=${MAX_AGE_DEFAULT}

DOCKER_IMAGE=${IMAGE}
ADMIN_PASSWORD_PLAIN=${ADMIN_PASSWORD}
EOF

  chmod 600 "$ENV_FILE"
}

write_compose() {
  cat >"$COMPOSE_FILE" <<EOF
services:
  amnezia-wg-easy:
    image: \${DOCKER_IMAGE}
    container_name: amnezia-wg-easy
    restart: unless-stopped

    env_file:
      - .env

    environment:
      PASSWORD_HASH: "${PASSWORD_HASH_ESCAPED}"

    volumes:
      - ./data:/etc/wireguard

    ports:
      - "\${WG_PORT}:\${WG_PORT}/udp"
      - "\${PORT}:\${PORT}/tcp"

    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    sysctls:
      net.ipv4.conf.all.src_valid_mark: "1"
      net.ipv4.ip_forward: "1"

    devices:
      - /dev/net/tun:/dev/net/tun
EOF

  chmod 644 "$COMPOSE_FILE"
}

print_summary() {
  echo
  echo -e "${GREEN}========================================================${NC}"
  echo -e "${GREEN} AWG установлен${NC}"
  echo -e "${GREEN}========================================================${NC}"
  echo
  echo "Панель управления: http://${WG_HOST}:${WEBUI_PORT}"
  echo "VPN endpoint:      ${WG_HOST}:${WG_PORT}/udp"
  echo "Пароль:            ${ADMIN_PASSWORD}"
  echo
  echo "Файлы:"
  echo "  ${ENV_FILE}"
  echo "  ${COMPOSE_FILE}"
  echo "  ${DATA_DIR}"
  echo
  warn "Пароль временно сохранён в ${ENV_FILE} как ADMIN_PASSWORD_PLAIN."
  warn "После входа в панель лучше удалить строку ADMIN_PASSWORD_PLAIN вручную."
  warn "Форк проекта находится здесь - https://github.com/stevefoxru/amnezia-wg-easy"
  echo
}

collect_install_settings() {
  echo
  echo -e "${BOLD}=== Установка / переустановка AWG ===${NC}"

  DETECTED_IP="$(detect_public_ip || true)"
  if [[ -n "$DETECTED_IP" ]]; then
    log "Найден публичный IP: $DETECTED_IP"
    if ask_yes_no "Использовать этот IP для WG_HOST?" "y"; then
      WG_HOST="$DETECTED_IP"
    else
      WG_HOST="$(ask_default "Введи IP или домен для WG_HOST" "$DETECTED_IP")"
    fi
  else
    warn "Не удалось автоматически определить IP"
    WG_HOST="$(ask_default "Введи IP или домен для WG_HOST" "")"
    [[ -n "$WG_HOST" ]] || { err "WG_HOST не может быть пустым"; exit 1; }
  fi

  WEBUI_PORT_CANDIDATE="$(find_free_port "$WEBUI_PORT_DEFAULT")"
  [[ "$WEBUI_PORT_CANDIDATE" != "$WEBUI_PORT_DEFAULT" ]] && warn "Порт ${WEBUI_PORT_DEFAULT}/tcp занят"
  WEBUI_PORT="$(ask_default "Порт Web UI" "$WEBUI_PORT_CANDIDATE")"

  WG_PORT_CANDIDATE="$(find_free_port "$WG_PORT_DEFAULT")"
  [[ "$WG_PORT_CANDIDATE" != "$WG_PORT_DEFAULT" ]] && warn "Порт ${WG_PORT_DEFAULT}/udp занят"
  WG_PORT="$(ask_default "Порт VPN (UDP)" "$WG_PORT_CANDIDATE")"

  if port_in_use_any "$WEBUI_PORT"; then
    err "Порт ${WEBUI_PORT} уже занят"
    exit 1
  fi

  if port_in_use_any "$WG_PORT"; then
    err "Порт ${WG_PORT} уже занят"
    exit 1
  fi

  if ask_yes_no "Сгенерировать случайный пароль администратора?" "y"; then
    ADMIN_PASSWORD="$(generate_password)"
    log "Пароль сгенерирован"
  else
    while true; do
      read -r -s -p "Введи пароль администратора: " p1
      echo
      read -r -s -p "Повтори пароль: " p2
      echo
      if [[ -z "$p1" ]]; then
        warn "Пароль не может быть пустым"
      elif [[ "$p1" != "$p2" ]]; then
        warn "Пароли не совпадают"
      else
        ADMIN_PASSWORD="$p1"
        break
      fi
    done
  fi

  PASSWORD_HASH_RAW="$(generate_bcrypt_hash "$ADMIN_PASSWORD")"
  PASSWORD_HASH_ESCAPED="$(printf '%s' "$PASSWORD_HASH_RAW" | escape_compose_dollars)"

  IMAGE="$(ask_default "Docker image" "$IMAGE_DEFAULT")"
  WG_DEFAULT_DNS="$(ask_default "DNS по умолчанию" "$WG_DEFAULT_DNS_DEFAULT")"
  WG_DEFAULT_ADDRESS="$(ask_default "Подсеть клиентов" "$WG_DEFAULT_ADDRESS_DEFAULT")"
}

install_awg() {
  ensure_base_packages
  install_docker_if_needed
  show_docker_versions
  prepare_dirs

  if stack_exists; then
    if ask_yes_no "Найдена существующая установка. Сделать backup перед переустановкой?" "y"; then
      backup_awg
    fi
  fi

  collect_install_settings
  write_env
  write_compose

  if ask_yes_no "Открыть порты в UFW, если он установлен?" "y"; then
    open_ufw_ports "$WEBUI_PORT" "$WG_PORT"
  fi

  start_stack
  post_checks
  print_summary
}

update_awg() {
  if ! stack_exists; then
    err "AWG ещё не установлен"
    return 1
  fi

  log "Обновляю контейнер"
  cd "$APP_DIR"
  docker compose pull
  docker compose up -d
  post_checks
  log "Обновление завершено"
}

change_password_awg() {
  if ! stack_exists; then
    err "AWG ещё не установлен"
    return 1
  fi

  echo
  echo -e "${BOLD}=== Смена пароля панели ===${NC}"

  local new_password new_hash_raw new_hash_escaped
  if ask_yes_no "Сгенерировать случайный пароль?" "y"; then
    new_password="$(generate_password)"
    log "Новый пароль сгенерирован"
  else
    while true; do
      read -r -s -p "Введи новый пароль: " p1
      echo
      read -r -s -p "Повтори новый пароль: " p2
      echo
      if [[ -z "$p1" ]]; then
        warn "Пароль не может быть пустым"
      elif [[ "$p1" != "$p2" ]]; then
        warn "Пароли не совпадают"
      else
        new_password="$p1"
        break
      fi
    done
  fi

  new_hash_raw="$(generate_bcrypt_hash "$new_password")"
  new_hash_escaped="$(printf '%s' "$new_hash_raw" | escape_compose_dollars)"

  cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  set_password_hash_in_compose "$new_hash_escaped"
  set_env_value "ADMIN_PASSWORD_PLAIN" "$new_password"

  restart_stack

  echo
  log "Пароль обновлён"
  echo "Новый пароль: ${new_password}"
  warn "Пароль сохранён в ${ENV_FILE}. При желании потом удали строку ADMIN_PASSWORD_PLAIN."
}

show_status_awg() {
  if ! stack_exists; then
    err "AWG ещё не установлен"
    return 1
  fi

  local wg_host port wg_port image hash_preview
  wg_host="$(read_env_value "WG_HOST")"
  port="$(read_env_value "PORT")"
  wg_port="$(read_env_value "WG_PORT")"
  image="$(read_env_value "DOCKER_IMAGE")"
  hash_preview="$(extract_password_hash_from_compose)"

  echo
  echo -e "${BOLD}=== Текущий статус AWG ===${NC}"
  echo "Папка проекта: $APP_DIR"
  echo "Папка данных:  $DATA_DIR"
  echo "Backup каталог: $BACKUP_DIR"
  echo "Образ:         ${image:-не найден}"
  echo "WG_HOST:       ${wg_host:-не найден}"
  echo "Web UI:        ${port:-не найден}/tcp"
  echo "VPN порт:      ${wg_port:-не найден}/udp"

  if [[ -n "${hash_preview}" ]]; then
    echo "PASSWORD_HASH: настроен"
  else
    echo "PASSWORD_HASH: не найден"
  fi

  echo
  cd "$APP_DIR"
  docker compose ps || true
  echo
  docker ps --filter "name=amnezia-wg-easy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  echo
}

backup_awg() {
  if [[ ! -d "$APP_DIR" ]]; then
    err "Каталог AWG не найден"
    return 1
  fi

  mkdir -p "$BACKUP_DIR"

  local ts backup_file tmp_list=()
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_file="${BACKUP_DIR}/awg-backup-${ts}.tar.gz"

  [[ -d "$DATA_DIR" ]] && tmp_list+=("data")
  [[ -f "$ENV_FILE" ]] && tmp_list+=(".env")
  [[ -f "$COMPOSE_FILE" ]] && tmp_list+=("docker-compose.yml")

  if [[ ${#tmp_list[@]} -eq 0 ]]; then
    err "Нет файлов для backup"
    return 1
  fi

  log "Создаю backup"
  (
    cd "$APP_DIR"
    tar -czf "$backup_file" "${tmp_list[@]}"
  )

  log "Backup создан: $backup_file"
}

restore_backup_awg() {
  mkdir -p "$BACKUP_DIR"

  local backups=()
  while IFS= read -r -d '' file; do
    backups+=("$file")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'awg-backup-*.tar.gz' -print0 | sort -z)

  if [[ ${#backups[@]} -eq 0 ]]; then
    err "Backup файлы не найдены в $BACKUP_DIR"
    return 1
  fi

  echo
  echo -e "${BOLD}=== Доступные backup файлы ===${NC}"
  local i=1
  for file in "${backups[@]}"; do
    echo "$i) $(basename "$file")"
    i=$((i + 1))
  done
  echo

  local choice selected
  read -r -p "Выбери backup для восстановления [1-${#backups[@]}]: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
    err "Неверный выбор"
    return 1
  fi

  selected="${backups[$((choice - 1))]}"

  echo
  warn "Восстановление перезапишет текущие файлы AWG в ${APP_DIR}"
  if ! ask_yes_no "Продолжить?" "n"; then
    info "Отменено"
    return 0
  fi

  if stack_exists; then
    if ask_yes_no "Сделать backup текущего состояния перед восстановлением?" "y"; then
      backup_awg
    fi
    (
      cd "$APP_DIR"
      docker compose down --remove-orphans || true
    )
  fi

  mkdir -p "$APP_DIR"
  tar -xzf "$selected" -C "$APP_DIR"

  chmod 700 "$APP_DIR"
  [[ -d "$DATA_DIR" ]] && chmod 700 "$DATA_DIR"
  [[ -f "$ENV_FILE" ]] && chmod 600 "$ENV_FILE"
  [[ -f "$COMPOSE_FILE" ]] && chmod 644 "$COMPOSE_FILE"

  if ask_yes_no "Запустить AWG после восстановления?" "y"; then
    restart_stack
    post_checks
  fi

  log "Восстановление завершено"
}

change_wg_host_awg() {
  if ! stack_exists; then
    err "AWG ещё не установлен"
    return 1
  fi

  echo
  echo -e "${BOLD}=== Смена WG_HOST ===${NC}"

  local current_host detected_ip new_host
  current_host="$(read_env_value "WG_HOST")"
  detected_ip="$(detect_public_ip || true)"

  echo "Текущий WG_HOST: ${current_host:-не найден}"
  if [[ -n "$detected_ip" ]]; then
    echo "Обнаруженный публичный IP: $detected_ip"
  fi

  if [[ -n "$detected_ip" ]]; then
    new_host="$(ask_default "Новый WG_HOST" "$detected_ip")"
  else
    new_host="$(ask_default "Новый WG_HOST" "${current_host:-}")"
  fi

  [[ -n "$new_host" ]] || { err "WG_HOST не может быть пустым"; return 1; }

  set_env_value "WG_HOST" "$new_host"
  restart_stack

  log "WG_HOST обновлён: $new_host"
}

change_ports_awg() {
  if ! stack_exists; then
    err "AWG ещё не установлен"
    return 1
  fi

  echo
  echo -e "${BOLD}=== Смена портов ===${NC}"

  local old_webui old_wg new_webui new_wg
  old_webui="$(read_env_value "PORT")"
  old_wg="$(read_env_value "WG_PORT")"

  echo "Текущий Web UI порт: ${old_webui:-не найден}/tcp"
  echo "Текущий VPN порт:    ${old_wg:-не найден}/udp"

  new_webui="$(ask_default "Новый Web UI порт" "${old_webui:-$WEBUI_PORT_DEFAULT}")"
  new_wg="$(ask_default "Новый VPN порт (UDP)" "${old_wg:-$WG_PORT_DEFAULT}")"

  [[ "$new_webui" =~ ^[0-9]+$ ]] || { err "Web UI порт должен быть числом"; return 1; }
  [[ "$new_wg" =~ ^[0-9]+$ ]] || { err "VPN порт должен быть числом"; return 1; }

  if [[ "$new_webui" != "$old_webui" ]] && port_in_use_any "$new_webui"; then
    err "Порт ${new_webui} уже занят"
    return 1
  fi

  if [[ "$new_wg" != "$old_wg" ]] && port_in_use_any "$new_wg"; then
    err "Порт ${new_wg} уже занят"
    return 1
  fi

  if ask_yes_no "Сделать backup перед сменой портов?" "y"; then
    backup_awg
  fi

  set_env_value "PORT" "$new_webui"
  set_env_value "WG_PORT" "$new_wg"

  restart_stack

  if [[ -n "$old_webui" && -n "$old_wg" ]]; then
    close_ufw_ports_if_possible "$old_webui" "$old_wg"
  fi

  if ask_yes_no "Открыть новые порты в UFW, если он установлен?" "y"; then
    open_ufw_ports "$new_webui" "$new_wg"
  fi

  log "Порты обновлены: Web UI ${new_webui}/tcp, VPN ${new_wg}/udp"
}

remove_awg() {
  echo
  echo -e "${BOLD}=== Удаление AWG ===${NC}"

  local existing_webui_port existing_wg_port
  existing_webui_port="$(read_env_value "PORT")"
  existing_wg_port="$(read_env_value "WG_PORT")"

  if stack_exists; then
    if ask_yes_no "Сделать backup перед удалением?" "y"; then
      backup_awg
    fi

    log "Останавливаю и удаляю контейнер"
    (
      cd "$APP_DIR"
      docker compose down --remove-orphans || true
    )
  else
    warn "docker-compose.yml не найден, пробую удалить контейнер напрямую"
    docker rm -f amnezia-wg-easy >/dev/null 2>&1 || true
  fi

  if [[ -n "$existing_webui_port" && -n "$existing_wg_port" ]]; then
    close_ufw_ports_if_possible "$existing_webui_port" "$existing_wg_port"
  fi

  if ask_yes_no "Удалить каталог проекта ${APP_DIR}?" "y"; then
    rm -rf "$APP_DIR"
    log "Каталог удалён"
  else
    warn "Каталог оставлен"
  fi

  log "AWG удалён"
  warn "Docker оставлен в системе."
}

show_menu() {
  echo
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD}         AWG Manager v3${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo "1) Установить / переустановить AWG"
  echo "2) Обновить контейнер AWG"
  echo "3) Сменить пароль панели"
  echo "4) Показать статус и настройки"
  echo "5) Сделать backup"
  echo "6) Восстановить из backup"
  echo "7) Сменить WG_HOST"
  echo "8) Сменить порты Web UI / VPN"
  echo "9) Удалить AWG"
  echo "10) Выход"
  echo
}

main() {
  require_root
  check_os

  while true; do
    show_menu
    read -r -p "Выбери действие [1-10]: " choice
    case "$choice" in
      1) install_awg ;;
      2) update_awg ;;
      3) change_password_awg ;;
      4) show_status_awg ;;
      5) backup_awg ;;
      6) restore_backup_awg ;;
      7) change_wg_host_awg ;;
      8) change_ports_awg ;;
      9) remove_awg ;;
      10) echo "Выход."; exit 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

main "$@"
