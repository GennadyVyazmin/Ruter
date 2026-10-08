#!/usr/bin/env bash
set -Eeuo pipefail

# Ruter Gateway
# Universal sing-box policy-routing gateway manager.
# Clean Ruter installation layout.
# Installs required packages automatically, including curl.
# Provides a local mixed proxy and a LAN mixed proxy for services such as
# Prowlarr/FlareSolverr to use the same sing-box selector managed by MetaCubeXD.

RUTER_VERSION="2.1.2"

APP_DIR="/etc/ruter"
SETTINGS_FILE="$APP_DIR/settings.env"
SUB_FILE="$APP_DIR/subscription.txt"

SINGBOX_DIR="/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_DIR/config.json"
SINGBOX_BACKUP_DIR="/etc/sing-box-backups"
UI_DIR="$SINGBOX_DIR/ui"

ROUTE_SCRIPT="/usr/local/sbin/ruter-route.sh"
ROUTE_SERVICE="/etc/systemd/system/ruter-route.service"

MANAGER_DIR="/usr/local/lib/ruter"
MANAGER_PATH="$MANAGER_DIR/ruter.sh"
COMMAND_PATH="/usr/local/bin/ruter"

REPO_RAW_URL="${RUTER_REPO_RAW_URL:-https://raw.githubusercontent.com/GennadyVyazmin/Ruter/refs/heads/main/install.sh}"

DEFAULT_TABLE_ID="200"
DEFAULT_RULE_PRIORITY="100"
DEFAULT_SELF_RULE_PRIORITY="90"
DEFAULT_TUN_IFACE="sb-tun0"
DEFAULT_MIXED_PORT="2080"
DEFAULT_LAN_PROXY_PORT="2081"
DEFAULT_CLASH_PORT="9090"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'

info() { printf '%s\n' "${C_BLUE}i${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
fail() { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }

pause() {
  [ -t 0 ] || return 0
  echo
  read -r -p "Нажми Enter для продолжения..." _
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Запусти от root:"
    echo "  sudo ruter"
    echo "или:"
    echo "  sudo bash $0"
    exit 1
  fi
}

have_settings() {
  [ -f "$SETTINGS_FILE" ]
}

load_settings() {
  if ! have_settings; then
    fail "Настройки не найдены. Сначала выполни установку."
    return 1
  fi

  # shellcheck disable=SC1090
  source "$SETTINGS_FILE"

  TABLE_ID="${TABLE_ID:-$DEFAULT_TABLE_ID}"
  RULE_PRIORITY="${RULE_PRIORITY:-$DEFAULT_RULE_PRIORITY}"
  SELF_RULE_PRIORITY="${SELF_RULE_PRIORITY:-$DEFAULT_SELF_RULE_PRIORITY}"
  TUN_IFACE="${TUN_IFACE:-$DEFAULT_TUN_IFACE}"
  MIXED_PORT="${MIXED_PORT:-$DEFAULT_MIXED_PORT}"
  LAN_PROXY_PORT="${LAN_PROXY_PORT:-$DEFAULT_LAN_PROXY_PORT}"
  CLASH_PORT="${CLASH_PORT:-$DEFAULT_CLASH_PORT}"

  # Migration from v1.
  if [ -z "${ROUTE_SOURCES:-}" ] && [ -n "${ROUTE_SOURCE:-}" ]; then
    ROUTE_SOURCES="$ROUTE_SOURCE"
  fi

  ROUTE_MODE="${ROUTE_MODE:-sources}"
  ROUTE_SOURCES="${ROUTE_SOURCES:-}"
}

detect_network() {
  local default_line vm_cidr

  default_line="$(ip -4 route show default | head -n1 || true)"
  if [ -z "$default_line" ]; then
    fail "Не найден default route."
    exit 1
  fi

  LAN_IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$default_line")"
  LAN_GATEWAY="$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$default_line")"
  vm_cidr="$(ip -o -4 addr show dev "$LAN_IFACE" scope global | awk '{print $4}' | head -n1)"
  VM_IP="${vm_cidr%/*}"

  LAN_CIDR="$(ip -4 route show dev "$LAN_IFACE" scope link |
    awk '$1 ~ /\// {print $1; exit}')"

  if [ -z "${LAN_CIDR:-}" ]; then
    LAN_CIDR="$(python3 - "$vm_cidr" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  fi

  if [ -z "${LAN_IFACE:-}" ] ||
     [ -z "${LAN_GATEWAY:-}" ] ||
     [ -z "${VM_IP:-}" ] ||
     [ -z "${LAN_CIDR:-}" ]; then
    fail "Не удалось автоматически определить параметры сети."
    echo "LAN_IFACE=${LAN_IFACE:-}"
    echo "LAN_GATEWAY=${LAN_GATEWAY:-}"
    echo "VM_IP=${VM_IP:-}"
    echo "LAN_CIDR=${LAN_CIDR:-}"
    exit 1
  fi
}

confirm_network() {
  detect_network

  echo
  echo "Найдена сеть:"
  echo "  Интерфейс VM: $LAN_IFACE"
  echo "  IP VM:        $VM_IP"
  echo "  Роутер:       $LAN_GATEWAY"
  echo "  LAN:          $LAN_CIDR"
  echo

  local answer
  read -r -p "Всё верно? [Y/n]: " answer
  answer="${answer:-Y}"

  if [[ ! "$answer" =~ ^[YyДд]$ ]]; then
    read -r -p "Интерфейс VM: " LAN_IFACE
    read -r -p "IP VM: " VM_IP
    read -r -p "IP роутера: " LAN_GATEWAY
    read -r -p "LAN CIDR: " LAN_CIDR
  fi
}

