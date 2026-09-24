#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="5.0.1"

REMNANODE_DIR="/opt/remnanode"
HAPROXY_DIR="/opt/haproxy"
CADDY_SOCKET="/dev/shm/nginx.sock"
STATE_DIR="/var/lib/remnawave-haproxy-multitransport"
STATE_FILE="$STATE_DIR/install-state.txt"
WAIT_TIMEOUT=900
HYSTERIA_CERT_FILE="/var/lib/remnawave/configs/xray/ssl/fullchain.pem"
HYSTERIA_KEY_FILE="/var/lib/remnawave/configs/xray/ssl/privkey.key"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
PURPLE=$'\033[38;5;141m'
PINK=$'\033[38;5;213m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

BACKUP_DIR=""

ok()   { printf '%s✅ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$RESET"; }
info() { printf '%sℹ %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()  { printf '%s❌ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

step() {
    local title="$1"
    local color="${2:-$YELLOW}"

    printf '\n%s%s%s%s\n' \
        "$BOLD" "$color" "$title" "$RESET"
}

show_banner() {
    local -a colors=(
        "$RED" "$ORANGE" "$YELLOW" "$GREEN" "$CYAN"
        "$PURPLE" "$PINK" "$RED" "$ORANGE" "$YELLOW"
    )
    local -a rows=(
        '█████|█   █|█   █| ███ |█   █| ███ |█  ██|█████|█   █|█████'
        '█    |█   █|██ ██|█   █|██ ██|█   █|█ ██ |  █  |██  █|   ██'
        '█ ███|█   █|█ █ █|█████|█ █ █|█████|██   |  █  |█ █ █|  ██ '
        '█   █|█   █|█   █|█   █|█   █|█   █|█ ██ |  █  |█  ██|██   '
        '█████|█████|█   █|█   █|█   █|█   █|█  ██|█████|█   █|█████'
    )
    local row glyph i

    printf '\n'
    for row in "${rows[@]}"; do
        IFS='|' read -r -a glyphs <<< "$row"
        for i in "${!glyphs[@]}"; do
            glyph="${glyphs[$i]}"
            printf '%s%s%s  ' "${colors[$i]}" "$glyph" "$RESET"
        done
        printf '\n'
    done
    printf '\n'
}

summary_border() {
    printf '%s%s%s\n' "$ORANGE" \
        '  ├────────────────────────┼────────────────────────────────────────────┤' \
        "$RESET"
}

summary_row() {
    local label="$1"
    local value="$2"
    local value_color="${3:-$GREEN}"
    local label_padding=$((18 - ${#label}))
    local value_padding=$((42 - ${#value}))

    (( label_padding < 0 )) && label_padding=0
    (( value_padding < 0 )) && value_padding=0

    printf '%s  │%s ' "$ORANGE" "$RESET"
    printf '%s[ %s%*s ]%s ' \
        "$CYAN" "$label" "$label_padding" '' "$RESET"
    printf '%s│%s %s%*s' \
        "$ORANGE" "$value_color" "$value" "$value_padding" ''
    printf ' %s%s│%s\n' "$RESET" "$ORANGE" "$RESET"
}

show_configuration_summary() {
    printf '\n%s%s%s%s\n' "$BOLD" "$YELLOW" \
        '  ╭────────────── ПРОВЕРЬ ПАРАМЕТРЫ ──────────────╮' "$RESET"
    printf '%s%s%s\n' "$ORANGE" \
        '  ┌────────────────────────┬────────────────────────────────────────────┐' \
        "$RESET"
    summary_row 'Нода' "$NODE_NAME"
    summary_row 'Код' "$NODE_CODE" "$YELLOW"
    summary_border
    summary_row 'TCP-домен' "$TCP_DOMAIN"
    summary_row 'XHTTP-домен' "$XHTTP_DOMAIN"
    summary_row 'gRPC-домен' "$GRPC_DOMAIN"
    if [[ "$USE_HYSTERIA" == "true" ]]; then
        summary_row 'Hysteria2' 'да' "$GREEN"
        summary_row 'Hysteria-домен' "$HYSTERIA_DOMAIN"
    else
        summary_row 'Hysteria2' 'нет' "$YELLOW"
    fi
    summary_border
    summary_row 'TCP tag' "$TCP_TAG" "$YELLOW"
    summary_row 'XHTTP tag' "$XHTTP_TAG" "$YELLOW"
    summary_row 'gRPC tag' "$GRPC_TAG" "$YELLOW"
    summary_row 'XHTTP path' "$XHTTP_PATH" "$CYAN"
    summary_row 'gRPC service' "$GRPC_SERVICE" "$CYAN"
    if [[ "$USE_HYSTERIA" == "true" ]]; then
        summary_row 'Hysteria tag' "$HYSTERIA_TAG" "$YELLOW"
        summary_row 'Hysteria port' '443/udp' "$PINK"
    fi
    printf '%s%s%s\n' "$ORANGE" \
        '  └────────────────────────┴────────────────────────────────────────────┘' \
        "$RESET"
}

on_error() {
    local rc=$?
    printf '\n%s❌ Ошибка на строке %s, код %s.%s\n' \
        "$RED" "${1:-?}" "$rc" "$RESET" >&2

    if [[ -n "$BACKUP_DIR" ]]; then
        printf '%sБэкап: %s%s\n' \
            "$YELLOW" "$BACKUP_DIR" "$RESET" >&2
    fi

    exit "$rc"
}
trap 'on_error $LINENO' ERR

need_root() {
    [[ ${EUID:-999} -eq 0 ]] ||
        die "Запусти скрипт от root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Не найдена команда: $1"
}

ask() {
    local variable="$1"
    local text="$2"
    local description="${3:-}"
    local value=""

    if [[ -n "$description" ]]; then
        printf '\n  %s\n' "$description"
    fi

    while [[ -z "$value" ]]; do
        read -r -p "$text: " value
    done

    printf -v "$variable" '%s' "$value"
}

confirm() {
    local answer=""
    read -r -p "$1 [Y/n]: " answer
    answer="${answer:-y}"
    [[ "$answer" =~ ^[YyДд]$ ]]
}

confirm_optional() {
    local answer=""
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[YyДд]$ ]]
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_code() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{1,31}$ ]]
}

port_owner() {
    local port="$1"
    ss -ltnp 2>/dev/null |
        awk -v suffix=":${port}" '$4 ~ suffix"$" {print}'
}

local_port_ready() {
    local port="$1"
    ss -ltnp 2>/dev/null |
        grep -qE "127\.0\.0\.1:${port}[[:space:]]"
}

udp_port_owner() {
    local port="$1"
    ss -lunp 2>/dev/null |
        awk -v suffix=":${port}" '$4 ~ suffix"$" {print}'
}

udp_port_ready() {
    local port="$1"
    ss -lunp 2>/dev/null |
        awk -v suffix=":${port}" '$4 ~ suffix"$" {found=1} END {exit !found}'
}

all_xray_inbounds_ready() {
    local_port_ready 1443 &&
        local_port_ready 2443 &&
        local_port_ready 3443 || return 1

    if [[ "${USE_HYSTERIA:-false}" == "true" ]]; then
        udp_port_ready 443 || return 1
    fi
}

detect_caddy_container() {
    local name=""

    for name in caddy-remnawave caddy; do
        if docker ps --format '{{.Names}}' | grep -qx "$name"; then
            printf '%s' "$name"
            return 0
        fi
    done

    name="$(
        docker ps --format '{{.Names}} {{.Image}}' |
            awk 'tolower($0) ~ /caddy/ {print $1; exit}'
    )"

    [[ -n "$name" ]] ||
        die "Не найден запущенный контейнер Caddy."

    printf '%s' "$name"
}

external_ipv4() {
    curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true
}

resolve_ipv4() {
    getent ahostsv4 "$1" 2>/dev/null |
        awk '{print $1}' |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
        sort -u
}

collect_values() {
    step "Ввод параметров" "$ORANGE"

    ask NODE_NAME \
        "${YELLOW}Название ноды${RESET}, например ${GREEN}Estonia${RESET}" \
        "Понятное имя локации. Используется в названиях inbound и Hosts."

    ask NODE_CODE \
        "${YELLOW}Короткий код${RESET}, например ${GREEN}ee01${RESET}" \
        "Уникальный код ноды. Из него формируются XHTTP path и gRPC serviceName."

    ask TCP_DOMAIN \
        "${YELLOW}TCP-домен${RESET}, например ${GREEN}rw-ee01.example.ru${RESET}" \
        "Адрес для TCP Reality. DNS-запись должна указывать на этот сервер."

    ask XHTTP_DOMAIN \
        "${YELLOW}XHTTP-домен${RESET}, например ${GREEN}rw-ee01x.example.ru${RESET}" \
        "Отдельный адрес для XHTTP Reality. DNS-запись должна указывать на этот сервер."

    ask GRPC_DOMAIN \
        "${YELLOW}gRPC-домен${RESET}, например ${GREEN}rw-ee01g.example.ru${RESET}" \
        "Отдельный адрес для gRPC Reality. DNS-запись должна указывать на этот сервер."

    USE_HYSTERIA="false"
    HYSTERIA_DOMAIN=""

    printf '\n  Hysteria2 работает напрямую через Xray на 443/udp и не проходит через HAProxy.\n'
    if confirm_optional "Добавить Hysteria2 на эту ноду?"; then
        USE_HYSTERIA="true"
        ask HYSTERIA_DOMAIN \
            "${YELLOW}Hysteria-домен${RESET}, например ${GREEN}rw-ee01h.example.ru${RESET}" \
            "Домен для Hysteria2 TLS. DNS-запись должна указывать на этот сервер."
    fi

    valid_code "$NODE_CODE" ||
        die "Короткий код должен содержать строчные буквы, цифры, _ или -."

    valid_domain "$TCP_DOMAIN" ||
        die "Некорректный TCP-домен."

    valid_domain "$XHTTP_DOMAIN" ||
        die "Некорректный XHTTP-домен."

    valid_domain "$GRPC_DOMAIN" ||
        die "Некорректный gRPC-домен."

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        valid_domain "$HYSTERIA_DOMAIN" ||
            die "Некорректный Hysteria-домен."
    fi

    TCP_TAG="${NODE_NAME}-T"
    XHTTP_TAG="${NODE_NAME}-X"
    GRPC_TAG="${NODE_NAME}-G"
    HYSTERIA_TAG="${NODE_NAME}-H"
    XHTTP_PATH="/api/v3/sync/${NODE_CODE}"
    GRPC_SERVICE="api.v3.sync.${NODE_CODE}"

    show_configuration_summary
    printf '\n'

    confirm "Всё верно, продолжить?" || exit 0
}

preflight() {
    step "Проверки сервера"

    need_root
    need_cmd docker
    need_cmd ss
    need_cmd curl
    need_cmd getent
    need_cmd awk
    need_cmd grep

    docker info >/dev/null 2>&1 ||
        die "Docker не запущен."

    docker compose version >/dev/null 2>&1 ||
        die "Не найден Docker Compose plugin."

    [[ -d "$REMNANODE_DIR" ]] ||
        die "Не найден каталог $REMNANODE_DIR"

    [[ -f "$REMNANODE_DIR/Caddyfile" ]] ||
        die "Не найден $REMNANODE_DIR/Caddyfile"

    CADDY_CONTAINER="$(detect_caddy_container)"
    ok "Caddy: $CADDY_CONTAINER"

    if docker ps --format '{{.Names}}' | grep -qx remnanode; then
        ok "Remnanode найден."
    else
        warn "Контейнер remnanode не найден по стандартному имени."
    fi

    local public_ip=""
    local domain=""
    local addresses=""
    local -a domains=("$TCP_DOMAIN" "$XHTTP_DOMAIN" "$GRPC_DOMAIN")

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        domains+=("$HYSTERIA_DOMAIN")
    fi

    public_ip="$(external_ipv4)"
    [[ -n "$public_ip" ]] &&
        info "Внешний IPv4: $public_ip"

    for domain in "${domains[@]}"; do
        addresses="$(resolve_ipv4 "$domain" || true)"

        if [[ -z "$addresses" ]]; then
            warn "$domain не разрешается в IPv4."
            continue
        fi

        info "$domain → $(tr '\n' ' ' <<<"$addresses" | xargs)"

        if [[ -n "$public_ip" ]] &&
            ! grep -qx "$public_ip" <<<"$addresses"; then
            warn "$domain не указывает на $public_ip."
        fi
    done

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        local udp_owner=""
        udp_owner="$(udp_port_owner 443 || true)"

        if [[ -n "$udp_owner" ]]; then
            info "Текущий владелец 443/udp: $udp_owner"
        else
            ok "443/udp свободен для Hysteria2."
        fi

        warn "TLS-сертификат Hysteria2 должен быть установлен на сервере Remnawave Panel."
        info "Certificate: $HYSTERIA_CERT_FILE"
        info "Private key: $HYSTERIA_KEY_FILE"
    fi
}

backup_configs() {
    step "Резервная копия"

    BACKUP_DIR="/root/remnawave-multiport-backup-$(date +%F_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    cp -a "$REMNANODE_DIR/Caddyfile" "$BACKUP_DIR/Caddyfile"

    [[ -f "$REMNANODE_DIR/docker-compose.yml" ]] &&
        cp -a "$REMNANODE_DIR/docker-compose.yml" \
            "$BACKUP_DIR/remnanode-docker-compose.yml"

    if [[ -d "$HAPROXY_DIR" ]]; then
        [[ -f "$HAPROXY_DIR/haproxy.cfg" ]] &&
            cp -a "$HAPROXY_DIR/haproxy.cfg" \
                "$BACKUP_DIR/haproxy.cfg"

        [[ -f "$HAPROXY_DIR/docker-compose.yml" ]] &&
            cp -a "$HAPROXY_DIR/docker-compose.yml" \
                "$BACKUP_DIR/haproxy-docker-compose.yml"
    fi

    ss -ltnp > "$BACKUP_DIR/ports-before.txt" || true
    ss -lunp > "$BACKUP_DIR/ports-udp-before.txt" || true
    docker ps --format \
        'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
        > "$BACKUP_DIR/docker-before.txt" || true

    ok "Бэкап: $BACKUP_DIR"
}

configure_hysteria_prerequisites() {
    [[ "$USE_HYSTERIA" == "true" ]] || return 0

    step "Подготовка Hysteria2"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow 443/udp comment 'Hysteria2' >/dev/null
        ok "UFW: разрешён входящий 443/udp."
    else
        info "Активный UFW не обнаружен: локальное правило не требуется."
    fi

    warn "Если у хостера есть внешний firewall, разреши в нём 443/udp."
    ok "Hysteria2 будет запущена Xray; отдельный контейнер не требуется."
}

configure_caddy() {
    step "Настройка Caddy"

    cat > "$REMNANODE_DIR/Caddyfile" <<EOF
{
    admin off

    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }

    auto_https disable_redirects
}

http://${TCP_DOMAIN}, http://${XHTTP_DOMAIN}, http://${GRPC_DOMAIN} {
    bind 0.0.0.0
    redir https://{host}{uri} permanent
}

https://${TCP_DOMAIN}, https://${XHTTP_DOMAIN}, https://${GRPC_DOMAIN} {
    bind unix/{\$CADDY_SOCKET_PATH}

    root * /var/www/html
    try_files {path} /index.html
    file_server
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOF

    chmod 644 "$REMNANODE_DIR/Caddyfile"

    docker exec "$CADDY_CONTAINER" \
        caddy validate \
        --config /etc/caddy/Caddyfile \
        --adapter caddyfile

    docker restart "$CADDY_CONTAINER" >/dev/null

    local i
    for i in {1..30}; do
        if [[ -S "$CADDY_SOCKET" ]]; then
            ok "Caddy socket готов: $CADDY_SOCKET"
            return 0
        fi
        sleep 1
    done

    docker logs --tail=120 "$CADDY_CONTAINER" || true
    die "Не появился Caddy socket $CADDY_SOCKET"
}

configure_haproxy() {
    step "Настройка HAProxy"

    mkdir -p "$HAPROXY_DIR"

    cat > "$HAPROXY_DIR/haproxy.cfg" <<EOF
global
    log stdout format raw local0
    maxconn 200000

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client 2m
    timeout server 2m

frontend https_in
    bind *:443
    mode tcp

    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    acl sni_tcp   req.ssl_sni -i ${TCP_DOMAIN}
    acl sni_xhttp req.ssl_sni -i ${XHTTP_DOMAIN}
    acl sni_grpc  req.ssl_sni -i ${GRPC_DOMAIN}

    use_backend be_tcp   if sni_tcp
    use_backend be_xhttp if sni_xhttp
    use_backend be_grpc  if sni_grpc

    default_backend be_tcp

backend be_tcp
    mode tcp
    server xray_tcp 127.0.0.1:1443 check

backend be_xhttp
    mode tcp
    server xray_xhttp 127.0.0.1:2443 check

backend be_grpc
    mode tcp
    server xray_grpc 127.0.0.1:3443 check
EOF

    cat > "$HAPROXY_DIR/docker-compose.yml" <<'EOF'
services:
  haproxy:
    image: haproxy:2.9-alpine
    container_name: haproxy
    user: "0:0"
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_BIND_SERVICE
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"
    command:
      - haproxy
      - -f
      - /usr/local/etc/haproxy/haproxy.cfg
      - -db
EOF

    chmod 644 \
        "$HAPROXY_DIR/haproxy.cfg" \
        "$HAPROXY_DIR/docker-compose.yml"

    docker run --rm \
        --user 0:0 \
        -v "$HAPROXY_DIR/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        haproxy:2.9-alpine \
        haproxy -c \
        -f /usr/local/etc/haproxy/haproxy.cfg

    ok "Конфигурация HAProxy валидна."
}

wait_for_xray() {
    step "Ожидание конфигурации Xray"

    if all_xray_inbounds_ready; then
        ok "Все выбранные Xray inbound уже работают."
        return 0
    fi

    printf '\n%sВ Remnawave Panel создай указанные inbound:%s\n' \
        "$BOLD" "$RESET"

    cat <<EOF

TCP Reality
  tag:         ${TCP_TAG}
  listen:      127.0.0.1
  port:        1443
  network:     tcp
  serverName:  ${TCP_DOMAIN}
  dest:        ${CADDY_SOCKET}

XHTTP Reality
  tag:         ${XHTTP_TAG}
  listen:      127.0.0.1
  port:        2443
  network:     xhttp
  path:        ${XHTTP_PATH}
  serverName:  ${XHTTP_DOMAIN}
  dest:        ${CADDY_SOCKET}

gRPC Reality
  tag:         ${GRPC_TAG}
  listen:      127.0.0.1
  port:        3443
  network:     grpc
  serviceName: ${GRPC_SERVICE}
  multiMode:   false
  serverName:  ${GRPC_DOMAIN}
  dest:        ${CADDY_SOCKET}

privateKey и shortId оставь в Xray Template панели.
EOF

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        cat <<EOF

Hysteria2
  tag:             ${HYSTERIA_TAG}
  listen:          0.0.0.0
  port:            443/udp
  protocol:        hysteria
  version:         2
  network:         hysteria
  security:        tls
  serverName:      ${HYSTERIA_DOMAIN}
  ALPN:            h3
  congestion:      bbr
  certificateFile: ${HYSTERIA_CERT_FILE}
  keyFile:         ${HYSTERIA_KEY_FILE}

Важно: сертификат и ключ должны находиться на сервере Remnawave Panel.
Панель сама передаст их на ноду при Redeploy.

Готовый объект inbound для добавления в массив inbounds:
{
  "tag": "${HYSTERIA_TAG}",
  "port": 443,
  "listen": "0.0.0.0",
  "protocol": "hysteria",
  "settings": {
    "clients": [],
    "version": 2
  },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "finalmask": {
      "quicParams": {
        "debug": false,
        "congestion": "bbr"
      }
    },
    "tlsSettings": {
      "alpn": ["h3"],
      "serverName": "${HYSTERIA_DOMAIN}",
      "certificates": [
        {
          "keyFile": "${HYSTERIA_KEY_FILE}",
          "certificateFile": "${HYSTERIA_CERT_FILE}"
        }
      ]
    },
    "hysteriaSettings": {
      "version": 2
    }
  }
}
EOF
    fi

    read -r -p \
        "После сохранения шаблона и Redeploy/Restart нажми Enter..."

    local start_time
    local elapsed
    local tcp
    local xhttp
    local grpc
    local hysteria

    start_time="$(date +%s)"

    while true; do
        tcp="нет"
        xhttp="нет"
        grpc="нет"
        hysteria="выкл"

        local_port_ready 1443 && tcp="OK"
        local_port_ready 2443 && xhttp="OK"
        local_port_ready 3443 && grpc="OK"

        if [[ "$USE_HYSTERIA" == "true" ]]; then
            hysteria="нет"
            udp_port_ready 443 && hysteria="OK"
        fi

        printf '\rTCP=%-3s  XHTTP=%-3s  gRPC=%-3s  Hysteria2=%-4s' \
            "$tcp" "$xhttp" "$grpc" "$hysteria"

        if all_xray_inbounds_ready; then
            printf '\n'
            ok "Все Xray inbound работают."
            return 0
        fi

        elapsed=$(( $(date +%s) - start_time ))

        if (( elapsed >= WAIT_TIMEOUT )); then
            printf '\n'
            ss -ltnp |
                grep -E ':443|:1443|:2443|:3443' || true
            [[ "$USE_HYSTERIA" == "true" ]] &&
                ss -lunp | grep -E ':443' || true
            die "Истекло время ожидания Xray inbound."
        fi

        sleep 3
    done
}

