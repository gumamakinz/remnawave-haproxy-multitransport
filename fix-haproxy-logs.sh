#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
COMPOSE_FILE="${HAPROXY_COMPOSE_FILE:-/opt/haproxy/docker-compose.yml}"
SERVICE="${HAPROXY_SERVICE:-haproxy}"
MAX_SIZE="10m"
MAX_FILE="3"

ok()   { printf '\033[0;32m✅ %s\033[0m\n' "$*"; }
info() { printf '\033[0;34mℹ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти скрипт от root."
command -v docker >/dev/null 2>&1 || die "Docker не найден."
command -v python3 >/dev/null 2>&1 || die "Python 3 не найден."
docker compose version >/dev/null 2>&1 || die "Docker Compose не найден."
[[ -f "$COMPOSE_FILE" ]] || die "Не найден $COMPOSE_FILE"

printf 'HAProxy log rotation fixer v%s\n\n' "$VERSION"

BACKUP_FILE="${COMPOSE_FILE}.backup-$(date +%Y%m%d-%H%M%S-%N)"
cp -a "$COMPOSE_FILE" "$BACKUP_FILE"
ok "Создан бэкап: $BACKUP_FILE"

PATCH_RESULT="$(python3 - "$COMPOSE_FILE" "$MAX_SIZE" "$MAX_FILE" <<'PY'
import os
import re
import stat
import sys
import tempfile

path, max_size, max_file = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    original = stream.read()

lines = original.splitlines(keepends=True)
newline = "\r\n" if "\r\n" in original else "\n"

service_re = re.compile(r"^  haproxy:\s*(?:#.*)?(?:\r?\n)?$")
top_service_re = re.compile(r"^  [A-Za-z0-9_.-]+:\s*(?:#.*)?(?:\r?\n)?$")
service_key_re = re.compile(r"^    [A-Za-z0-9_.-]+:\s*(?:#.*)?(?:\r?\n)?$")

start = next((i for i, line in enumerate(lines) if service_re.match(line)), None)
if start is None:
    raise SystemExit("В Compose не найден сервис haproxy.")

end = next(
    (i for i in range(start + 1, len(lines)) if top_service_re.match(lines[i])),
    len(lines),
)

logging_start = next(
    (i for i in range(start + 1, end) if re.match(r"^    logging:\s*", lines[i])),
    None,
)

block = [
    f"    logging:{newline}",
    f"      driver: local{newline}",
    f"      options:{newline}",
    f"        max-size: \"{max_size}\"{newline}",
    f"        max-file: \"{max_file}\"{newline}",
]

if logging_start is not None:
    logging_end = next(
        (i for i in range(logging_start + 1, end) if service_key_re.match(lines[i])),
        end,
    )
    lines[logging_start:logging_end] = block
else:
    insert_at = next(
        (i for i in range(start + 1, end) if re.match(r"^    command:\s*", lines[i])),
        end,
    )
    lines[insert_at:insert_at] = block

updated = "".join(lines)
if updated == original:
    print("unchanged")
    raise SystemExit(0)

directory = os.path.dirname(path)
metadata = os.stat(path)
fd, temporary = tempfile.mkstemp(prefix=".docker-compose.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
        stream.write(updated)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    os.replace(temporary, path)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise

print("updated")
PY
)" || {
    cp -a "$BACKUP_FILE" "$COMPOSE_FILE"
    die "Не удалось изменить Compose. Восстановлен бэкап."
}

if [[ "$PATCH_RESULT" == "updated" ]]; then
    ok "В Compose добавлены ограничения логов."
else
    info "В Compose уже указаны нужные ограничения логов."
fi

if ! docker compose -f "$COMPOSE_FILE" config >/dev/null; then
    cp -a "$BACKUP_FILE" "$COMPOSE_FILE"
    die "Compose не прошёл проверку. Восстановлен бэкап."
fi
ok "Конфигурация Compose валидна."

CURRENT_DRIVER="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$SERVICE" 2>/dev/null || true)"
CURRENT_SIZE="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$SERVICE" 2>/dev/null || true)"
CURRENT_FILES="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-file"}}' "$SERVICE" 2>/dev/null || true)"

if [[ "$CURRENT_DRIVER" == "local" &&
      "$CURRENT_SIZE" == "$MAX_SIZE" &&
      "$CURRENT_FILES" == "$MAX_FILE" ]]; then
    info "Контейнер уже использует нужные ограничения; пересоздание не требуется."
else
    info "Пересоздаю только контейнер HAProxy..."
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$SERVICE"
fi

DRIVER="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$SERVICE")"
SIZE="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$SERVICE")"
FILES="$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-file"}}' "$SERVICE")"
RUNNING="$(docker inspect -f '{{.State.Running}}' "$SERVICE")"

[[ "$RUNNING" == "true" ]] || die "Контейнер HAProxy не запущен."
[[ "$DRIVER" == "local" ]] || die "Не применился logging driver local."
[[ "$SIZE" == "$MAX_SIZE" ]] || die "Не применился max-size=$MAX_SIZE."
[[ "$FILES" == "$MAX_FILE" ]] || die "Не применился max-file=$MAX_FILE."

printf '\n'
ok "Готово: HAProxy использует local, ${MAX_SIZE} × ${MAX_FILE} файла."
info "Бэкап: $BACKUP_FILE"
df -h /