normalize_source() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

value = sys.argv[1].strip()
try:
    if "/" in value:
        print(ipaddress.ip_network(value, strict=False))
    else:
        print(ipaddress.ip_address(value).compressed + "/32")
except ValueError:
    raise SystemExit(1)
PY
}

ask_route_mode() {
  local choice input normalized
  local -a sources=()

  echo
  echo "Тип маршрутизации:"
  echo "  1) Одно устройство"
  echo "  2) Несколько устройств"
  echo "  3) Вся LAN-подсеть"
  echo "  4) Маршрутизацию отключить"
  echo

  read -r -p "Выбор [1-4]: " choice

  case "$choice" in
    1)
      read -r -p "IP устройства: " input
      normalized="$(normalize_source "$input")" || {
        fail "Некорректный IP."
        return 1
      }
      ROUTE_MODE="sources"
      ROUTE_SOURCES="$normalized"
      ;;
    2)
      echo "Вводи IP устройств по одному. Пустая строка завершает ввод."
      while true; do
        read -r -p "IP: " input
        [ -z "$input" ] && break
        normalized="$(normalize_source "$input")" || {
          warn "Пропущено некорректное значение: $input"
          continue
        }
        sources+=("$normalized")
      done

      if [ "${#sources[@]}" -eq 0 ]; then
        fail "Не введено ни одного корректного IP."
        return 1
      fi

      ROUTE_MODE="sources"
      ROUTE_SOURCES="${sources[*]}"
      ;;
    3)
      ROUTE_MODE="lan"
      ROUTE_SOURCES="$LAN_CIDR"
      ;;
    4)
      ROUTE_MODE="disabled"
      ROUTE_SOURCES=""
      ;;
    *)
      fail "Неверный выбор."
      return 1
      ;;
  esac
}

save_settings() {
  mkdir -p "$APP_DIR"

  cat >"$SETTINGS_FILE" <<EOF
LAN_IFACE="$LAN_IFACE"
LAN_GATEWAY="$LAN_GATEWAY"
VM_IP="$VM_IP"
LAN_CIDR="$LAN_CIDR"

ROUTE_MODE="${ROUTE_MODE:-sources}"
ROUTE_SOURCES="${ROUTE_SOURCES:-}"

TABLE_ID="${TABLE_ID:-$DEFAULT_TABLE_ID}"
RULE_PRIORITY="${RULE_PRIORITY:-$DEFAULT_RULE_PRIORITY}"
SELF_RULE_PRIORITY="${SELF_RULE_PRIORITY:-$DEFAULT_SELF_RULE_PRIORITY}"

TUN_IFACE="${TUN_IFACE:-$DEFAULT_TUN_IFACE}"
MIXED_PORT="${MIXED_PORT:-$DEFAULT_MIXED_PORT}"
LAN_PROXY_PORT="${LAN_PROXY_PORT:-$DEFAULT_LAN_PROXY_PORT}"
CLASH_PORT="${CLASH_PORT:-$DEFAULT_CLASH_PORT}"
EOF

  chmod 600 "$SETTINGS_FILE"
}

migrate_settings() {
  load_settings || return 1
  save_settings
  ok "Настройки приведены к формату Ruter $RUTER_VERSION."
}

install_manager() {
  mkdir -p "$MANAGER_DIR"

  local source_path
  source_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

  if [ -f "$source_path" ] && [ "$source_path" != "$MANAGER_PATH" ]; then
    install -m 0755 "$source_path" "$MANAGER_PATH"
  elif [ "$source_path" = "$MANAGER_PATH" ]; then
    chmod 0755 "$MANAGER_PATH"
  else
    fail "Не удалось определить путь текущего скрипта."
    return 1
  fi

  ln -sfn "$MANAGER_PATH" "$COMMAND_PATH"
  ok "Установлена команда: ruter"
  echo "  $MANAGER_PATH"
  echo "  $COMMAND_PATH -> $MANAGER_PATH"
}

install_deps() {
  apt-get update
  apt-get install -y \
    curl wget ca-certificates iproute2 nftables python3 git unzip jq
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    ok "sing-box уже установлен: $(sing-box version | head -n1)"
    systemctl enable sing-box >/dev/null 2>&1 || true
    return
  fi

  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://sing-box.app/install.sh -o "$tmp"
  sh "$tmp"
  rm -f "$tmp"

  command -v sing-box >/dev/null 2>&1 || {
    fail "sing-box не появился в PATH."
    exit 1
  }

  systemctl enable sing-box >/dev/null 2>&1 || true
  ok "Установлен $(sing-box version | head -n1)"
}

install_ui() {
  mkdir -p "$SINGBOX_DIR"

  rm -rf "$UI_DIR"

  if ! git clone \
    --depth 1 \
    --single-branch \
    --branch gh-pages \
    https://github.com/MetaCubeX/metacubexd.git \
    "$UI_DIR"; then
    rm -rf "$UI_DIR"
    fail "Не удалось установить MetaCubeXD."
    return 1
  fi

  if [ ! -f "$UI_DIR/index.html" ]; then
    rm -rf "$UI_DIR"
    fail "MetaCubeXD установлен некорректно: не найден $UI_DIR/index.html"
    return 1
  fi

  ok "MetaCubeXD установлен."
}