start_haproxy() {
    step "Запуск HAProxy"

    local current_owner=""
    current_owner="$(port_owner 443 || true)"

    if [[ -n "$current_owner" ]] &&
       ! grep -qi haproxy <<<"$current_owner"; then
        warn "Порт 443 занят:"
        printf '%s\n' "$current_owner"
        die "После Redeploy внешний 443 должен освободиться."
    fi

    (
        cd "$HAPROXY_DIR"
        docker compose up -d --force-recreate
    )

    local i
    for i in {1..20}; do
        if port_owner 443 | grep -qi haproxy; then
            ok "HAProxy слушает 443/tcp."
            return 0
        fi
        sleep 1
    done

    docker logs --tail=100 haproxy || true
    die "HAProxy не занял 443/tcp."
}

final_status() {
    step "Итоговый статус"

    port_owner 443 | grep -qi haproxy &&
        ok "443/tcp → HAProxy" ||
        warn "443/tcp не принадлежит HAProxy"

    local_port_ready 1443 &&
        ok "127.0.0.1:1443 → Xray TCP" ||
        warn "Нет 127.0.0.1:1443"

    local_port_ready 2443 &&
        ok "127.0.0.1:2443 → Xray XHTTP" ||
        warn "Нет 127.0.0.1:2443"

    local_port_ready 3443 &&
        ok "127.0.0.1:3443 → Xray gRPC" ||
        warn "Нет 127.0.0.1:3443"

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        udp_port_ready 443 &&
            ok "443/udp → Xray Hysteria2" ||
            warn "Нет Hysteria2 на 443/udp"
    fi

    [[ -S "$CADDY_SOCKET" ]] &&
        ok "$CADDY_SOCKET → Caddy" ||
        warn "Caddy socket отсутствует"

    printf '\n%sПараметры Hosts:%s\n' "$BOLD" "$RESET"

    cat <<EOF

${NODE_NAME} TCP
  Inbound:     ${TCP_TAG}
  Address:     ${TCP_DOMAIN}
  Port:        443
  Network:     tcp
  Security:    reality
  SNI:         ${TCP_DOMAIN}
  Flow:        xtls-rprx-vision
  Fingerprint: Random

${NODE_NAME} XHTTP
  Inbound:     ${XHTTP_TAG}
  Address:     ${XHTTP_DOMAIN}
  Port:        443
  Network:     xhttp
  Security:    reality
  SNI:         ${XHTTP_DOMAIN}
  Path:        ${XHTTP_PATH}
  Mode:        auto
  Flow:        пусто
  Fingerprint: Random

${NODE_NAME} gRPC
  Inbound:     ${GRPC_TAG}
  Address:     ${GRPC_DOMAIN}
  Port:        443
  Network:     grpc
  Security:    reality
  SNI:         ${GRPC_DOMAIN}
  ServiceName: ${GRPC_SERVICE}
  MultiMode:   false
  Flow:        пусто
  Fingerprint: Random
EOF

    if [[ "$USE_HYSTERIA" == "true" ]]; then
        cat <<EOF

${NODE_NAME} Hysteria2
  Inbound:     ${HYSTERIA_TAG}
  Address:     ${HYSTERIA_DOMAIN}
  Port:        443
  Network:     hysteria
  Security:    tls
  SNI:         ${HYSTERIA_DOMAIN}
  ALPN:        h3
EOF
    fi

    printf '\n'
    info "HAProxy logs: docker logs -f haproxy"
    info "Бэкап: $BACKUP_DIR"
    ok "Настройка завершена."
}

