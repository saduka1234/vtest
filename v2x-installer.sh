#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2155
#
# V2X Installer and Manager
# Beginner-friendly one-click installer for Xray-core / V2Ray-core
# Supports:
#   - VMess over TCP / WebSocket
#   - VLESS over TCP / WebSocket
#   - TLS and non-TLS
#   - User management, config regeneration, firewall rules, systemd
#
# Notes:
#   - Xray is preferred by default, with optional fallback to V2Ray
#   - TLS uses a self-signed certificate for simplicity and automation
#   - Clients may need "allow insecure" for self-signed TLS
#
# Run as root:
#   sudo bash v2x-installer.sh

set -uo pipefail
shopt -s lastpipe

APP_NAME="V2X Installer"
MANAGER_DIR="/etc/v2x-manager"
SETTINGS_FILE="$MANAGER_DIR/settings.json"
USERS_FILE="$MANAGER_DIR/users.json"
CONFIG_DIR="/usr/local/etc/v2x"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/v2x.service"
BIN_DIR="/usr/local/bin"
XRAY_BIN="$BIN_DIR/xray"
V2RAY_BIN="$BIN_DIR/v2ray"
CERT_DIR="$MANAGER_DIR/certs"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
SYSTEMD_NAME="v2x"
TMP_DIR="/tmp/v2x-installer.$$"

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

title()   { echo -e "${MAGENTA}========== $* ==========${NC}"; }
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()     { error "$*"; return 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { error "Please run this script as root."; exit 1; }
}

check_command() {
  command -v "$1" >/dev/null 2>&1
}

pause() {
  read -r -p "$(echo -e "${YELLOW}Press Enter to continue...${NC}")"
}

input_nonempty() {
  local prompt="$1"
  local value=""
  while true; do
    read -r -p "$(echo -e "${CYAN}${prompt}${NC}")" value
    [[ -n "${value// }" ]] && { echo "$value"; return 0; }
    warn "Input cannot be empty."
  done
}

input_default() {
  local prompt="$1"
  local def="$2"
  local value=""
  read -r -p "$(echo -e "${CYAN}${prompt} [default: ${def}]: ${NC}")" value
  echo "${value:-$def}"
}

input_choice() {
  local prompt="$1"; shift
  local opts=("$@")
  local value=""
  while true; do
    read -r -p "$(echo -e "${CYAN}${prompt}${NC}")" value
    for o in "${opts[@]}"; do
      [[ "$value" == "$o" ]] && { echo "$value"; return 0; }
    done
    warn "Invalid choice. Valid options: ${opts[*]}"
  done
}

confirm() {
  local prompt="${1:-Are you sure? [y/N]: }"
  local ans=""
  read -r -p "$(echo -e "${YELLOW}${prompt}${NC}")" ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

detect_pkg_manager() {
  if check_command apt-get; then
    PKG_MGR="apt"
  elif check_command dnf; then
    PKG_MGR="dnf"
  elif check_command yum; then
    PKG_MGR="yum"
  else
    error "Unsupported OS: no apt, dnf, or yum found."
    return 1
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf) dnf makecache -y ;;
    yum) yum makecache -y ;;
  esac
}

pkg_install() {
  local packages=("$@")
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" ;;
    dnf) dnf install -y "${packages[@]}" ;;
    yum) yum install -y "${packages[@]}" ;;
  esac
}

ensure_dependencies() {
  detect_pkg_manager || return 1
  pkg_update || return 1

  local deps=(curl unzip tar jq openssl grep sed systemd ca-certificates)
  local extra=()

  case "$PKG_MGR" in
    apt)
      extra=(iproute2 net-tools gawk)
      ;;
    dnf|yum)
      extra=(iproute net-tools gawk)
      ;;
  esac

  pkg_install "${deps[@]}" "${extra[@]}" || return 1

  if ! check_command qrencode; then
    warn "qrencode not found. Trying to install it for QR code output..."
    pkg_install qrencode || warn "Could not install qrencode. QR codes will be skipped."
  fi

  return 0
}