read_subscription_input() {
  echo
  echo "Вставь:"
  echo "  • одну или несколько vless:// ссылок;"
  echo "  • либо URL подписки http/https."
  echo
  echo "Пустая строка завершает ввод."

  local input="" line
  while IFS= read -r line; do
    [ -z "$line" ] && break
    input+="$line"$'\n'
  done

  [ -n "$input" ] || {
    fail "Пустой ввод."
    return 1
  }

  mkdir -p "$APP_DIR"
  printf '%s' "$input" >"$SUB_FILE"
  chmod 600 "$SUB_FILE"
}

generate_singbox_config() {
  load_settings
  [ -s "$SUB_FILE" ] || {
    fail "Файл подписки отсутствует или пуст: $SUB_FILE"
    return 1
  }

  mkdir -p "$SINGBOX_DIR" "$SINGBOX_BACKUP_DIR"

  local candidate
  candidate="$(mktemp)"

  python3 - "$SUB_FILE" "$candidate" "$UI_DIR" "$TUN_IFACE" "$MIXED_PORT" "$CLASH_PORT" "$VM_IP" "$LAN_PROXY_PORT" <<'PY'
import base64
import ipaddress
import json
import os
import re
import sys
import urllib.parse
import urllib.request

sub_file, out_file, ui_dir, tun_iface, mixed_port, clash_port, vm_ip, lan_proxy_port = sys.argv[1:]
mixed_port = int(mixed_port)
clash_port = int(clash_port)
lan_proxy_port = int(lan_proxy_port)

raw = open(sub_file, "r", encoding="utf-8", errors="ignore").read().strip()

def fetch_if_url(value):
    value = value.strip()
    if value.startswith(("http://", "https://")):
        req = urllib.request.Request(
            value,
            headers={"User-Agent": "Mozilla/5.0 ruter-subscription-parser"},
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.read().decode("utf-8", errors="ignore")
    return value

def maybe_b64_decode(value):
    if "vless://" in value:
        return value
    compact = re.sub(r"\s+", "", value)
    for decoder in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            padding = "=" * (-len(compact) % 4)
            decoded = decoder((compact + padding).encode()).decode(
                "utf-8", errors="ignore"
            )
            if "vless://" in decoded:
                return decoded
        except Exception:
            pass
    return value

def first(query, *names, default=""):
    for name in names:
        values = query.get(name)
        if values:
            return values[0]
    return default

def sanitize_tag(name, fallback):
    name = urllib.parse.unquote(name or "")
    if not name:
        name = fallback

    translit = {
        "🇹🇷": "turk-",
        "🇫🇮": "finland-",
        "🇵🇱": "poland-",
        "🇩🇪": "germany-",
        "🇰🇿": "kz-",
        "🇮🇳": "india-",
    }
    for old, new in translit.items():
        name = name.replace(old, new)

    name = name.lower()
    name = re.sub(r"[^a-z0-9._-]+", "-", name)
    name = re.sub(r"-+", "-", name).strip("-")
    return name or fallback

content = maybe_b64_decode(fetch_if_url(raw))
links = re.findall(r"vless://[^\s\"'<>]+", content)
if not links and content.startswith("vless://"):
    links = [content]

if not links:
    raise SystemExit("Не найдено ни одной vless:// ссылки.")

outbounds = [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"},
]

tags = []
used_tags = {"direct", "block", "auto", "select"}
vps_ips = set()
skipped = []

for index, link in enumerate(links, start=1):
    try:
        url = urllib.parse.urlsplit(link)
        query = urllib.parse.parse_qs(url.query)

        server = url.hostname
        port = url.port
        uuid = urllib.parse.unquote(url.username or "")
        fragment = urllib.parse.unquote(url.fragment or "")

        if not server or not port or not uuid:
            skipped.append(f"#{index}: нет server/port/uuid")
            continue

        base_tag = sanitize_tag(fragment, f"proxy-{index}")
        tag = base_tag
        suffix = 2
        while tag in used_tags:
            tag = f"{base_tag}-{suffix}"
            suffix += 1

        sni = first(
            query, "sni", "serverName", "servername", default="www.nvidia.com"
        )
        public_key = first(
            query, "pbk", "public_key", "publicKey", "pubkey"
        )
        short_id = first(query, "sid", "short_id", "shortId")
        fingerprint = first(
            query, "fp", "fingerprint", default="chrome"
        )
        flow = first(query, "flow")
        network_type = first(query, "type", default="tcp").lower()

        if not public_key:
            skipped.append(f"{fragment or server}: нет pbk/public_key")
            continue

        transport = None
        if network_type == "tcp":
            pass
        elif network_type == "xhttp":
            skipped.append(
                f"{fragment or server}: type=xhttp не поддерживается transport sing-box"
            )
            continue
        elif network_type in ("http", "h2"):
            transport = {
                "type": "http",
                "path": first(query, "path", default="/") or "/",
                "method": first(query, "method", default="GET") or "GET",
            }
            host = first(query, "host")
            if host:
                transport["host"] = [host]
        elif network_type in ("ws", "websocket"):
            transport = {
                "type": "ws",
                "path": first(query, "path", default="/") or "/",
            }
            host = first(query, "host")
            if host:
                transport["headers"] = {"Host": host}
        elif network_type == "grpc":
            transport = {
                "type": "grpc",
                "service_name": first(
                    query, "serviceName", "service_name", "path"
                ),
            }
        elif network_type == "httpupgrade":
            transport = {
                "type": "httpupgrade",
                "path": first(query, "path", default="/") or "/",
            }
            host = first(query, "host")
            if host:
                transport["host"] = host
        else:
            skipped.append(
                f"{fragment or server}: type={network_type} не поддерживается"
            )
            continue

        outbound = {
            "type": "vless",
            "tag": tag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "packet_encoding": "xudp",
            "tls": {
                "enabled": True,
                "server_name": sni,
                "reality": {
                    "enabled": True,
                    "public_key": public_key,
                    "short_id": short_id,
                },
                "utls": {
                    "enabled": True,
                    "fingerprint": fingerprint,
                },
            },
        }

        if flow:
            outbound["flow"] = flow
        if transport:
            outbound["transport"] = transport

        used_tags.add(tag)
        tags.append(tag)
        outbounds.append(outbound)

        try:
            vps_ips.add(str(ipaddress.ip_address(server)) + "/32")
        except ValueError:
            pass

    except Exception as exc:
        skipped.append(f"#{index}: ошибка парсинга: {exc}")

if not tags:
    for item in skipped:
        print("Пропущено:", item, file=sys.stderr)
    raise SystemExit("Нет валидных VLESS outbound.")

if len(tags) > 1:
    outbounds.insert(
        2,
        {
            "type": "urltest",
            "tag": "auto",
            "outbounds": tags,
            "url": "https://google.com/generate_204",
            "interval": "3m",
            "tolerance": 50,
            "idle_timeout": "30m",
            "interrupt_exist_connections": False,
        },
    )
    selector_members = ["auto", *tags]
    selector_default = "auto"
else:
    selector_members = tags
    selector_default = tags[0]

outbounds.insert(
    3 if len(tags) > 1 else 2,
    {
        "type": "selector",
        "tag": "select",
        "outbounds": selector_members,
        "default": selector_default,
        "interrupt_exist_connections": False,
    },
)

route_rules = [
    {"ip_version": 6, "outbound": "block"},
    {"ip_is_private": True, "outbound": "direct"},
]

if vps_ips:
    route_rules.append(
        {"ip_cidr": sorted(vps_ips), "outbound": "direct"}
    )

config = {
    "log": {"level": "info", "timestamp": True},
    "dns": {
        "servers": [
            {"type": "udp", "tag": "cloudflare", "server": "1.1.1.1"},
            {"type": "udp", "tag": "google", "server": "8.8.8.8"},
        ],
        "final": "cloudflare",
    },
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tun_iface,
            "address": ["172.19.0.1/30"],
            "auto_route": False,
            "strict_route": False,
            "stack": "system",
        },
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": mixed_port,
        },
        {
            "type": "mixed",
            "tag": "lan-proxy-in",
            "listen": vm_ip,
            "listen_port": lan_proxy_port,
        },
    ],
    "outbounds": outbounds,
    "route": {
        "default_domain_resolver": "cloudflare",
        "auto_detect_interface": True,
        "rules": route_rules,
        "final": "select",
    },
    "experimental": {
        "cache_file": {"enabled": True},
        "clash_api": {
            "external_controller": f"0.0.0.0:{clash_port}",
            "external_ui": ui_dir,
            "external_ui_download_detour": "direct",
            "access_control_allow_private_network": True,
            "secret": "",
        },
    },
}