check_previous_install() {
    local detected="false"

    step "Проверка предыдущей установки"

    if [[ -f "$STATE_FILE" ]]; then
        detected="true"
        warn "Найдена отметка о предыдущем запуске этого скрипта:"
        sed 's/^/  /' "$STATE_FILE"
    elif [[ -f "$HAPROXY_DIR/haproxy.cfg" ||
            -f "$HAPROXY_DIR/docker-compose.yml" ]]; then
        detected="true"
        warn "Найдена существующая конфигурация HAProxy в $HAPROXY_DIR."
        info "Вероятно, нода уже настраивалась старой версией скрипта."
    elif command -v docker >/dev/null 2>&1 &&
         docker inspect haproxy >/dev/null 2>&1; then
        detected="true"
        warn "Найден существующий контейнер HAProxy."
    else
        ok "Предыдущая установка не обнаружена."
    fi

    if [[ "$detected" == "true" ]]; then
        printf '\n'
        confirm "Продолжить повторную настройку с созданием нового бэкапа?" || exit 0
    fi
}

write_install_state() {
    local temporary=""

    install -d -m 700 "$STATE_DIR"
    temporary="$(mktemp "$STATE_DIR/.install-state.XXXXXX")"

    {
        printf 'installed_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'installer_version=%s\n' "$VERSION"
        printf 'node_name=%s\n' "$NODE_NAME"
        printf 'node_code=%s\n' "$NODE_CODE"
        printf 'tcp_domain=%s\n' "$TCP_DOMAIN"
        printf 'xhttp_domain=%s\n' "$XHTTP_DOMAIN"
        printf 'grpc_domain=%s\n' "$GRPC_DOMAIN"
        printf 'hysteria_enabled=%s\n' "$USE_HYSTERIA"
        if [[ "$USE_HYSTERIA" == "true" ]]; then
            printf 'hysteria_domain=%s\n' "$HYSTERIA_DOMAIN"
        fi
    } > "$temporary"

    chmod 600 "$temporary"
    mv -f "$temporary" "$STATE_FILE"
    ok "Сохранена отметка установки: $STATE_FILE"
}

