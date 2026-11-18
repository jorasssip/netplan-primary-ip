#!/usr/bin/env bash
set -Eeuo pipefail

# netplan-primary-ip installer v3.1.0
# Переключает основной публичный IPv4 через Netplan policy routing и умеет
# безопасно возвращать конфигурацию к исходному единственному IPv4.

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

command -v flock >/dev/null 2>&1 || die "Команда flock не найдена."
exec 9>/run/lock/netplan-primary-ip.lock
flock -n 9 || die "Другая копия скрипта уже запущена."

for required_command in netplan systemd-run systemctl ip python3 awk grep timeout; do
  command -v "$required_command" >/dev/null 2>&1 || die "Команда $required_command не найдена."
done

INTERACTIVE=0
(( $# == 0 )) && INTERACTIVE=1
MODE=${1:-}
NEW_IP=${2:-}
(( $# <= 2 )) || die "Слишком много аргументов. Использование: install.sh [1 NEW_IP | 2]"

if [[ -z $MODE ]]; then
  while true; do
    printf '\nВыберите действие:\n' >/dev/tty
    printf '  1) Установить или заменить новый основной IPv4\n' >/dev/tty
    printf '  2) Откатиться к одному исходному IPv4\n' >/dev/tty
    read -r -p "Ваш выбор [1/2]: " MODE </dev/tty || die "Не удалось прочитать выбор из терминала."
    [[ $MODE == 1 || $MODE == 2 ]] && break
    say_warn "Введите 1 или 2."
  done
elif [[ $MODE != 1 && $MODE != 2 ]]; then
  die "Неизвестный режим '$MODE'. Допустимы только 1 и 2."
fi

if [[ $MODE == 2 && -n $NEW_IP ]]; then
  die "Для режима отката IP указывать не нужно."
fi

APT_UPDATED=0
install_apt_package() {
  local package=$1
  command -v apt-get >/dev/null 2>&1 || die "Для установки $package требуется apt-get."
  export DEBIAN_FRONTEND=noninteractive
  if (( APT_UPDATED == 0 )); then
    say_info "Обновляю список пакетов..."
    apt-get update -qq || die "Не удалось обновить список пакетов."
    APT_UPDATED=1
  fi
  apt-get install -y -qq "$package" || die "Не удалось установить $package."
}

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  say_info "Устанавливаю python3-yaml..."
  install_apt_package python3-yaml
fi
say_ok "PyYAML доступен."

if ! command -v curl >/dev/null 2>&1; then
  say_info "Устанавливаю curl..."
  install_apt_package curl
fi
say_ok "curl доступен."

validate_ipv4() {
  local ip=$1 IFS=. octets octet
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

META_FILE=$(mktemp)
PY_HELPER=$(mktemp)
RT_TMP=''
BACKUP_DIR=''
ROLLBACK_UNIT=''
ROLLBACK_SCRIPT=''
COMMIT_MARKER=''
ROLLED_BACK_MARKER=''
ROLLBACK_DELAY=180
ROLLBACK_STARTED_AT=0
MODIFIED=0
COMMITTED=0
ROLLBACK_SCHEDULED=0

cancel_rollback_timer() {
  local waited=0
  if (( ROLLBACK_SCHEDULED )); then
    if ! systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1; then
      return 1
    fi
    # Сервис отката не убиваем посреди работы: даём ему закончить, иначе
    # сеть останется в промежуточном состоянии.
    while systemctl is-active --quiet "$ROLLBACK_UNIT.service" && (( waited < 60 )); do
      sleep 1
      waited=$((waited + 1))
    done
    systemctl reset-failed "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
    ROLLBACK_SCHEDULED=0
  fi
}

restore_now() {
  say_warn "Восстанавливаю исходную сеть..."

  if [[ -n ${NETPLAN_FILE:-} && -n $BACKUP_DIR ]]; then
    local backup_netplan_file="$BACKUP_DIR/netplan/$(basename "$NETPLAN_FILE")"
    if [[ -f $backup_netplan_file ]]; then
      cp -a -- "$backup_netplan_file" "$NETPLAN_FILE"
    fi
  fi

  if [[ -n $BACKUP_DIR ]]; then
    mkdir -p /etc/iproute2
    if [[ -f $BACKUP_DIR/iproute2/rt_tables.existed ]]; then
      cp -a -- "$BACKUP_DIR/iproute2/rt_tables" /etc/iproute2/rt_tables
    else
      rm -f -- /etc/iproute2/rt_tables
    fi
  fi

  netplan generate >/dev/null 2>&1 || true
  netplan apply >/dev/null 2>&1 || true
  cancel_rollback_timer || true
  say_warn "Исходная конфигурация восстановлена."
}

on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && MODIFIED == 1 && COMMITTED == 0 )); then
    restore_now
  fi
  if [[ -n $RT_TMP ]]; then
    rm -f -- "$RT_TMP" || true
  fi
  rm -f -- "$META_FILE" "$PY_HELPER" || true
  exit "$rc"
}
trap on_exit EXIT

cat > "$PY_HELPER" <<'PY_HELPER_EOF'
import glob
import ipaddress
import os
import shlex
import sys
import tempfile

import yaml


class ConfigError(Exception):
    pass


UNKNOWN_TABLE = object()


def table_id(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return UNKNOWN_TABLE
    text = str(value).strip().lower()
    if text == "main":
        return 254
    if text == "custom":
        return 100
    try:
        return int(text, 10)
    except ValueError:
        return UNKNOWN_TABLE


def is_default(route):
    """IPv4 default route. `to: default` с IPv6-шлюзом сюда не относится."""
    if not isinstance(route, dict):
        return False
    to = str(route.get("to", "")).strip().lower()
    if to == "0.0.0.0/0":
        return True
    if to != "default":
        return False
    via = str(route.get("via") or "").strip()
    try:
        return ipaddress.ip_address(via).version == 4
    except ValueError:
        return True


def load_records(netplan_dir):
    paths = sorted(
        set(glob.glob(os.path.join(netplan_dir, "*.yaml")))
        | set(glob.glob(os.path.join(netplan_dir, "*.yml")))
    )
    if not paths:
        raise ConfigError(f"В {netplan_dir} не найдены файлы *.yaml или *.yml")

    records = []
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as stream:
                data = yaml.safe_load(stream) or {}
        except Exception as exc:
            raise ConfigError(f"Не удалось прочитать {path}: {exc}") from exc

        if not isinstance(data, dict):
            raise ConfigError(f"Корень {path} должен быть YAML-словарём")
        network = data.get("network") or {}
        if not isinstance(network, dict):
            raise ConfigError(f"Поле network в {path} должно быть словарём")
        ethernets = network.get("ethernets") or {}
        if not isinstance(ethernets, dict):
            raise ConfigError(f"Поле network.ethernets в {path} должно быть словарём")

        for iface_name, iface in ethernets.items():
            if not isinstance(iface, dict):
                raise ConfigError(f"Интерфейс {iface_name} в {path} должен быть словарём")

            addresses = iface.get("addresses") or []
            routes = iface.get("routes") or []
            policies = iface.get("routing-policy") or []
            if not isinstance(addresses, list):
                raise ConfigError(f"Поле addresses у {path}:{iface_name} должно быть списком")
            if not isinstance(routes, list):
                raise ConfigError(f"Поле routes у {path}:{iface_name} должно быть списком")
            if not isinstance(policies, list):
                raise ConfigError(f"Поле routing-policy у {path}:{iface_name} должно быть списком")

            ipv4_entries = []
            seen_ipv4 = set()
            for raw_address in addresses:
                try:
                    parsed = ipaddress.ip_interface(str(raw_address))
                except ValueError:
                    continue
                if parsed.version != 4:
                    continue
                ip_text = str(parsed.ip)
                if ip_text in seen_ipv4:
                    raise ConfigError(
                        f"IPv4 {ip_text} повторяется в addresses у {path}:{iface_name}"
                    )
                seen_ipv4.add(ip_text)
                ipv4_entries.append(
                    {
                        "ip": ip_text,
                        "prefix": parsed.network.prefixlen,
                        "raw": str(raw_address),
                    }
                )

            records.append(
                {
                    "key": (path, str(iface_name)),
                    "path": path,
                    "data": data,
                    "iface_name": str(iface_name),
                    "iface": iface,
                    "addresses": addresses,
                    "ipv4": ipv4_entries,
                    "routes": routes,
                    "policies": policies,
                }
            )
    return records


def main_default(record):
    found = []
    for index, route in enumerate(record["routes"]):
        if is_default(route) and table_id(route.get("table")) in (None, 254):
            found.append((index, dict(route)))

    gateway4 = record["iface"].get("gateway4")
    if gateway4 and found:
        raise ConfigError(
            f"У {record['path']}:{record['iface_name']} одновременно заданы gateway4 и основной default route"
        )
    if len(found) > 1:
        raise ConfigError(
            f"У {record['path']}:{record['iface_name']} найдено несколько основных default route"
        )
    if found:
        index, route = found[0]
    elif gateway4:
        index, route = None, {"to": "0.0.0.0/0", "via": str(gateway4)}
    else:
        raise ConfigError(
            f"У {record['path']}:{record['iface_name']} отсутствует основной default route/gateway4"
        )

    via = str(route.get("via") or "").strip()
    if not via:
        raise ConfigError(
            f"У основного default route в {record['path']}:{record['iface_name']} отсутствует via"
        )
    try:
        if ipaddress.ip_address(via).version != 4:
            raise ValueError
    except ValueError as exc:
        raise ConfigError(f"Некорректный IPv4 gateway {via}") from exc
    return index, route, via


def has_main_default(record):
    if record["iface"].get("gateway4"):
        return True
    return any(
        is_default(route) and table_id(route.get("table")) in (None, 254)
        for route in record["routes"]
        if isinstance(route, dict)
    )


def inspect_target(netplan_dir):
    records = load_records(netplan_dir)
    policy_candidates = []
    custom_route_owners = set()
    custom_activity = False
    conflicts = []

    for record in records:
        custom_sources = set()
        table_100_rules = []
        address_ips = {entry["ip"] for entry in record["ipv4"]}

        for rule in record["policies"]:
            if not isinstance(rule, dict):
                continue
            if table_id(rule.get("table")) != 100:
                continue
            custom_activity = True
            table_100_rules.append(rule)
            source = str(rule.get("from") or "").strip()
            try:
                parsed_source = ipaddress.ip_interface(source)
            except ValueError:
                conflicts.append(
                    f"правило table 100 без корректного IPv4 from у {record['path']}:{record['iface_name']}"
                )
                continue
            source_ip = str(parsed_source.ip)
            if parsed_source.version != 4 or source_ip not in address_ips:
                conflicts.append(
                    f"правило table 100 с from {source} не соответствует адресу {record['path']}:{record['iface_name']}"
                )
                continue
            custom_sources.add(source_ip)

        if table_100_rules:
            if len(custom_sources) != 1:
                conflicts.append(
                    f"у {record['path']}:{record['iface_name']} таблица 100 связана не с одним IPv4"
                )
            else:
                policy_candidates.append((record, next(iter(custom_sources))))

        for route in record["routes"]:
            if not isinstance(route, dict) or table_id(route.get("table")) != 100:
                continue
            custom_activity = True
            if not is_default(route):
                conflicts.append(
                    f"у {record['path']}:{record['iface_name']} есть неподдерживаемый не-default route table 100"
                )
            custom_route_owners.add(record["key"])

    if conflicts:
        raise ConfigError("Неоднозначная конфигурация: " + "; ".join(conflicts))

    if policy_candidates:
        unique_candidates = {
            (record["path"], record["iface_name"], source_ip)
            for record, source_ip in policy_candidates
        }
        if len(unique_candidates) != 1:
            details = ", ".join(f"{path}:{iface}:{ip}" for path, iface, ip in sorted(unique_candidates))
            raise ConfigError(f"Найдено несколько IP, связанных с table 100: {details}")

        record, custom_ip = policy_candidates[0]
        if custom_route_owners - {record["key"]}:
            raise ConfigError("Default route table 100 найден на другом интерфейсе")
        if not has_main_default(record):
            raise ConfigError("На интерфейсе с table 100 не найден основной default route")

        base_entries = [entry for entry in record["ipv4"] if entry["ip"] != custom_ip]
        if len(base_entries) != 1:
            raise ConfigError(
                f"Для {record['path']}:{record['iface_name']} не удалось однозначно определить исходный IPv4"
            )
        base_entry = base_entries[0]
        state_kind = "CUSTOM"
    else:
        if custom_activity:
            raise ConfigError(
                "Обнаружен route table 100, но нет policy rule, позволяющего определить дополнительный IPv4"
            )

        default_records = [record for record in records if has_main_default(record)]
        if len(default_records) != 1:
            details = ", ".join(
                f"{record['path']}:{record['iface_name']}" for record in default_records
            ) or "нет кандидатов"
            raise ConfigError(f"Основной интерфейс Netplan найден неоднозначно: {details}")
        record = default_records[0]
        if len(record["ipv4"]) != 1:
            raise ConfigError(
                f"В чистом режиме у {record['path']}:{record['iface_name']} должен быть ровно один статический IPv4"
            )
        base_entry = record["ipv4"][0]
        custom_ip = ""
        state_kind = "CLEAN"

    _, _, gateway = main_default(record)
    match = record["iface"].get("match") or {}
    if not isinstance(match, dict):
        raise ConfigError(f"Поле match у {record['path']}:{record['iface_name']} должно быть словарём")
    mac = str(match.get("macaddress") or "").strip().lower()
    parts = mac.split(":")
    if len(parts) != 6 or any(
        len(part) != 2 or any(char not in "0123456789abcdef" for char in part)
        for part in parts
    ):
        raise ConfigError(f"Некорректный или отсутствующий match.macaddress: {mac or 'не задан'}")

    return {
        "state": state_kind,
        "record": record,
        "path": record["path"],
        "iface_name": record["iface_name"],
        "mac": mac,
        "prefix": base_entry["prefix"],
        "base_ip": base_entry["ip"],
        "base_raw": base_entry["raw"],
        "custom_ip": custom_ip,
        "gateway": gateway,
    }


def write_shell_metadata(path, target):
    values = {
        "STATE_KIND": target["state"],
        "NETPLAN_FILE": target["path"],
        "IFACE_KEY": target["iface_name"],
        "MAC": target["mac"],
        "PREFIX": target["prefix"],
        "BASE_IP": target["base_ip"],
        "CUSTOM_IP": target["custom_ip"],
        "GATEWAY": target["gateway"],
    }
    with open(path, "w", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={shlex.quote(str(value))}\n")


def leading_comments(path):
    """Комментарии в начале файла (шапка cloud-init), которые safe_dump теряет."""
    header = []
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            if line.lstrip().startswith("#"):
                header.append(line if line.endswith("\n") else line + "\n")
            elif line.strip() == "" and header:
                continue
            else:
                break
    return header


def atomic_write(target):
    record = target["record"]
    path = record["path"]
    directory = os.path.dirname(path)
    header = leading_comments(path)
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".netplan-primary-ip-", suffix=".yaml", dir=directory
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.writelines(header)
            yaml.safe_dump(
                record["data"],
                stream,
                sort_keys=False,
                default_flow_style=False,
                allow_unicode=True,
            )
            stream.flush()
            os.fsync(stream.fileno())
        stat_result = os.stat(path)
        os.chmod(temporary_path, stat_result.st_mode & 0o777)
        try:
            os.chown(temporary_path, stat_result.st_uid, stat_result.st_gid)
        except (AttributeError, PermissionError):
            pass
        os.replace(temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


def apply_change(netplan_dir, mode, new_ip, expected_path, expected_base, expected_custom):
    target = inspect_target(netplan_dir)
    if (
        target["path"] != expected_path
        or target["base_ip"] != expected_base
        or target["custom_ip"] != expected_custom
    ):
        raise ConfigError("Конфигурация Netplan изменилась после проверки; повторите запуск")

    if mode == "1":
        try:
            new_obj = ipaddress.ip_address(new_ip)
        except ValueError as exc:
            raise ConfigError(f"Некорректный новый IPv4: {new_ip}") from exc
        if new_obj.version != 4:
            raise ConfigError(f"Ожидался IPv4, получен: {new_ip}")
        if str(new_obj) == target["base_ip"]:
            raise ConfigError("Новый IPv4 совпадает с неизменяемым исходным IPv4")
        if str(new_obj) == target["gateway"]:
            raise ConfigError("Новый IPv4 совпадает с gateway")
    elif mode != "2":
        raise ConfigError(f"Неизвестный режим: {mode}")

    record = target["record"]
    iface = record["iface"]
    removed_ipv4 = {target["base_ip"]}
    if target["custom_ip"]:
        removed_ipv4.add(target["custom_ip"])

    remaining_addresses = []
    seen_remaining = set()
    for raw_address in record["addresses"]:
        try:
            parsed = ipaddress.ip_interface(str(raw_address))
            if parsed.version == 4 and str(parsed.ip) in removed_ipv4:
                continue
        except ValueError:
            pass
        marker = str(raw_address)
        if marker not in seen_remaining:
            remaining_addresses.append(raw_address)
            seen_remaining.add(marker)

    if mode == "1":
        new_cidr = f"{new_ip}/{target['prefix']}"
        iface["addresses"] = [new_cidr, target["base_raw"]] + remaining_addresses
    else:
        iface["addresses"] = [target["base_raw"]] + remaining_addresses
    iface["dhcp4"] = False

    main_index, main_route, _ = main_default(record)
    kept_routes = []
    for index, route in enumerate(record["routes"]):
        if index == main_index:
            continue
        if isinstance(route, dict) and is_default(route) and table_id(route.get("table")) == 100:
            continue
        kept_routes.append(route)

    iface.pop("gateway4", None)
    main_route["to"] = "0.0.0.0/0"
    main_route["via"] = target["gateway"]
    main_route.pop("table", None)
    main_route.pop("from", None)
    main_route["on-link"] = True
    if mode == "1":
        # PreferredSource для основного default route. Только голый адрес,
        # без маски: `from: X/24` networkd не принимает и маршрут не ставится.
        # Без этого src зависит от порядка адресов в ядре, который netplan
        # apply не пересоздаёт, и при замене IP трафик уходит со старого адреса.
        main_route["from"] = new_ip
    normalized_routes = kept_routes + [main_route]
    if mode == "1":
        custom_route = dict(main_route)
        custom_route["table"] = 100
        normalized_routes.append(custom_route)
    iface["routes"] = normalized_routes

    kept_policies = []
    used_priorities = set()
    for rule in record["policies"]:
        if isinstance(rule, dict) and table_id(rule.get("table")) == 100:
            continue
        kept_policies.append(rule)
        if isinstance(rule, dict) and rule.get("priority") is not None:
            try:
                used_priorities.add(int(rule["priority"]))
            except (TypeError, ValueError):
                pass

    if mode == "1":
        priority = 100
        while priority in used_priorities:
            priority += 1
        iface["routing-policy"] = kept_policies + [
            {"from": f"{new_ip}/32", "table": 100, "priority": priority}
        ]
    elif kept_policies:
        iface["routing-policy"] = kept_policies
    else:
        iface.pop("routing-policy", None)

    atomic_write(target)


def main():
    try:
        action = sys.argv[1]
        if action == "inspect" and len(sys.argv) == 4:
            metadata_path, netplan_dir = sys.argv[2:4]
            write_shell_metadata(metadata_path, inspect_target(netplan_dir))
        elif action == "apply" and len(sys.argv) == 8:
            netplan_dir, mode, new_ip, expected_path, expected_base, expected_custom = sys.argv[2:8]
            apply_change(
                netplan_dir,
                mode,
                new_ip,
                expected_path,
                expected_base,
                expected_custom,
            )
        else:
            raise ConfigError("Некорректный внутренний вызов обработчика Netplan")
    except ConfigError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY_HELPER_EOF

python3 "$PY_HELPER" inspect "$META_FILE" /etc/netplan

# Значения записаны Python через shlex.quote; имена переменных фиксированы.
# shellcheck disable=SC1090
source "$META_FILE"

say_ok "Конфигурация найдена: $NETPLAN_FILE"
say_ok "Интерфейс: $IFACE_KEY, MAC: $MAC, gateway: $GATEWAY"

find_link_by_mac() {
  local path name mac
  if [[ -e /sys/class/net/$IFACE_KEY/address ]] \
    && [[ $(tr 'A-F' 'a-f' < "/sys/class/net/$IFACE_KEY/address") == "$MAC" ]]; then
    printf '%s\n' "$IFACE_KEY"
    return 0
  fi
  for path in /sys/class/net/*; do
    name=${path##*/}
    [[ -r $path/address ]] || continue
    [[ -e $path/master ]] && continue
    mac=$(tr 'A-F' 'a-f' < "$path/address")
    if [[ $mac == "$MAC" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

LINK=$(find_link_by_mac) || die "Не найден сетевой интерфейс с MAC $MAC."
say_ok "Интерфейс в системе: $LINK"

say_ok "Неизменяемый исходный IPv4: $BASE_IP/$PREFIX"
if [[ $STATE_KIND == CUSTOM ]]; then
  say_info "Текущий дополнительный основной IPv4: $CUSTOM_IP"
else
  say_info "Дополнительный IPv4 через 100 custom сейчас не настроен."
fi

if [[ $MODE == 2 && $STATE_KIND == CLEAN ]]; then
  say_ok "Откат не требуется: в Netplan уже настроен один исходный IPv4 $BASE_IP."
  exit 0
fi

if [[ $MODE == 1 ]]; then
  if [[ -n $NEW_IP ]]; then
    validate_ipv4 "$NEW_IP" || die "Некорректный новый IPv4: $NEW_IP"
    [[ $NEW_IP != "$BASE_IP" ]] || die "Новый IPv4 совпадает с неизменяемым исходным IPv4 $BASE_IP."
    [[ $NEW_IP != "$GATEWAY" ]] || die "Новый IPv4 совпадает с gateway $GATEWAY."
  else
    while true; do
      read -r -p "Новый основной IPv4: " NEW_IP </dev/tty || die "Не удалось прочитать IPv4 из терминала."
      if ! validate_ipv4 "$NEW_IP"; then
        say_warn "Некорректный IPv4. Повторите ввод."
        continue
      fi
      if [[ $NEW_IP == "$BASE_IP" ]]; then
        say_warn "Это неизменяемый исходный IPv4. Введите новый адрес."
        continue
      fi
      if [[ $NEW_IP == "$GATEWAY" ]]; then
        say_warn "IPv4 совпадает с gateway. Введите другой адрес."
        continue
      fi
      break
    done
  fi
  say_ok "Новый основной IPv4 проверен: $NEW_IP"
fi

RT_TABLES=/etc/iproute2/rt_tables
if [[ -f $RT_TABLES ]] && awk '
  !/^[[:space:]]*#/ && $1 == 100 && $2 != "custom" { conflict=1 }
  END { exit !conflict }
' "$RT_TABLES"; then
  die "Таблица 100 уже занята другим именем в $RT_TABLES."
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)-$$
BACKUP_DIR="/root/netplan-primary-ip-backups/$STAMP"
ROLLBACK_UNIT="netplan-primary-ip-rollback-${STAMP,,}"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
COMMIT_MARKER="$BACKUP_DIR/committed"
ROLLED_BACK_MARKER="$BACKUP_DIR/rolled-back"

mkdir -p "$BACKUP_DIR"
cp -a /etc/netplan "$BACKUP_DIR/netplan"
mkdir -p "$BACKUP_DIR/iproute2"
if [[ -f $RT_TABLES ]]; then
  cp -a -- "$RT_TABLES" "$BACKUP_DIR/iproute2/rt_tables"
  : > "$BACKUP_DIR/iproute2/rt_tables.existed"
else
  : > "$BACKUP_DIR/iproute2/rt_tables"
fi
say_ok "Резервная копия: $BACKUP_DIR"

python3 "$PY_HELPER" apply /etc/netplan "$MODE" "$NEW_IP" \
  "$NETPLAN_FILE" "$BASE_IP" "$CUSTOM_IP"
MODIFIED=1
say_ok "Netplan обновлён атомарно: $NETPLAN_FILE"

normalize_rt_tables() {
  local action=$1
  mkdir -p /etc/iproute2
  RT_TMP=$(mktemp "${RT_TABLES}.tmp.XXXXXX")

  if [[ -f $RT_TABLES ]]; then
    awk '!(!/^[[:space:]]*#/ && $1 == 100 && $2 == "custom") { print }' \
      "$RT_TABLES" > "$RT_TMP"
    chmod --reference="$RT_TABLES" "$RT_TMP" 2>/dev/null || chmod 644 "$RT_TMP"
    chown --reference="$RT_TABLES" "$RT_TMP" 2>/dev/null || true
  else
    : > "$RT_TMP"
    chmod 644 "$RT_TMP"
  fi

  if [[ $action == add ]]; then
    printf '100 custom\n' >> "$RT_TMP"
  fi
  mv -- "$RT_TMP" "$RT_TABLES"
  RT_TMP=''
}

if [[ $MODE == 1 ]]; then
  normalize_rt_tables add
  say_ok "Таблица 100 custom настроена без дублей."
else
  normalize_rt_tables remove
  say_ok "Запись 100 custom удалена."
fi

if ! netplan generate; then
  die "netplan generate завершился ошибкой."
fi
say_ok "Синтаксис Netplan корректен."

BACKUP_NETPLAN_FILE="$BACKUP_DIR/netplan/$(basename "$NETPLAN_FILE")"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -u'
  # Если основной скрипт уже подтвердил конфигурацию — ничего не делаем.
  printf '[[ -e %q ]] && exit 0\n' "$COMMIT_MARKER"
  printf ': > %q\n' "$ROLLED_BACK_MARKER"
  printf 'cp -a -- %q %q\n' "$BACKUP_NETPLAN_FILE" "$NETPLAN_FILE"
  printf '%s\n' 'mkdir -p /etc/iproute2'
  if [[ -f $BACKUP_DIR/iproute2/rt_tables.existed ]]; then
    printf 'cp -a -- %q %q\n' "$BACKUP_DIR/iproute2/rt_tables" "$RT_TABLES"
  else
    printf 'rm -f -- %q\n' "$RT_TABLES"
  fi
  printf '%s\n' 'netplan generate >/dev/null 2>&1 && netplan apply >/dev/null 2>&1'
} > "$ROLLBACK_SCRIPT"
chmod 700 "$ROLLBACK_SCRIPT"

systemd-run \
  --quiet \
  --unit="$ROLLBACK_UNIT" \
  --on-active="${ROLLBACK_DELAY}s" \
  --timer-property=AccuracySec=1s \
  /bin/bash "$ROLLBACK_SCRIPT"
ROLLBACK_SCHEDULED=1
ROLLBACK_STARTED_AT=$SECONDS
say_ok "Аварийный автооткат запланирован через $ROLLBACK_DELAY секунд."

say_info "Применяю Netplan..."
if ! timeout 45s netplan apply; then
  die "Не удалось применить Netplan."
fi
say_ok "Netplan применён."

# Точное совпадение адреса на целевом интерфейсе (без ложных 1.2.3.4 ⊂ 11.2.3.4).
has_addr() {
  ip -4 -o addr show dev "$LINK" 2>/dev/null \
    | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) found = 1 } END { exit !found }'
}

route_src() {
  local route_line
  route_line=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)
  [[ " $route_line " == *" src $1 "* ]]
}

state_ready() {
  if [[ $MODE == 1 ]]; then
    has_addr "$BASE_IP" && has_addr "$NEW_IP" && route_src "$NEW_IP"
  else
    has_addr "$BASE_IP" && { [[ -z $CUSTOM_IP ]] || ! has_addr "$CUSTOM_IP"; } && route_src "$BASE_IP"
  fi
}

say_info "Жду, пока networkd применит адреса и маршруты (до 20 с)..."
for _ in $(seq 1 20); do
  state_ready && break
  sleep 1
done

route_source_is() {
  local expected_ip=$1 route_line
  route_line=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)
  if [[ " $route_line " != *" src $expected_ip "* ]]; then
    die "Основной маршрут выбрал другой source IP: ${route_line:-нет данных}"
  fi
  say_ok "Основной маршрут использует source IP $expected_ip."
}

verify_external_ip() {
  local expected_ip=$1 external_ip='' attempt
  for attempt in 1 2 3; do
    external_ip=$(curl -4fsS \
      --connect-timeout 8 \
      --max-time 15 \
      -A 'netplan-primary-ip/3.1.0' \
      https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n $external_ip ]] && break
    sleep 2
  done
  [[ -n $external_ip ]] || die "ifconfig.me не ответил; изменение не подтверждено."
  [[ $external_ip == "$expected_ip" ]] || die "ifconfig.me показал $external_ip вместо $expected_ip."
  say_ok "ifconfig.me подтвердил основной IPv4: $external_ip"
}