os.makedirs(os.path.dirname(out_file), exist_ok=True)
with open(out_file, "w", encoding="utf-8") as file:
    json.dump(config, file, indent=2, ensure_ascii=False)

print("Добавлены outbound:")
for tag in tags:
    print("  -", tag)

if skipped:
    print("Пропущены ссылки:")
    for item in skipped:
        print("  -", item)
PY

  sing-box check -c "$candidate"

  if [ -f "$SINGBOX_CONFIG" ]; then
    cp -a "$SINGBOX_CONFIG" \
      "$SINGBOX_BACKUP_DIR/config.json.$(date +%Y%m%d-%H%M%S).bak"
  fi

  install -m 0644 "$candidate" "$SINGBOX_CONFIG"
  rm -f "$candidate"

  ok "Конфигурация sing-box создана и проверена."
}

clear_policy_rules() {
  local start end priority
  start="${RULE_PRIORITY:-$DEFAULT_RULE_PRIORITY}"
  end=$((start + 255))

  for ((priority=start; priority<=end; priority++)); do
    while ip rule del priority "$priority" 2>/dev/null; do :; done
  done

  if [ -n "${SELF_RULE_PRIORITY:-}" ]; then
    while ip rule del priority "$SELF_RULE_PRIORITY" 2>/dev/null; do :; done
  fi
}

reset_runtime_state() {
  load_settings || return 0

  systemctl disable --now ruter-route.service \
    >/dev/null 2>&1 || true

  clear_policy_rules
  ip route flush table "$TABLE_ID" 2>/dev/null || true
  nft delete table ip ruter_nat 2>/dev/null || true

  rm -f "$ROUTE_SERVICE" "$ROUTE_SCRIPT"
  systemctl daemon-reload
}