show_intro() {
    show_banner

    printf '%sRemnawave multi-transport installer v%s%s\n' \
        "$BOLD" "$VERSION" "$RESET"

    printf '\n%sЧто делает скрипт:%s\n' "$BOLD" "$RESET"
    printf '  • Объединяет TCP, XHTTP и gRPC на одном внешнем порту 443.\n'
    printf '  • Проверяет Docker, Caddy, Remnanode, DNS-записи и нужные порты.\n'
    printf '  • Создаёт резервную копию текущих конфигураций.\n'
    printf '  • Настраивает Caddy и HAProxy.\n'
    printf '  • Ограничивает логи HAProxy тремя файлами по 10 МБ.\n'
    printf '  • Опционально добавляет Hysteria2 на 443/udp через Xray.\n'
    printf '  • Показывает параметры inbound для Remnawave Panel.\n'
    printf '  • Дожидается запуска inbound и выводит готовые параметры Hosts.\n'
}

status_only() {
    need_root
    need_cmd docker
    need_cmd ss

    show_banner

    printf '%sRemnawave multi-transport installer v%s%s\n\n' \
        "$BOLD" "$VERSION" "$RESET"

    ss -ltnp |
        grep -E ':80|:443|:2222|:1443|:2443|:3443' || true

    ss -lunp |
        grep -E ':443' || true

    printf '\n'

    docker ps \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' |
        grep -E 'NAMES|haproxy|caddy|remna' || true

    printf '\n'

    [[ -S "$CADDY_SOCKET" ]] &&
        ok "Caddy socket: OK" ||
        warn "Caddy socket: MISSING"

    if [[ -f "$STATE_FILE" ]]; then
        printf '\n%sПоследняя установка:%s\n' "$BOLD" "$RESET"
        sed 's/^/  /' "$STATE_FILE"
    fi
}

preview_only() {
    show_intro

    printf '\n'
    warn "Режим предпросмотра: изменения в системе не вносятся."

    collect_values

    printf '\n'
    ok "Предпросмотр завершён. Система не изменена."
}

main() {
    case "${1:-}" in
        --preview)
            preview_only
            exit 0
            ;;
        --status)
            status_only
            exit 0
            ;;
        --help|-h)
            cat <<EOF
Использование:
  $0            Интерактивная установка
  $0 --preview  Предпросмотр ввода без изменений
  $0 --status   Проверка состояния
  $0 --help     Справка
EOF
            exit 0
            ;;
    esac

    show_intro

    printf '\n'
    warn "Обычный режим изменит конфигурации Caddy и HAProxy на этом сервере."

    need_root
    check_previous_install

    collect_values
    preflight
    backup_configs
    configure_hysteria_prerequisites
    configure_caddy
    configure_haproxy
    wait_for_xray
    start_haproxy
    final_status
    write_install_state
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