ensure_dirs() {
  mkdir -p "$MANAGER_DIR" "$CERT_DIR" "$CONFIG_DIR"
  chmod 700 "$MANAGER_DIR" "$CERT_DIR"
}

init_users_file() {
  if [[ ! -f "$USERS_FILE" ]]; then
    cat > "$USERS_FILE" <<'EOF'
{
  "users": []
}
EOF
  fi
}

json_validate() {
  jq empty "$1" >/dev/null 2>&1
}

load_settings_or_fail() {
  [[ -f "$SETTINGS_FILE" ]] || { error "Installer is not initialized yet. Please choose 'Install Xray/V2Ray' first."; return 1; }
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

port_in_use() {
  local port="$1"
  if check_command ss; then
    ss -lnt "( sport = :$port )" 2>/dev/null | grep -q ":$port"
  else
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
  fi
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif check_command uuidgen; then
    uuidgen
  else
    openssl rand -hex 16 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}'
  fi
}

get_core_bin() {
  load_settings_or_fail || return 1
  local core
  core="$(jq -r '.core' "$SETTINGS_FILE")"

  if [[ "$core" == "xray" && -x "$XRAY_BIN" ]]; then
    echo "$XRAY_BIN"
  elif [[ "$core" == "v2ray" && -x "$V2RAY_BIN" ]]; then
    echo "$V2RAY_BIN"
  elif [[ -x "$XRAY_BIN" ]]; then
    echo "$XRAY_BIN"
  elif [[ -x "$V2RAY_BIN" ]]; then
    echo "$V2RAY_BIN"
  else
    error "Neither Xray nor V2Ray binary was found."
    return 1
  fi
}

open_port_firewall() {
  local port="$1"

  if check_command ufw; then
    ufw allow "$port"/tcp >/dev/null 2>&1 || true
    return 0
  fi

  if check_command firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
  fi

  if check_command iptables; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

remove_port_firewall() {
  local port="$1"

  if check_command ufw; then
    ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
    return 0
  fi

  if check_command firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
  fi

  if check_command iptables; then
    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

apply_firewall_from_settings() {
  load_settings_or_fail || return 1
  mapfile -t ports < <(jq -r '.inbounds[].port' "$SETTINGS_FILE")
  for p in "${ports[@]}"; do
    open_port_firewall "$p"
  done
  success "Firewall rules applied."
}

generate_self_signed_cert() {
  local host="$1"
  mkdir -p "$CERT_DIR"

  local san=""
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san="IP:${host}"
  else
    san="DNS:${host}"
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 825 \
    -subj "/CN=$host" \
    -addext "subjectAltName=$san" >/dev/null 2>&1 || return 1

  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
  success "Self-signed TLS certificate created: $CERT_FILE"
}

get_latest_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

download_xray() {
  title "Installing Xray-core"
  local tag url zip_file
  tag="$(get_latest_tag "XTLS/Xray-core")"
  [[ -n "$tag" && "$tag" != "null" ]] || return 1

  zip_file="$TMP_DIR/xray.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip"

  curl -fL "$url" -o "$zip_file" || return 1
  unzip -o "$zip_file" -d "$TMP_DIR/xray" >/dev/null || return 1
  install -m 755 "$TMP_DIR/xray/xray" "$XRAY_BIN" || return 1

  [[ -f "$TMP_DIR/xray/geoip.dat" ]] && install -m 644 "$TMP_DIR/xray/geoip.dat" /usr/local/share/geoip.dat || true
  [[ -f "$TMP_DIR/xray/geosite.dat" ]] && install -m 644 "$TMP_DIR/xray/geosite.dat" /usr/local/share/geosite.dat || true

  success "Xray-core installed to $XRAY_BIN"
}

download_v2ray() {
  title "Installing V2Ray-core"
  local tag url zip_file
  tag="$(get_latest_tag "v2fly/v2ray-core")"
  [[ -n "$tag" && "$tag" != "null" ]] || return 1

  zip_file="$TMP_DIR/v2ray.zip"
  url="https://github.com/v2fly/v2ray-core/releases/download/${tag}/v2ray-linux-64.zip"

  curl -fL "$url" -o "$zip_file" || return 1
  unzip -o "$zip_file" -d "$TMP_DIR/v2ray" >/dev/null || return 1
  install -m 755 "$TMP_DIR/v2ray/v2ray" "$V2RAY_BIN" || return 1

  [[ -f "$TMP_DIR/v2ray/v2ctl" ]] && install -m 755 "$TMP_DIR/v2ray/v2ctl" "$BIN_DIR/v2ctl" || true
  [[ -f "$TMP_DIR/v2ray/geoip.dat" ]] && install -m 644 "$TMP_DIR/v2ray/geoip.dat" /usr/local/share/geoip.dat || true
  [[ -f "$TMP_DIR/v2ray/geosite.dat" ]] && install -m 644 "$TMP_DIR/v2ray/geosite.dat" /usr/local/share/geosite.dat || true

  success "V2Ray-core installed to $V2RAY_BIN"
}

install_core_interactive() {
  local selected_core
  selected_core="$(input_choice "Choose core (xray/v2ray): " xray v2ray)"

  case "$selected_core" in
    xray)
      if download_xray; then
        echo "xray"
        return 0
      fi
      warn "Xray installation failed."
      if confirm "Fallback to V2Ray automatically? [y/N]: "; then
        download_v2ray || return 1
        echo "v2ray"
        return 0
      fi
      return 1
      ;;
    v2ray)
      download_v2ray || return 1
      echo "v2ray"
      ;;
  esac
}