write_route_script() {
  load_settings

  cat >"$ROUTE_SCRIPT" <<'ROUTE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SETTINGS_FILE="/etc/ruter/settings.env"
SINGBOX_CONFIG="/etc/sing-box/config.json"

error_handler() {
  local exit_code=$?
  echo "Ruter route error: line ${BASH_LINENO[0]}, command: ${BASH_COMMAND}, exit: ${exit_code}" >&2
  exit "$exit_code"
}
trap error_handler ERR

# shellcheck disable=SC1090
source "$SETTINGS_FILE"

TABLE_ID="${TABLE_ID:-200}"
RULE_PRIORITY="${RULE_PRIORITY:-100}"
SELF_RULE_PRIORITY="${SELF_RULE_PRIORITY:-90}"
ROUTE_MODE="${ROUTE_MODE:-sources}"
ROUTE_SOURCES="${ROUTE_SOURCES:-${ROUTE_SOURCE:-}}"

require_value() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    echo "Missing required setting: $name" >&2
    exit 2
  fi
}

validate_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

validate_network() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
PY
}

cleanup_rules() {
  local priority
  for ((priority=RULE_PRIORITY; priority<=RULE_PRIORITY+255; priority++)); do
    while ip -4 rule del priority "$priority" 2>/dev/null; do :; done
  done
  while ip -4 rule del priority "$SELF_RULE_PRIORITY" 2>/dev/null; do :; done
}

wait_interface() {
  local iface="$1"
  local tries="${2:-60}"
  local i

  for ((i=1; i<=tries; i++)); do
    if ip link show dev "$iface" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Interface not found after ${tries}s: $iface" >&2
  return 1
}

require_value LAN_IFACE
require_value LAN_GATEWAY
require_value VM_IP
require_value LAN_CIDR
require_value TUN_IFACE

VM_IP="${VM_IP%%/*}"

validate_ipv4 "$VM_IP" || {
  echo "Invalid VM_IP: $VM_IP" >&2
  exit 2
}
validate_ipv4 "$LAN_GATEWAY" || {
  echo "Invalid LAN_GATEWAY: $LAN_GATEWAY" >&2
  exit 2
}
validate_network "$LAN_CIDR" || {
  echo "Invalid LAN_CIDR: $LAN_CIDR" >&2
  exit 2
}

case "$ROUTE_MODE" in
  sources|lan|disabled) ;;
  *)
    echo "Invalid ROUTE_MODE: $ROUTE_MODE" >&2
    exit 2
    ;;
esac

if [ "$ROUTE_MODE" != "disabled" ] && [ -z "$ROUTE_SOURCES" ]; then
  echo "ROUTE_SOURCES is empty for enabled routing" >&2
  exit 2
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null

wait_interface "$LAN_IFACE"

cleanup_rules
ip -4 route flush table "$TABLE_ID" 2>/dev/null || true
nft delete table ip ruter_nat 2>/dev/null || true

# Gateway VM always bypasses the VPN routing table.
ip -4 rule add \
  priority "$SELF_RULE_PRIORITY" \
  from "$VM_IP/32" \
  lookup main

if [ "$ROUTE_MODE" = "disabled" ]; then
  echo "Ruter routing is disabled"
  exit 0
fi

wait_interface "$TUN_IFACE"

# Keep the local LAN reachable from the policy-routing table.
ip -4 route replace \
  "$LAN_CIDR" \
  dev "$LAN_IFACE" \
  scope link \
  table "$TABLE_ID"

# VPN server addresses must bypass TUN to prevent a routing loop.
if [ -f "$SINGBOX_CONFIG" ]; then
  while IFS= read -r server_ip; do
    [ -n "$server_ip" ] || continue
    ip -4 route replace \
      "$server_ip/32" \
      via "$LAN_GATEWAY" \
      dev "$LAN_IFACE" \
      table "$TABLE_ID"
  done < <(
    python3 - "$SINGBOX_CONFIG" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    config = json.load(fh)

addresses = set()

for outbound in config.get("outbounds", []):
    server = outbound.get("server")
    if not server:
        continue
    try:
        addresses.add(str(ipaddress.ip_address(server)))
    except ValueError:
        pass

for rule in config.get("route", {}).get("rules", []):
    for item in rule.get("ip_cidr", []) or []:
        try:
            network = ipaddress.ip_network(item, strict=False)
        except ValueError:
            continue
        if network.version == 4 and network.prefixlen == 32:
            addresses.add(str(network.network_address))

for address in sorted(addresses):
    print(address)
PY
  )
fi

ip -4 route replace \
  default \
  dev "$TUN_IFACE" \
  table "$TABLE_ID"

priority="$RULE_PRIORITY"
for source in $ROUTE_SOURCES; do
  validate_network "$source" || {
    echo "Invalid route source: $source" >&2
    exit 2
  }

  ip -4 rule add \
    priority "$priority" \
    from "$source" \
    lookup "$TABLE_ID"

  priority=$((priority + 1))
done

nft add table ip ruter_nat
nft 'add chain ip ruter_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip ruter_nat postrouting \
  oifname "$LAN_IFACE" \
  ip saddr "$LAN_CIDR" \
  masquerade

