#!/usr/bin/env bash
set -Eeuo pipefail

# Безопасно переключает основной публичный IPv4 в Netplan.
# Поддерживаемый сценарий: Ubuntu/Netplan, статические IPv4, default gateway
# уже указан в исходном YAML, новый адрес использует ту же маску, что и старый.

OK='[OK]'
INFO='[..]'
WARN='[!!]'
FAIL='[FAIL]'

say_ok()   { printf '%s %s\n' "$OK" "$*"; }
say_info() { printf '%s %s\n' "$INFO" "$*"; }
say_warn() { printf '%s %s\n' "$WARN" "$*" >&2; }
say_fail() { printf '%s %s\n' "$FAIL" "$*" >&2; }

die() {
  say_fail "$*"
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите скрипт через sudo или от root."

# Не допускаем одновременный запуск двух копий.
exec 9>/run/lock/netplan-switch-primary-ip.lock
flock -n 9 || die "Другая копия скрипта уже запущена."

command -v netplan >/dev/null 2>&1 || die "Команда netplan не найдена."
command -v systemd-run >/dev/null 2>&1 || die "Команда systemd-run не найдена."
command -v ip >/dev/null 2>&1 || die "Команда ip не найдена."
command -v python3 >/dev/null 2>&1 || die "Python 3 не найден."

validate_ipv4() {
  local ip=$1 IFS=. octets octet
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

OLD_IP=${1:-}
NEW_IP=${2:-}

if [[ -z $OLD_IP ]]; then
  read -r -p "Старый основной IPv4: " OLD_IP </dev/tty
fi
if [[ -z $NEW_IP ]]; then
  read -r -p "Новый основной IPv4: " NEW_IP </dev/tty
fi

validate_ipv4 "$OLD_IP" || die "Некорректный старый IPv4: $OLD_IP"
validate_ipv4 "$NEW_IP" || die "Некорректный новый IPv4: $NEW_IP"
[[ $OLD_IP != "$NEW_IP" ]] || die "Старый и новый IP совпадают."
say_ok "Входные IP проверены."

# Зависимости устанавливаются до изменения сети.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  say_info "Устанавливаю python3-yaml..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "Не удалось обновить список пакетов."
  apt-get install -y -qq python3-yaml || die "Не удалось установить python3-yaml."
fi
say_ok "PyYAML доступен."

if ! command -v curl >/dev/null 2>&1; then
  say_info "Устанавливаю curl..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "Не удалось обновить список пакетов."
  apt-get install -y -qq curl || die "Не удалось установить curl."
fi
say_ok "curl доступен."

STAMP=$(date -u +%Y%m%dT%H%M%SZ)-$$
BACKUP_DIR="/root/netplan-switch-backups/$STAMP"
mkdir -p "$BACKUP_DIR"
cp -a /etc/netplan "$BACKUP_DIR/netplan"
mkdir -p "$BACKUP_DIR/iproute2"
if [[ -f /etc/iproute2/rt_tables ]]; then
  cp -a /etc/iproute2/rt_tables "$BACKUP_DIR/iproute2/rt_tables"
else
  : > "$BACKUP_DIR/iproute2/rt_tables"
fi
say_ok "Резервная копия: $BACKUP_DIR"

META_FILE=$(mktemp)
ROLLBACK_UNIT="netplan-switch-rollback-${STAMP,,}"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
MODIFIED=0
COMMITTED=0
ROLLBACK_SCHEDULED=0

cancel_rollback_timer() {
  if (( ROLLBACK_SCHEDULED )); then
    systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
    systemctl stop "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
    ROLLBACK_SCHEDULED=0
  fi
}

restore_now() {
  say_warn "Восстанавливаю исходную сеть..."
  rm -rf /etc/netplan
  cp -a "$BACKUP_DIR/netplan" /etc/netplan
  mkdir -p /etc/iproute2
  cp -a "$BACKUP_DIR/iproute2/rt_tables" /etc/iproute2/rt_tables
  netplan generate >/dev/null 2>&1 || true
  netplan apply >/dev/null 2>&1 || true
  cancel_rollback_timer
  say_warn "Исходная конфигурация восстановлена."
}

on_exit() {
  local rc=$?
  rm -f "$META_FILE"
  if (( rc != 0 && MODIFIED == 1 && COMMITTED == 0 )); then
    restore_now
  fi
  exit "$rc"
}
trap on_exit EXIT

# Ищем YAML и интерфейс по старому IP, извлекаем MAC/gateway,
# затем идемпотентно обновляем только найденный интерфейс.
python3 - "$OLD_IP" "$NEW_IP" "$META_FILE" <<'PY'
import glob
import ipaddress
import os
import sys
import tempfile
import yaml

old_ip, new_ip, meta_path = sys.argv[1:4]
old_obj = ipaddress.ip_address(old_ip)
new_obj = ipaddress.ip_address(new_ip)

candidates = []
for path in sorted(glob.glob('/etc/netplan/*.yaml')) + sorted(glob.glob('/etc/netplan/*.yml')):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f) or {}
    except Exception as exc:
        raise SystemExit(f'Не удалось прочитать {path}: {exc}')

    ethernets = ((data.get('network') or {}).get('ethernets') or {})
    for iface_name, iface in ethernets.items():
        if not isinstance(iface, dict):
            continue
        for addr in iface.get('addresses') or []:
            try:
                ipif = ipaddress.ip_interface(str(addr))
            except ValueError:
                continue
            if ipif.ip == old_obj:
                candidates.append((path, data, iface_name, iface, ipif.network.prefixlen))

if not candidates:
    raise SystemExit(f'Старый IP {old_ip} не найден в /etc/netplan/*.yaml')
if len(candidates) != 1:
    where = ', '.join(f'{p}:{i}' for p, _, i, _, _ in candidates)
    raise SystemExit(f'Старый IP найден неоднозначно: {where}')

path, data, iface_name, iface, prefix = candidates[0]
match = iface.get('match') or {}
mac = str(match.get('macaddress') or '').strip()
if not mac:
    raise SystemExit('В найденном интерфейсе отсутствует match.macaddress')

# Проверяем MAC.
parts = mac.split(':')
if len(parts) != 6 or any(len(p) != 2 or any(c not in '0123456789abcdefABCDEF' for c in p) for p in parts):
    raise SystemExit(f'Некорректный MAC в конфиге: {mac}')

old_cidr = f'{old_ip}/{prefix}'
new_cidr = f'{new_ip}/{prefix}'

# Новый адрес первым, старый вторым; остальные адреса сохраняются без дублей.
remaining = []
seen = {old_ip, new_ip}
for addr in iface.get('addresses') or []:
    try:
        ipif = ipaddress.ip_interface(str(addr))
        if str(ipif.ip) in seen:
            continue
    except ValueError:
        pass
    if str(addr) not in remaining:
        remaining.append(str(addr))
iface['addresses'] = [new_cidr, old_cidr] + remaining
iface['dhcp4'] = False

routes = iface.get('routes') or []
if not isinstance(routes, list):
    raise SystemExit('Поле routes должно быть списком')

def is_default(route):
    return isinstance(route, dict) and str(route.get('to', '')).lower() in ('default', '0.0.0.0/0')

main_default = None
kept_routes = []
for route in routes:
    if not isinstance(route, dict):
        kept_routes.append(route)
        continue
    table = route.get('table')
    try:
        table_num = int(table) if table is not None else None
    except (TypeError, ValueError):
        table_num = {'main': 254, 'custom': 100}.get(str(table).lower())
    if is_default(route) and (table_num is None or table_num == 254):
        if main_default is None:
            main_default = dict(route)
        continue
    if is_default(route) and table_num == 100:
        continue
    kept_routes.append(route)

gateway4 = iface.pop('gateway4', None)
if main_default is None:
    if gateway4:
        main_default = {'to': '0.0.0.0/0', 'via': str(gateway4)}
    else:
        raise SystemExit('В интерфейсе не найден основной default route/gateway')

via = str(main_default.get('via') or '').strip()
if not via:
    raise SystemExit('У основного default route отсутствует via')

main_default['to'] = '0.0.0.0/0'
main_default['via'] = via
main_default.pop('table', None)
main_default['on-link'] = True
main_default['from'] = new_cidr

custom_default = dict(main_default)
custom_default['table'] = 100

iface['routes'] = kept_routes + [main_default, custom_default]

policies = iface.get('routing-policy') or []
if not isinstance(policies, list):
    raise SystemExit('Поле routing-policy должно быть списком')

kept_policies = []
used_priorities = set()
for rule in policies:
    if not isinstance(rule, dict):
        kept_policies.append(rule)
        continue
    try:
        table = int(rule.get('table')) if rule.get('table') is not None else None
    except (TypeError, ValueError):
        table = None
    if table == 100:
        continue
    if rule.get('priority') is not None:
        try:
            used_priorities.add(int(rule['priority']))
        except (TypeError, ValueError):
            pass
    kept_policies.append(rule)

priority = 100
while priority in used_priorities:
    priority += 1

iface['routing-policy'] = kept_policies + [{
    'from': new_cidr,
    'table': 100,
    'priority': priority,
}]

# Атомарная запись с сохранением прав файла.
dirname = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(prefix='.netplan-switch-', suffix='.yaml', dir=dirname)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
        f.flush()
        os.fsync(f.fileno())
    st = os.stat(path)
    os.chmod(tmp_path, st.st_mode & 0o777)
    try:
        os.chown(tmp_path, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)

with open(meta_path, 'w', encoding='utf-8') as f:
    f.write(f'NETPLAN_FILE={path}\n')
    f.write(f'IFACE_KEY={iface_name}\n')
    f.write(f'MAC={mac.lower()}\n')
    f.write(f'PREFIX={prefix}\n')
    f.write(f'GATEWAY={via}\n')
    f.write(f'PRIORITY={priority}\n')
PY

# shellcheck disable=SC1090
source "$META_FILE"
MODIFIED=1
say_ok "Netplan обновлён: $NETPLAN_FILE"
say_ok "MAC найден автоматически: $MAC"
say_ok "Интерфейс: $IFACE_KEY, gateway: $GATEWAY"

# Нормализуем 100 custom: не допускаем конфликтующего имени и дублей.
mkdir -p /etc/iproute2
RT_TABLES=/etc/iproute2/rt_tables
touch "$RT_TABLES"
if awk '!/^[[:space:]]*#/ && $1 == 100 && $2 != "custom" {found=1} END{exit !found}' "$RT_TABLES"; then
  die "Таблица 100 уже занята другим именем в $RT_TABLES."
fi
RT_TMP=$(mktemp)
awk '!(!/^[[:space:]]*#/ && $1 == 100 && $2 == "custom") {print}' "$RT_TABLES" > "$RT_TMP"
printf '100 custom\n' >> "$RT_TMP"
chmod --reference="$RT_TABLES" "$RT_TMP" 2>/dev/null || chmod 644 "$RT_TMP"
chown --reference="$RT_TABLES" "$RT_TMP" 2>/dev/null || true
mv "$RT_TMP" "$RT_TABLES"
say_ok "Таблица 100 custom настроена без дублей."

if ! netplan generate; then
  die "netplan generate завершился ошибкой."
fi
say_ok "Синтаксис Netplan корректен."

cat > "$ROLLBACK_SCRIPT" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -u
rm -rf /etc/netplan
cp -a '$BACKUP_DIR/netplan' /etc/netplan
mkdir -p /etc/iproute2
cp -a '$BACKUP_DIR/iproute2/rt_tables' /etc/iproute2/rt_tables
netplan generate >/dev/null 2>&1 && netplan apply >/dev/null 2>&1
EOF_ROLLBACK
chmod 700 "$ROLLBACK_SCRIPT"

# Независимый от SSH таймер отката. Если сессия оборвётся, systemd вернёт сеть.
systemd-run \
  --quiet \
  --unit="$ROLLBACK_UNIT" \
  --on-active=90s \
  --timer-property=AccuracySec=1s \
  /bin/bash "$ROLLBACK_SCRIPT"
ROLLBACK_SCHEDULED=1
say_ok "Автооткат запланирован через 90 секунд."

say_info "Применяю Netplan..."
if ! timeout 45s netplan apply; then
  die "Не удалось применить Netplan."
fi
say_ok "Netplan применён."

sleep 3

ip -4 addr show | grep -Fq "$NEW_IP/" || die "Новый IP не появился на интерфейсе."
say_ok "Новый IP назначен интерфейсу."

ip route show table 100 | grep -Eq '^default .* dev ' || die "В таблице 100 нет default route."
say_ok "Default route в таблице 100 найден."

ip rule show | grep -Eq "from ${NEW_IP}(/32)? .*lookup (100|custom)" || die "Policy rule для нового IP не найден."
say_ok "Policy rule для нового IP найден."

ROUTE_LINE=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)
if [[ $ROUTE_LINE != *"src $NEW_IP"* ]]; then
  die "Основной маршрут выбрал другой source IP: ${ROUTE_LINE:-нет данных}"
fi
say_ok "Маршрут по умолчанию выбирает $NEW_IP."

EXTERNAL_IP=''
for _ in 1 2 3; do
  EXTERNAL_IP=$(curl -4fsS \
    --connect-timeout 8 \
    --max-time 15 \
    -A 'netplan-switch-primary-ip/1.0' \
    https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n $EXTERNAL_IP ]] && break
  sleep 2
done

[[ -n $EXTERNAL_IP ]] || die "ifconfig.me не ответил; изменение не подтверждено."
[[ $EXTERNAL_IP == "$NEW_IP" ]] || die "ifconfig.me показал $EXTERNAL_IP вместо $NEW_IP."
say_ok "ifconfig.me подтвердил новый IP: $EXTERNAL_IP"

COMMITTED=1
cancel_rollback_timer
say_ok "Автооткат отменён — конфигурация сохранена."
printf '\n%s Готово. Старый IP: %s, новый основной: %s, MAC: %s\n' "$OK" "$OLD_IP" "$NEW_IP" "$MAC"
printf '%s Резервная копия: %s\n' "$INFO" "$BACKUP_DIR"