write_systemd_service() {
  local core_bin="$1"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=V2X Service (Xray/V2Ray)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${core_bin} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || return 1
  systemctl enable "$SYSTEMD_NAME" >/dev/null 2>&1 || true
  success "Systemd service written: $SERVICE_FILE"
}

validate_generated_config() {
  local core_bin="$1"
  "$core_bin" run -test -config "$CONFIG_FILE" >/dev/null 2>&1
}

service_restart_safe() {
  local core_bin
  core_bin="$(get_core_bin)" || return 1

  if ! validate_generated_config "$core_bin"; then
    error "Core config test failed."
    "$core_bin" run -test -config "$CONFIG_FILE" || true
    return 1
  fi

  success "Config validation passed."

  systemctl restart "$SYSTEMD_NAME" || return 1
  sleep 1

  if systemctl is-active "$SYSTEMD_NAME" >/dev/null 2>&1; then
    success "Service restarted successfully."
    return 0
  fi

  error "Service failed to start. Showing recent logs:"
  journalctl -u "$SYSTEMD_NAME" -n 30 --no-pager || true
  return 1
}

build_inbound_json() {
  local protocol="$1"
  local network="$2"
  local tlsmode="$3"
  local port="$4"
  local path="$5"
  local host="$6"

  local clients_json
  if [[ "$protocol" == "vmess" ]]; then
    clients_json="$(jq -c '
      [.users[] | select(.protocol == "vmess") | {
        id: .uuid,
        alterId: 0,
        email: .name
      }]
    ' "$USERS_FILE")"
  else
    clients_json="$(jq -c '
      [.users[] | select(.protocol == "vless") | {
        id: .uuid,
        email: .name,
        flow: ""
      }]
    ' "$USERS_FILE")"
  fi

  local security_json='null'
  if [[ "$tlsmode" == "tls" ]]; then
    security_json="$(jq -nc \
      --arg cert "$CERT_FILE" \
      --arg key "$KEY_FILE" \
      '{"certificates":[{"certificateFile":$cert,"keyFile":$key}]}' \
    )"
  fi

  local stream_json
  if [[ "$network" == "ws" ]]; then
    if [[ "$tlsmode" == "tls" ]]; then
      stream_json="$(jq -nc \
        --arg path "$path" \
        --arg host "$host" \
        --argjson tlsSettings "$security_json" \
        '{
          network:"ws",
          security:"tls",
          tlsSettings:$tlsSettings,
          wsSettings:{path:$path,headers:{Host:$host}}
        }'
      )"
    else
      stream_json="$(jq -nc \
        --arg path "$path" \
        --arg host "$host" \
        '{
          network:"ws",
          security:"none",
          wsSettings:{path:$path,headers:{Host:$host}}
        }'
      )"
    fi
  else
    if [[ "$tlsmode" == "tls" ]]; then
      stream_json="$(jq -nc \
        --argjson tlsSettings "$security_json" \
        '{
          network:"tcp",
          security:"tls",
          tlsSettings:$tlsSettings
        }'
      )"
    else
      stream_json="$(jq -nc '{network:"tcp",security:"none"}')"
    fi
  fi

  if [[ "$protocol" == "vmess" ]]; then
    jq -nc \
      --arg tag "${protocol}-${network}-${tlsmode}" \
      --arg protocol "$protocol" \
      --argjson port "$port" \
      --argjson clients "$clients_json" \
      --argjson streamSettings "$stream_json" \
      '{
        tag:$tag,
        port:$port,
        listen:"0.0.0.0",
        protocol:$protocol,
        settings:{
          clients:$clients,
          disableInsecureEncryption:false
        },
        streamSettings:$streamSettings,
        sniffing:{enabled:true,destOverride:["http","tls"]}
      }'
  else
    jq -nc \
      --arg tag "${protocol}-${network}-${tlsmode}" \
      --arg protocol "$protocol" \
      --argjson port "$port" \
      --argjson clients "$clients_json" \
      --argjson streamSettings "$stream_json" \
      '{
        tag:$tag,
        port:$port,
        listen:"0.0.0.0",
        protocol:$protocol,
        settings:{
          clients:$clients,
          decryption:"none"
        },
        streamSettings:$streamSettings,
        sniffing:{enabled:true,destOverride:["http","tls"]}
      }'
  fi
}