echo "Ruter policy routing applied"
ROUTE_EOF

  chmod 0755 "$ROUTE_SCRIPT"
  bash -n "$ROUTE_SCRIPT"

  cat >"$ROUTE_SERVICE" <<EOF
[Unit]
Description=Ruter policy routing
After=network-online.target nftables.service sing-box.service
Wants=network-online.target nftables.service
Requires=sing-box.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=$ROUTE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ruter-route.service >/dev/null
  ok "Сервис маршрутизации записан."
}

check_singbox_config() {
  [ -f "$SINGBOX_CONFIG" ] || {
    fail "Не найден $SINGBOX_CONFIG"
    return 1
  }
  sing-box check -c "$SINGBOX_CONFIG"
}

restart_singbox() {
  check_singbox_config
  systemctl restart sing-box
  systemctl is-active --quiet sing-box
  ok "sing-box перезапущен."
}

restart_routing() {
  load_settings
  write_route_script

  if ! systemctl restart ruter-route.service; then
    fail "Маршрутизация не запустилась."
    journalctl -u ruter-route.service -n 40 --no-pager >&2 || true
    return 1
  fi

  systemctl is-active --quiet ruter-route.service
  ok "Маршрутизация перезапущена."
}

restart_all() {
  restart_singbox
  sleep 2
  restart_routing
  ok "Все сервисы перезапущены."
}

update_subscription() {
  load_settings
  read_subscription_input
  generate_singbox_config
  restart_all
}

regenerate_from_saved_subscription() {
  load_settings
  generate_singbox_config
  restart_all
}

change_routing() {
  load_settings
  ask_route_mode
  save_settings
  write_route_script

  if systemctl is-active --quiet sing-box; then
    systemctl restart ruter-route.service
  else
    warn "sing-box не активен; настройки сохранены, но маршрут не запущен."
  fi

  show_route_summary
}

show_route_summary() {
  load_settings

  echo
  echo "Маршрутизация:"
  echo "  Режим:      $ROUTE_MODE"
  echo "  Источники:  ${ROUTE_SOURCES:-нет}"
  echo "  Таблица:    $TABLE_ID"
  echo "  Приоритет:  $RULE_PRIORITY"
  echo "  VM bypass:  $VM_IP/32 priority $SELF_RULE_PRIORITY"
}

service_state() {
  local service="$1"
  if systemctl is-active --quiet "$service"; then
    printf '%sactive%s' "$C_GREEN" "$C_RESET"
  else
    printf '%sinactive%s' "$C_RED" "$C_RESET"
  fi
}

show_status() {
  echo
  printf '%sRuter %s%s\n' "$C_BOLD" "$RUTER_VERSION" "$C_RESET"
  echo

  printf 'sing-box:      %s\n' "$(service_state sing-box)"
  printf 'routing:       %s\n' "$(service_state ruter-route.service)"

  if command -v sing-box >/dev/null 2>&1; then
    echo "Версия:        $(sing-box version | head -n1)"
  else
    echo "Версия:        sing-box не установлен"
  fi

  if have_settings; then
    load_settings
    echo "VM:            $VM_IP"
    echo "LAN:           $LAN_CIDR"
    echo "Маршруты:      ${ROUTE_SOURCES:-отключены}"
    echo "Local proxy:   127.0.0.1:$MIXED_PORT (mixed HTTP/SOCKS)"
    echo "LAN proxy:     $VM_IP:$LAN_PROXY_PORT (mixed HTTP/SOCKS)"
    echo "Clash UI:      http://$VM_IP:$CLASH_PORT/ui"
  fi

  echo
  echo "ip rule:"
  ip rule show || true
}

doctor_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
    return 0
  else
    fail "$label"
    return 1
  fi
}

