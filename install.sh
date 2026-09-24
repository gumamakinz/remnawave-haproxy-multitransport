#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION="4.3.0"

REMNANODE_DIR="/opt/remnanode"
HAPROXY_DIR="/opt/haproxy"
CADDY_SOCKET="/dev/shm/nginx.sock"
WAIT_TIMEOUT=900

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

BACKUP_DIR=""

ok()   { printf '%s✅ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$RESET"; }
info() { printf '%sℹ %s%s\n' "$BLUE" "$*" "$RESET"; }
die()  { printf '%s❌ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

step() {
    local title="$1"
    local color="${2:-$BLUE}"

    printf '\n%s%s%s%s\n' \
        "$BOLD" "$color" "$title" "$RESET"
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

    valid_code "$NODE_CODE" ||
        die "Короткий код должен содержать строчные буквы, цифры, _ или -."

    valid_domain "$TCP_DOMAIN" ||
        die "Некорректный TCP-домен."

    valid_domain "$XHTTP_DOMAIN" ||
        die "Некорректный XHTTP-домен."

    valid_domain "$GRPC_DOMAIN" ||
        die "Некорректный gRPC-домен."

    TCP_TAG="$NODE_NAME"
    XHTTP_TAG="${NODE_NAME}-XHTTP"
    GRPC_TAG="${NODE_NAME}-gRPC"
    XHTTP_PATH="/api/v3/sync/${NODE_CODE}"
    GRPC_SERVICE="api.v3.sync.${NODE_CODE}"

    printf '\n%sПроверь:%s\n' "$BOLD" "$RESET"
    printf '  Нода:          %s\n' "$NODE_NAME"
    printf '  Код:           %s\n' "$NODE_CODE"
    printf '  TCP-домен:     %s\n' "$TCP_DOMAIN"
    printf '  XHTTP-домен:   %s\n' "$XHTTP_DOMAIN"
    printf '  gRPC-домен:    %s\n' "$GRPC_DOMAIN"
    printf '\n'
    printf '  TCP tag:       %s\n' "$TCP_TAG"
    printf '  XHTTP tag:     %s\n' "$XHTTP_TAG"
    printf '  gRPC tag:      %s\n' "$GRPC_TAG"
    printf '  XHTTP path:    %s\n' "$XHTTP_PATH"
    printf '  gRPC service:  %s\n' "$GRPC_SERVICE"
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

    public_ip="$(external_ipv4)"
    [[ -n "$public_ip" ]] &&
        info "Внешний IPv4: $public_ip"

    for domain in "$TCP_DOMAIN" "$XHTTP_DOMAIN" "$GRPC_DOMAIN"; do
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
    docker ps --format \
        'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
        > "$BACKUP_DIR/docker-before.txt" || true

    ok "Бэкап: $BACKUP_DIR"
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

    if local_port_ready 1443 &&
       local_port_ready 2443 &&
       local_port_ready 3443; then
        ok "Все три Xray inbound уже работают."
        return 0
    fi

    printf '\n%sВ Remnawave Panel создай три inbound:%s\n' \
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

    read -r -p \
        "После сохранения шаблона и Redeploy/Restart нажми Enter..."

    local start_time
    local elapsed
    local tcp
    local xhttp
    local grpc

    start_time="$(date +%s)"

    while true; do
        tcp="нет"
        xhttp="нет"
        grpc="нет"

        local_port_ready 1443 && tcp="OK"
        local_port_ready 2443 && xhttp="OK"
        local_port_ready 3443 && grpc="OK"

        printf '\rTCP=%-3s  XHTTP=%-3s  gRPC=%-3s' \
            "$tcp" "$xhttp" "$grpc"

        if [[ "$tcp" == "OK" &&
              "$xhttp" == "OK" &&
              "$grpc" == "OK" ]]; then
            printf '\n'
            ok "Все Xray inbound работают."
            return 0
        fi

        elapsed=$(( $(date +%s) - start_time ))

        if (( elapsed >= WAIT_TIMEOUT )); then
            printf '\n'
            ss -ltnp |
                grep -E ':443|:1443|:2443|:3443' || true
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

    printf '\n'
    info "HAProxy logs: docker logs -f haproxy"
    info "Бэкап: $BACKUP_DIR"
    ok "Настройка завершена."
}

show_intro() {
    printf '%sRemnawave multi-transport installer v%s%s\n' \
        "$BOLD" "$VERSION" "$RESET"

    printf '\n%sЧто делает скрипт:%s\n' "$BOLD" "$RESET"
    printf '  • Объединяет TCP, XHTTP и gRPC на одном внешнем порту 443.\n'
    printf '  • Проверяет Docker, Caddy, Remnanode, DNS-записи и нужные порты.\n'
    printf '  • Создаёт резервную копию текущих конфигураций.\n'
    printf '  • Настраивает Caddy и HAProxy.\n'
    printf '  • Ограничивает логи HAProxy тремя файлами по 10 МБ.\n'
    printf '  • Показывает параметры трёх inbound для Remnawave Panel.\n'
    printf '  • Дожидается запуска inbound и выводит готовые параметры Hosts.\n'
}

status_only() {
    need_root
    need_cmd docker
    need_cmd ss

    printf '%sRemnawave multi-transport installer v%s%s\n\n' \
        "$BOLD" "$VERSION" "$RESET"

    ss -ltnp |
        grep -E ':80|:443|:2222|:1443|:2443|:3443' || true

    printf '\n'

    docker ps \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' |
        grep -E 'NAMES|haproxy|caddy|remna' || true

    printf '\n'

    [[ -S "$CADDY_SOCKET" ]] &&
        ok "Caddy socket: OK" ||
        warn "Caddy socket: MISSING"
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

    collect_values
    preflight
    backup_configs
    configure_caddy
    configure_haproxy
    wait_for_xray
    start_haproxy
    final_status
}

main "$@"