render_config() {
  load_settings_or_fail || return 1
  init_users_file

  local inbounds_file="$TMP_DIR/inbounds.jsonl"
  : > "$inbounds_file"

  while IFS= read -r row; do
    local protocol network tlsmode port ws_path host
    protocol="$(jq -r '.protocol' <<<"$row")"
    network="$(jq -r '.network' <<<"$row")"
    tlsmode="$(jq -r '.tls' <<<"$row")"
    port="$(jq -r '.port' <<<"$row")"
    ws_path="$(jq -r '.ws_path // "/"' <<<"$row")"
    host="$(jq -r '.host // ""' <<<"$row")"

    build_inbound_json "$protocol" "$network" "$tlsmode" "$port" "$ws_path" "$host" >> "$inbounds_file" || return 1
  done < <(jq -c '.inbounds[]' "$SETTINGS_FILE")

  jq -s '{
    log: { loglevel: "warning" },
    inbounds: .,
    outbounds: [
      { protocol: "freedom", tag: "direct" },
      { protocol: "blackhole", tag: "blocked" }
    ]
  }' "$inbounds_file" > "$CONFIG_FILE" || return 1

  json_validate "$CONFIG_FILE" || return 1
}

build_install_settings() {
  ensure_dirs
  init_users_file

  local core="$1"
  local transport tls_mode server_host
  transport="$(input_choice "Choose transport (ws/tcp/both): " ws tcp both)"
  tls_mode="$(input_choice "Choose TLS mode (tls/non-tls/both): " tls non-tls both)"
  server_host="$(input_nonempty "Enter your server public domain or IP: ")"

  local use_ws=0 use_tcp=0 use_tls=0 use_non_tls=0
  [[ "$transport" == "ws" || "$transport" == "both" ]] && use_ws=1
  [[ "$transport" == "tcp" || "$transport" == "both" ]] && use_tcp=1
  [[ "$tls_mode" == "tls" || "$tls_mode" == "both" ]] && use_tls=1
  [[ "$tls_mode" == "non-tls" || "$tls_mode" == "both" ]] && use_non_tls=1

  (( use_tls == 1 )) && generate_self_signed_cert "$server_host" || true

  local inbounds='[]'
  local combos=("vmess" "vless")

  for proto in "${combos[@]}"; do
    if (( use_tcp == 1 && use_non_tls == 1 )); then
      local def_port port
      [[ "$proto" == "vmess" ]] && def_port=10000 || def_port=11000
      port="$(input_default "Port for ${proto^^} TCP non-TLS" "$def_port")"
      validate_port "$port" || return 1
      port_in_use "$port" && warn "Port $port is already in use. Make sure this is intentional."
      inbounds="$(jq -c \
        --arg protocol "$proto" \
        --arg network "tcp" \
        --arg tls "none" \
        --arg host "$server_host" \
        --argjson port "$port" \
        '. + [{protocol:$protocol,network:$network,tls:$tls,port:$port,host:$host}]' <<<"$inbounds")"
    fi

    if (( use_tcp == 1 && use_tls == 1 )); then
      local def_port port
      [[ "$proto" == "vmess" ]] && def_port=10001 || def_port=11001
      port="$(input_default "Port for ${proto^^} TCP TLS" "$def_port")"
      validate_port "$port" || return 1
      port_in_use "$port" && warn "Port $port is already in use. Make sure this is intentional."
      inbounds="$(jq -c \
        --arg protocol "$proto" \
        --arg network "tcp" \
        --arg tls "tls" \
        --arg host "$server_host" \
        --argjson port "$port" \
        '. + [{protocol:$protocol,network:$network,tls:$tls,port:$port,host:$host}]' <<<"$inbounds")"
    fi

    if (( use_ws == 1 && use_non_tls == 1 )); then
      local def_port def_path port path
      [[ "$proto" == "vmess" ]] && { def_port=20000; def_path="/vmessws"; } || { def_port=21000; def_path="/vlessws"; }
      port="$(input_default "Port for ${proto^^} WS non-TLS" "$def_port")"
      validate_port "$port" || return 1
      port_in_use "$port" && warn "Port $port is already in use. Make sure this is intentional."
      path="$(input_default "WebSocket path for ${proto^^} WS non-TLS" "$def_path")"
      inbounds="$(jq -c \
        --arg protocol "$proto" \
        --arg network "ws" \
        --arg tls "none" \
        --arg host "$server_host" \
        --arg path "$path" \
        --argjson port "$port" \
        '. + [{protocol:$protocol,network:$network,tls:$tls,port:$port,host:$host,ws_path:$path}]' <<<"$inbounds")"
    fi

    if (( use_ws == 1 && use_tls == 1 )); then
      local def_port def_path port path
      [[ "$proto" == "vmess" ]] && { def_port=20001; def_path="/vmesswss"; } || { def_port=21001; def_path="/vlesswss"; }
      port="$(input_default "Port for ${proto^^} WS TLS" "$def_port")"
      validate_port "$port" || return 1
      port_in_use "$port" && warn "Port $port is already in use. Make sure this is intentional."
      path="$(input_default "WebSocket path for ${proto^^} WS TLS" "$def_path")"
      inbounds="$(jq -c \
        --arg protocol "$proto" \
        --arg network "ws" \
        --arg tls "tls" \
        --arg host "$server_host" \
        --arg path "$path" \
        --argjson port "$port" \
        '. + [{protocol:$protocol,network:$network,tls:$tls,port:$port,host:$host,ws_path:$path}]' <<<"$inbounds")"
    fi
  done

  jq -n \
    --arg core "$core" \
    --arg host "$server_host" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    --argjson inbounds "$inbounds" \
    '{
      core:$core,
      server_host:$host,
      cert_file:$cert,
      key_file:$key,
      inbounds:$inbounds
    }' > "$SETTINGS_FILE" || return 1

  json_validate "$SETTINGS_FILE" || return 1
}