doctor() {
  echo
  printf '%sДиагностика Ruter%s\n\n' "$C_BOLD" "$C_RESET"

  local errors=0
  local reality_errors=""

  doctor_check "Настройки найдены" test -f "$SETTINGS_FILE" || errors=$((errors+1))
  doctor_check "sing-box установлен" command -v sing-box || errors=$((errors+1))
  doctor_check "sing-box активен" systemctl is-active --quiet sing-box || errors=$((errors+1))
  doctor_check "route service активен" systemctl is-active --quiet ruter-route.service || errors=$((errors+1))
  doctor_check "Конфигурация sing-box валидна" check_singbox_config || errors=$((errors+1))

  if have_settings; then
    load_settings

    doctor_check "LAN-интерфейс существует" ip link show "$LAN_IFACE" || errors=$((errors+1))
    doctor_check "TUN-интерфейс существует" ip link show "$TUN_IFACE" || errors=$((errors+1))
    doctor_check "Default route существует" bash -c 'ip -4 route show default | grep -q . ' || errors=$((errors+1))
    doctor_check "DNS работает" getent ahostsv4 google.com || errors=$((errors+1))
    doctor_check "Время синхронизировано" bash -c \
      'timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes' ||
      errors=$((errors+1))

    if ip rule show | grep -q "from $VM_IP lookup main"; then
      ok "Есть bypass-правило для самой VM"
    else
      fail "Нет bypass-правила для самой VM"
      errors=$((errors+1))
    fi

    if ip route show table "$TABLE_ID" | grep -q '^default '; then
      ok "Default route в таблице $TABLE_ID существует"
    else
      fail "Нет default route в таблице $TABLE_ID"
      errors=$((errors+1))
    fi

    if curl -4fsS --max-time 15 \
      -x "socks5h://127.0.0.1:$MIXED_PORT" \
      https://ifconfig.me >/tmp/ruter-ip.$$ 2>/dev/null; then
      ok "Local mixed/SOCKS-прокси работает: $(cat /tmp/ruter-ip.$$)"
    else
      fail "Local mixed/SOCKS-прокси не отвечает"
      errors=$((errors+1))
    fi
    rm -f /tmp/ruter-ip.$$

    if ss -lnt | grep -Eq "[[:space:]]${VM_IP}:${LAN_PROXY_PORT}[[:space:]]"; then
      ok "LAN proxy слушает $VM_IP:$LAN_PROXY_PORT"
    else
      fail "LAN proxy не слушает $VM_IP:$LAN_PROXY_PORT"
      errors=$((errors+1))
    fi

    if curl -4fsS --max-time 15 \
      -x "http://$VM_IP:$LAN_PROXY_PORT" \
      https://ifconfig.me >/tmp/ruter-lan-ip.$$ 2>/dev/null; then
      ok "LAN HTTP-прокси работает: $(cat /tmp/ruter-lan-ip.$$)"
    else
      fail "LAN HTTP-прокси не отвечает"
      errors=$((errors+1))
    fi
    rm -f /tmp/ruter-lan-ip.$$
  fi

  reality_errors="$(journalctl -u sing-box --since '-30 min' --no-pager 2>/dev/null |
    grep -E 'reality verification failed|REALITY authentication failed' |
    tail -n3 || true)"

  if [ -n "$reality_errors" ]; then
    echo
    warn "Обнаружены ошибки REALITY:"
    echo "$reality_errors"
    echo
    warn "Для Xray-core 26.7.11+ проверь Min Client Ver = 1.0.0."
  fi

  echo
  echo "Последние сообщения sing-box:"
  journalctl -u sing-box -n 20 --no-pager 2>/dev/null || true

  echo
  if [ "$errors" -eq 0 ]; then
    ok "Базовые проверки пройдены."
  else
    fail "Не пройдено проверок: $errors"
    return 1
  fi
}

update_singbox() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://sing-box.app/install.sh -o "$tmp"
  sh "$tmp"
  rm -f "$tmp"
  restart_all
}

update_ui() {
  install_ui
  ok "UI готов: $UI_DIR"
}

update_manager() {
  local tmp backup
  tmp="$(mktemp)"
  backup="$MANAGER_PATH.backup-$(date +%Y%m%d-%H%M%S)"

  info "Скачиваю новую версию Ruter с GitHub..."
  curl -fsSL "$REPO_RAW_URL" -o "$tmp"
  chmod 0755 "$tmp"

  bash -n "$tmp" || {
    rm -f "$tmp"
    fail "Новая версия не прошла bash -n. Текущий ruter не изменён."
    return 1
  }

  mkdir -p "$MANAGER_DIR"
  if [ -f "$MANAGER_PATH" ]; then
    cp -a "$MANAGER_PATH" "$backup"
  fi

  install -m 0755 "$tmp" "$MANAGER_PATH"
  ln -sfn "$MANAGER_PATH" "$COMMAND_PATH"
  rm -f "$tmp"

  ok "Ruter обновлён с GitHub."
  [ -f "$backup" ] && echo "Резервная копия: $backup"
  echo "Чтобы применить изменения служб: sudo ruter restart-route"
}

install_flow() {
  confirm_network
  TABLE_ID="$DEFAULT_TABLE_ID"
  RULE_PRIORITY="$DEFAULT_RULE_PRIORITY"
  SELF_RULE_PRIORITY="$DEFAULT_SELF_RULE_PRIORITY"
  TUN_IFACE="$DEFAULT_TUN_IFACE"
  MIXED_PORT="$DEFAULT_MIXED_PORT"
  LAN_PROXY_PORT="$DEFAULT_LAN_PROXY_PORT"
  CLASH_PORT="$DEFAULT_CLASH_PORT"

  ask_route_mode
  save_settings

  install_deps
  install_singbox
  install_ui
  install_manager

  if [ ! -s "$SUB_FILE" ]; then
    read_subscription_input
  else
    local answer
    read -r -p "Использовать сохранённую подписку? [Y/n]: " answer
    answer="${answer:-Y}"
    [[ "$answer" =~ ^[YyДд]$ ]] || read_subscription_input
  fi

  generate_singbox_config
  reset_runtime_state
  restart_all

  show_status
  echo
  ok "Установка завершена. Дальше используй: sudo ruter"
}

repair_flow() {
  install_deps
  install_manager
  migrate_settings
  install_singbox
  install_ui
  generate_singbox_config
  restart_all
  ok "Установка восстановлена."
}