if [[ $MODE == 1 ]]; then
  has_addr "$BASE_IP" || die "Исходный IPv4 исчез с интерфейса $LINK."
  has_addr "$NEW_IP" || die "Новый IPv4 не появился на интерфейсе $LINK."
  say_ok "Исходный и новый IPv4 назначены интерфейсу $LINK."

  main_default_line=$(ip -4 route show table main default 2>/dev/null | head -n1 || true)
  [[ " $main_default_line " == *" src $NEW_IP "* ]] \
    || die "У основного default route нет src $NEW_IP: ${main_default_line:-маршрут отсутствует}"
  say_ok "Основной default route закреплён за src $NEW_IP."

  ip -4 route show table 100 | grep -Eq '^default ' || die "В таблице 100 нет default route."
  say_ok "Default route в таблице 100 найден."

  escaped_new_ip=${NEW_IP//./\.}
  ip -4 rule show | grep -Eq "from ${escaped_new_ip}(/32)?[[:space:]].*lookup (100|custom)([[:space:]]|$)" \
    || die "Policy rule table 100 для нового IPv4 не найден."
  say_ok "Policy rule table 100 для $NEW_IP найден."

  if [[ -n $CUSTOM_IP && $CUSTOM_IP != "$NEW_IP" ]] && has_addr "$CUSTOM_IP"; then
    die "Предыдущий дополнительный IPv4 $CUSTOM_IP остался на интерфейсе."
  fi
  route_source_is "$NEW_IP"
  verify_external_ip "$NEW_IP"
else
  has_addr "$BASE_IP" || die "Исходный IPv4 не появился на интерфейсе $LINK."
  if has_addr "$CUSTOM_IP"; then
    die "Дополнительный IPv4 $CUSTOM_IP остался на интерфейсе."
  fi
  if ip -4 rule show | grep -Eq 'lookup (100|custom)([[:space:]]|$)'; then
    die "После отката осталось policy rule для таблицы 100."
  fi
  if ip -4 route show table 100 2>/dev/null | grep -Eq '^default '; then
    die "После отката в таблице 100 остался default route."
  fi
  say_ok "Дополнительный IPv4, route и policy rule таблицы 100 удалены."
  route_source_is "$BASE_IP"
  verify_external_ip "$BASE_IP"
fi

if (( SECONDS - ROLLBACK_STARTED_AT >= ROLLBACK_DELAY - 5 )); then
  die "Проверки заняли слишком много времени; автооткат мог уже начаться."
fi
: > "$COMMIT_MARKER"
if ! cancel_rollback_timer; then
  die "Не удалось отменить таймер автоотката; возвращаю исходную конфигурацию."
fi
if [[ -e $ROLLED_BACK_MARKER ]]; then
  die "Автооткат сработал раньше подтверждения; конфигурация не сохранена."
fi
COMMITTED=1
say_ok "Автооткат отменён — проверенная конфигурация сохранена."

if [[ $MODE == 1 ]]; then
  printf '\n%s Готово. Исходный IPv4: %s, новый основной: %s, MAC: %s\n' \
    "$OK" "$BASE_IP" "$NEW_IP" "$MAC"
else
  printf '\n%s Откат завершён. Единственный основной IPv4: %s, MAC: %s\n' \
    "$OK" "$BASE_IP" "$MAC"
fi
printf '%s Резервная копия: %s\n' "$INFO" "$BACKUP_DIR"

CLOUD_NET_DISABLE=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
if [[ $MODE == 1 && $(basename "$NETPLAN_FILE") == 50-cloud-init.yaml && -d /etc/cloud && ! -e $CLOUD_NET_DISABLE ]]; then
  say_warn "Файл $NETPLAN_FILE создан cloud-init. На части провайдеров cloud-init"
  say_warn "перегенерирует его при перезагрузке, и новый IPv4 пропадёт."
  answer=''
  if (( INTERACTIVE )); then
    read -r -p "Отключить управление сетью в cloud-init ($CLOUD_NET_DISABLE)? [y/N]: " answer </dev/tty || answer=''
  fi
  if [[ $answer == [yYдД]* ]]; then
    mkdir -p "$(dirname "$CLOUD_NET_DISABLE")"
    printf 'network: {config: disabled}\n' > "$CLOUD_NET_DISABLE"
    say_ok "Создан $CLOUD_NET_DISABLE — cloud-init больше не будет трогать сеть."
  else
    say_info "Чтобы закрепить настройку вручную:"
    say_info "  echo 'network: {config: disabled}' | sudo tee $CLOUD_NET_DISABLE"
  fi
fi