install_flow() {
  require_root
  ensure_dependencies || return 1
  ensure_dirs
  init_users_file

  local core
  core="$(install_core_interactive)" || return 1

  build_install_settings "$core" || return 1
  render_config || { error "Generated config JSON is invalid."; return 1; }

  local core_bin
  core_bin="$(get_core_bin)" || return 1
  write_systemd_service "$core_bin" || return 1

  if ! validate_generated_config "$core_bin"; then
    error "Config validation failed. Installation stopped."
    "$core_bin" run -test -config "$CONFIG_FILE" || true
    return 1
  fi

  apply_firewall_from_settings || true
  systemctl restart "$SYSTEMD_NAME" || return 1
  systemctl enable "$SYSTEMD_NAME" >/dev/null 2>&1 || true

  if systemctl is-active "$SYSTEMD_NAME" >/dev/null 2>&1; then
    success "Installation completed successfully."
  else
    journalctl -u "$SYSTEMD_NAME" -n 30 --no-pager || true
    error "Installation finished, but the service is not active."
    return 1
  fi

  show_all_users
  show_vmess_links
  show_vless_links
}

user_exists() {
  local name="$1" protocol="$2"
  jq -e --arg name "$name" --arg protocol "$protocol" \
    '.users[] | select(.name == $name and .protocol == $protocol)' \
    "$USERS_FILE" >/dev/null 2>&1
}