uninstall_flow() {
  load_settings || true

  echo
  warn "Будут удалены правила маршрутизации и управляющая команда ruter."
  local answer
  read -r -p "Продолжить? [y/N]: " answer
  answer="${answer:-N}"
  [[ "$answer" =~ ^[YyДд]$ ]] || return 0

  systemctl disable --now ruter-route.service \
    >/dev/null 2>&1 || true

  if have_settings; then
    clear_policy_rules
    ip route flush table "${TABLE_ID:-200}" 2>/dev/null || true
  fi

  nft delete table ip ruter_nat 2>/dev/null || true
  rm -f "$ROUTE_SERVICE" "$ROUTE_SCRIPT"
  systemctl daemon-reload

  read -r -p "Удалить также sing-box и все настройки? [y/N]: " answer
  answer="${answer:-N}"

  if [[ "$answer" =~ ^[YyДд]$ ]]; then
    systemctl stop sing-box 2>/dev/null || true
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL https://sing-box.app/install.sh -o "$tmp"; then
      sh "$tmp" --remove || true
    fi
    rm -f "$tmp"
    rm -rf "$SINGBOX_DIR" "$APP_DIR"
  fi

  rm -f "$COMMAND_PATH"

  # Do not delete the running file before the function finishes.
  if [ "$(readlink -f "$0" 2>/dev/null || true)" != "$MANAGER_PATH" ]; then
    rm -rf "$MANAGER_DIR"
  else
    warn "Каталог $MANAGER_DIR можно удалить после выхода:"
    echo "  rm -rf $MANAGER_DIR"
  fi

  ok "Удаление завершено."
}

services_menu() {
  while true; do
    echo
    echo "Сервисы"
    echo "  1) Перезапустить всё"
    echo "  2) Перезапустить sing-box"
    echo "  3) Перезапустить маршрутизацию"
    echo "  4) Показать журнал sing-box"
    echo "  0) Назад"
    echo

    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) restart_all; pause ;;
      2) restart_singbox; pause ;;
      3) restart_routing; pause ;;
      4) journalctl -u sing-box -n 100 --no-pager; pause ;;
      0) return ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

updates_menu() {
  while true; do
    echo
    echo "Обновления"
    echo "  1) Обновить Ruter с GitHub"
    echo "  2) Обновить sing-box"
    echo "  3) Обновить MetaCubeXD"
    echo "  4) Обновить конфигурацию из сохранённой подписки"
    echo "  0) Назад"
    echo

    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) update_manager; pause ;;
      2) update_singbox; pause ;;
      3) update_ui; pause ;;
      4) regenerate_from_saved_subscription; pause ;;
      0) return ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

main_menu() {
  while true; do
    echo
    printf '%s============================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s        Ruter %s%s\n' "$C_BOLD" "$RUTER_VERSION" "$C_RESET"
    printf '%s============================%s\n' "$C_BOLD" "$C_RESET"
    echo
    echo "  1) Статус"
    echo "  2) Обновить подписку"
    echo "  3) Изменить маршрутизацию"
    echo "  4) Сервисы"
    echo "  5) Диагностика"
    echo "  6) Обновления"
    echo "  7) Установить / восстановить"
    echo "  8) Удалить"
    echo "  0) Выход"
    echo

    local choice
    read -r -p "Выбор: " choice

    case "$choice" in
      1) show_status; pause ;;
      2) update_subscription; pause ;;
      3) change_routing; pause ;;
      4) services_menu ;;
      5) doctor || true; pause ;;
      6) updates_menu ;;
      7)
        if have_settings; then
          repair_flow
        else
          install_flow
        fi
        pause
        ;;
      8) uninstall_flow; pause ;;
      0) return ;;
      *) warn "Неверный выбор." ;;
    esac
  done
}

usage() {
  cat <<EOF
Ruter $RUTER_VERSION

Установка автоматически ставит зависимости:
  curl, wget, ca-certificates, iproute2, nftables, python3, git, unzip, jq

После установки доступны:
  local mixed proxy: 127.0.0.1:$DEFAULT_MIXED_PORT
  LAN mixed proxy:   <IP Ruter>:$DEFAULT_LAN_PROXY_PORT
  LAN proxy использует тот же selector/auto, что и MetaCubeXD.

Использование:
  ruter                       интерактивное меню
  ruter install               установка или восстановление
  ruter status                состояние сервисов и маршрутов
  ruter doctor | diag         диагностика
  ruter restart               перезапуск всех сервисов
  ruter restart-singbox       перезапуск sing-box
  ruter restart-route         перезапуск маршрутизации
  ruter route                 изменить тип маршрутизации
  ruter sub                   заменить подписку и применить
  ruter rebuild               пересоздать config из сохранённой подписки
  ruter update                обновить Ruter с GitHub
  ruter update-singbox        обновить sing-box
  ruter update-ui             обновить MetaCubeXD
  ruter uninstall             удалить
  ruter version               показать версию
EOF
}

dispatch() {
  case "${1:-menu}" in
    menu) main_menu ;;
    install|repair)
      if have_settings; then repair_flow; else install_flow; fi
      ;;
    status) show_status ;;
    doctor|diag) doctor ;;
    restart) restart_all ;;
    restart-singbox|singbox) restart_singbox ;;
    restart-route) restart_routing ;;
    route|routing) change_routing ;;
    sub|subscription) update_subscription ;;
    rebuild) regenerate_from_saved_subscription ;;
    update) update_manager ;;
    update-singbox) update_singbox ;;
    update-ui) update_ui ;;
    uninstall|remove) uninstall_flow ;;
    version|-v|--version) echo "Ruter $RUTER_VERSION" ;;
    help|-h|--help) usage ;;
    *)
      fail "Неизвестная команда: $1"
      usage
      return 2
      ;;
  esac
}

trap 'fail "Ошибка в строке $LINENO. Команда: $BASH_COMMAND"' ERR

need_root
dispatch "${1:-menu}"