add_user_common() {
  local protocol="$1"
  load_settings_or_fail || return 1
  init_users_file

  local name uuid
  name="$(input_nonempty "Enter ${protocol^^} username/email label: ")"

  if user_exists "$name" "$protocol"; then
    warn "User '$name' already exists for protocol '$protocol'."
    return 0
  fi

  uuid="$(generate_uuid)"
  jq \
    --arg name "$name" \
    --arg uuid "$uuid" \
    --arg protocol "$protocol" \
    --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.users += [{
      name:$name,
      uuid:$uuid,
      protocol:$protocol,
      created_at:$created_at
    }]' \
    "$USERS_FILE" > "$TMP_DIR/users.new.json" || return 1

  json_validate "$TMP_DIR/users.new.json" || return 1
  mv "$TMP_DIR/users.new.json" "$USERS_FILE"

  render_config || return 1
  service_restart_safe || return 1

  success "${protocol^^} user added: $name"
  if [[ "$protocol" == "vmess" ]]; then
    show_vmess_links "$name"
  else
    show_vless_links "$name"
  fi
}

add_vmess_user() { add_user_common "vmess"; }
add_vless_user() { add_user_common "vless"; }

remove_user() {
  load_settings_or_fail || return 1
  init_users_file

  title "Existing users"
  if [[ "$(jq '.users | length' "$USERS_FILE")" -eq 0 ]]; then
    warn "No users found."
    return 0
  fi

  jq -r '.users[] | "\(.protocol)\t\(.name)\t\(.uuid)"' "$USERS_FILE" | nl -w2 -s'. '

  local name
  name="$(input_nonempty "Enter username/email label to remove: ")"

  if ! jq -e --arg name "$name" '.users[] | select(.name == $name)' "$USERS_FILE" >/dev/null 2>&1; then
    warn "No user named '$name' was found."
    return 0
  fi

  jq --arg name "$name" '.users |= map(select(.name != $name))' "$USERS_FILE" > "$TMP_DIR/users.new.json" || return 1
  json_validate "$TMP_DIR/users.new.json" || return 1
  mv "$TMP_DIR/users.new.json" "$USERS_FILE"

  render_config || return 1
  service_restart_safe || return 1

  success "Removed user: $name"
}

show_all_users() {
  load_settings_or_fail || return 1
  init_users_file

  title "All Users"
  if [[ "$(jq '.users | length' "$USERS_FILE")" -eq 0 ]]; then
    warn "No users found."
    return 0
  fi

  jq -r '
    .users[]
    | "Protocol: \(.protocol)\nName: \(.name)\nUUID: \(.uuid)\nCreated: \(.created_at)\n---"
  ' "$USERS_FILE"
}

vmess_json_for_user_inbound() {
  local user_json="$1"
  local inbound_json="$2"
  local host uuid name port network tlsmode ws_path
  host="$(jq -r '.host' <<<"$inbound_json")"
  port="$(jq -r '.port' <<<"$inbound_json")"
  network="$(jq -r '.network' <<<"$inbound_json")"
  tlsmode="$(jq -r '.tls' <<<"$inbound_json")"
  ws_path="$(jq -r '.ws_path // ""' <<<"$inbound_json")"
  uuid="$(jq -r '.uuid' <<<"$user_json")"
  name="$(jq -r '.name' <<<"$user_json")"

  jq -nc \
    --arg v "2" \
    --arg ps "${name}-${network}-${tlsmode}" \
    --arg add "$host" \
    --arg port "$port" \
    --arg id "$uuid" \
    --arg aid "0" \
    --arg net "$network" \
    --arg type "none" \
    --arg host "$host" \
    --arg path "$ws_path" \
    --arg tls "$([[ "$tlsmode" == "tls" ]] && echo "tls" || echo "")" \
    --arg sni "$host" \
    '{
      v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid,
      net:$net, type:$type, host:$host, path:$path, tls:$tls, sni:$sni
    }'
}

base64_encode() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

print_qr_if_available() {
  local text="$1"
  if check_command qrencode; then
    echo -e "${CYAN}QR Code:${NC}"
    qrencode -t ANSIUTF8 "$text" || true
  fi
}

show_vmess_links() {
  load_settings_or_fail || return 1
  init_users_file

  local filter_name="${1:-}"

  title "VMess Links"
  local count
  count="$(jq '[.users[] | select(.protocol == "vmess")] | length' "$USERS_FILE")"
  [[ "$count" -gt 0 ]] || { warn "No VMess users found."; return 0; }

  while IFS= read -r user; do
    local name
    name="$(jq -r '.name' <<<"$user")"
    [[ -n "$filter_name" && "$name" != "$filter_name" ]] && continue

    echo -e "${GREEN}User:${NC} $name"
    while IFS= read -r inbound; do
      local vmess_json vmess_link
      vmess_json="$(vmess_json_for_user_inbound "$user" "$inbound")"
      vmess_link="vmess://$(printf '%s' "$vmess_json" | base64_encode)"

      echo -e "${MAGENTA}VMess JSON:${NC}"
      echo "$vmess_json" | jq .
      echo -e "${MAGENTA}VMess Link:${NC}"
      echo "$vmess_link"
      print_qr_if_available "$vmess_link"
      echo
    done < <(jq -c '.inbounds[] | select(.protocol == "vmess")' "$SETTINGS_FILE")
  done < <(jq -c '.users[] | select(.protocol == "vmess")' "$USERS_FILE")
}

show_vless_links() {
  load_settings_or_fail || return 1
  init_users_file

  local filter_name="${1:-}"

  title "VLESS Links"
  local count
  count="$(jq '[.users[] | select(.protocol == "vless")] | length' "$USERS_FILE")"
  [[ "$count" -gt 0 ]] || { warn "No VLESS users found."; return 0; }

  while IFS= read -r user; do
    local name uuid
    name="$(jq -r '.name' <<<"$user")"
    uuid="$(jq -r '.uuid' <<<"$user")"
    [[ -n "$filter_name" && "$name" != "$filter_name" ]] && continue

    echo -e "${GREEN}User:${NC} $name"
    while IFS= read -r inbound; do
      local host port network tlsmode ws_path security query tag link
      host="$(jq -r '.host' <<<"$inbound")"
      port="$(jq -r '.port' <<<"$inbound")"
      network="$(jq -r '.network' <<<"$inbound")"
      tlsmode="$(jq -r '.tls' <<<"$inbound")"
      ws_path="$(jq -r '.ws_path // ""' <<<"$inbound")"
      security="$([[ "$tlsmode" == "tls" ]] && echo "tls" || echo "none")"
      tag="${name}-${network}-${tlsmode}"

      if [[ "$network" == "ws" ]]; then
        query="encryption=none&security=${security}&type=ws&host=${host}&path=$(printf '%s' "$ws_path" | sed 's#/#%2F#g')"
      else
        query="encryption=none&security=${security}&type=tcp"
      fi

      if [[ "$tlsmode" == "tls" ]]; then
        query="${query}&sni=${host}&allowInsecure=1"
      fi

      link="vless://${uuid}@${host}:${port}?${query}#${tag}"

      echo -e "${MAGENTA}VLESS Link:${NC}"
      echo "$link"
      print_qr_if_available "$link"
      echo
    done < <(jq -c '.inbounds[] | select(.protocol == "vless")' "$SETTINGS_FILE")
  done < <(jq -c '.users[] | select(.protocol == "vless")' "$USERS_FILE")
}

restart_service() {
  load_settings_or_fail || return 1
  service_restart_safe
}

uninstall_completely() {
  require_root

  if ! confirm "This will completely remove Xray/V2Ray, config, users, certs, and service. Continue? [y/N]: "; then
    warn "Uninstall cancelled."
    return 0
  fi

  local ports=()
  if [[ -f "$SETTINGS_FILE" ]]; then
    mapfile -t ports < <(jq -r '.inbounds[].port' "$SETTINGS_FILE" 2>/dev/null || true)
  fi

  systemctl stop "$SYSTEMD_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SYSTEMD_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true

  rm -f "$XRAY_BIN" "$V2RAY_BIN" "$BIN_DIR/v2ctl"
  rm -rf "$CONFIG_DIR" "$MANAGER_DIR"

  for p in "${ports[@]}"; do
    remove_port_firewall "$p"
  done

  success "Uninstall completed."
}

run_action() {
  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    error "Operation failed and returned to the menu."
  fi
  return 0
}

print_menu() {
  clear 2>/dev/null || true
  title "$APP_NAME"
  echo -e "${CYAN}1.${NC}  Install Xray/V2Ray"
  echo -e "${CYAN}2.${NC}  Add VMess user"
  echo -e "${CYAN}3.${NC}  Add VLESS user"
  echo -e "${CYAN}4.${NC}  Remove user"
  echo -e "${CYAN}5.${NC}  Show all users"
  echo -e "${CYAN}6.${NC}  Show VMess links"
  echo -e "${CYAN}7.${NC}  Show VLESS links"
  echo -e "${CYAN}8.${NC}  Restart service"
  echo -e "${CYAN}9.${NC}  Uninstall completely"
  echo -e "${CYAN}10.${NC} Exit"
  echo
}

main_menu() {
  while true; do
    print_menu
    local choice
    read -r -p "$(echo -e "${YELLOW}Select an option [1-10]: ${NC}")" choice

    case "$choice" in
      1) run_action install_flow; pause ;;
      2) run_action add_vmess_user; pause ;;
      3) run_action add_vless_user; pause ;;
      4) run_action remove_user; pause ;;
      5) run_action show_all_users; pause ;;
      6) run_action show_vmess_links; pause ;;
      7) run_action show_vless_links; pause ;;
      8) run_action restart_service; pause ;;
      9) run_action uninstall_completely; pause ;;
      10) success "Bye."; exit 0 ;;
      *) warn "Invalid option."; pause ;;
    esac
  done
}

require_root
main_menu
