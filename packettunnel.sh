#!/bin/bash
# WaterWall Enterprise Tunnel Manager - PacketTunnel Edition
# Anti-censorship mesh deployment for Iran GFW evasion
# Requires: bash 4+, jq, sshpass, curl, systemd

set -euo pipefail

# ===== Configuration =====
BASE_DIR="/root/waterwall"
LIBS_DIR="/root/waterwall/libs"
GITHUB_REPO="radkesvat/WaterWall"
LOG_FILE="/var/log/waterwall-manager.log"
TMP_FILES=()

# ===== Logging =====
function log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [+] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

function error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [!] ERROR: $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ===== Cleanup Trap =====
function cleanup() {
    for f in "${TMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

# ===== CRLF Self-Check =====
if [[ "${BASH_SOURCE[0]}" =~ /dev/fd/ ]]; then
    # Script is being piped - check for carriage returns
    if grep -q $'\r' <(head -20 "$0"); then
        error "Script has Windows line endings (CRLF). Please convert with: sed -i 's/\r$//' script.sh"
        exit 1
    fi
fi

# ===== Path Helpers =====
function tunnel_dir() { echo "$BASE_DIR/tunnel$1"; }
function tunnel_config() { echo "$(tunnel_dir "$1")/config.json"; }
function tunnel_core() { echo "$(tunnel_dir "$1")/core.json"; }
function tunnel_log_dir() { echo "$(tunnel_dir "$1")/log"; }
function tunnel_svc_name() { echo "waterwall$1"; }
function tunnel_svc_file() { echo "/etc/systemd/system/waterwall$1.service"; }
function tunnel_ip_iran() { echo "10.10.$(($1-1)).1"; }
function tunnel_ip_kharej() { echo "10.10.$(($1-1)).2"; }
function tunnel_dev_primary() { echo "wtun$((2*$1-1))"; }
function tunnel_dev_secondary() { echo "wtun$((2*$1))"; }
function tunnel_subnet_secondary() { echo "10.20.$(($1-1)).1/24"; }

# ===== Utilities =====
function pause_return_menu() {
    echo
    read -rp "Press Enter to return to menu..." dummy
}

function is_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi
}

function wait_for_apt() {
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )
    local waited=0
    local max_wait=120
    
    while true; do
        local locked=false
        for lf in "${lock_files[@]}"; do
            if fuser "$lf" >/dev/null 2>&1; then
                locked=true
                break
            fi
        done
        [[ "$locked" == false ]] && break
        
        if [[ "$waited" -eq 0 ]]; then
            log "Waiting for other apt/dpkg process to finish (max ${max_wait}s)..."
        fi
        
        waited=$((waited + 5))
        if [[ "$waited" -ge "$max_wait" ]]; then
            error "Timeout: Another package manager is running. Please resolve manually."
            return 1
        fi
        sleep 5
    done
    dpkg --configure -a >/dev/null 2>&1 || true
}

function install_prerequisites() {
    log "Checking prerequisites..."
    wait_for_apt || return 1
    
    local pkgs=(curl jq wget unzip sshpass systemd)
    local missing=()
    
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || {
            error "Failed to install prerequisites"
            return 1
        }
    fi
}

function get_public_ip() {
    local ip
    ip="$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" && "$ip" != 127.* ]] && echo "$ip" || echo ""
}

function choose_server_ip() {
    local -a all_ips=()
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" && "$ip" != 127.* ]] && all_ips+=("$ip")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    
    if [[ "${#all_ips[@]}" -eq 0 ]]; then
        echo ""
        return
    fi
    if [[ "${#all_ips[@]}" -eq 1 ]]; then
        echo "${all_ips[0]}"
        return
    fi
    
    echo "Multiple IPs detected on this server:" >&2
    for i in "${!all_ips[@]}"; do
        echo " $((i+1))) ${all_ips[i]}" >&2
    done
    while true; do
        read -rp "Choose IP [1-${#all_ips[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#all_ips[@]} )); then
            echo "${all_ips[$((choice-1))]}"
            return
        fi
        echo "Invalid choice." >&2
    done
}

function validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

function ask_ip() {
    local prompt="$1"
    local ip
    while true; do
        read -rp "$prompt: " ip
        [[ -z "$ip" ]] && { echo ""; return; }
        validate_ip "$ip" && { echo "$ip"; return; }
        echo "Invalid IP format." >&2
    done
}

function validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

function ask_port() {
    local prompt="$1"
    local port
    while true; do
        read -rp "$prompt: " port
        [[ -z "$port" ]] && { echo ""; return; }
        validate_port "$port" && { echo "$port"; return; }
        echo "Invalid port (1-65535)." >&2
    done
}

function ask_port_json() {
    local label="$1"
    local allow_empty="${2:-false}"
    local input
    while true; do
        read -rp "$label (comma-separated, e.g. 443 or 443,80,8443): " input || { echo ""; return; }
        [[ "$input" == "0" ]] && echo "" && return
        if [[ -z "$input" ]]; then
            [[ "$allow_empty" == "true" ]] && { echo "SKIP"; return; }
            echo "Cannot be empty." >&2
            continue
        fi
        input="${input// /}"
        IFS=',' read -ra port_arr <<< "$input"
        
        local valid=true
        for p in "${port_arr[@]}"; do
            if ! validate_port "$p"; then
                echo "Invalid port: $p" >&2
                valid=false
                break
            fi
        done
        [[ "$valid" == false ]] && continue
        
        printf '%s\n' "${port_arr[@]}" | jq -nc '[inputs | tonumber]'
        return
    done
}

function ask_role() {
    echo "Select server role:"
    echo "1) Iran Server (inside firewall)"
    echo "2) Kharej Server (outside Iran)"
    echo "0) Cancel"
    local role
    while true; do
        read -rp "Choose [0-2]: " role
        [[ "$role" =~ ^[0-2]$ ]] && { echo "$role"; return; }
        echo "Invalid choice." >&2
    done
}

function ask_tunnel_num() {
    local existing max next_num
    existing="$(get_installed_tunnels)"
    if [[ -z "$existing" ]]; then
        echo 1
        return
    fi
    max="$(echo "$existing" | tail -1)"
    next_num=$((max + 1))
    read -rp "Enter tunnel number [default: $next_num]: " num
    [[ -z "$num" ]] && num="$next_num"
    if systemctl list-unit-files "waterwall${num}.service" &>/dev/null; then
        echo "Tunnel $num already exists." >&2
        return
    fi
    echo "$num"
}

function get_installed_tunnels() {
    systemctl list-unit-files 2>/dev/null | grep -oP '^waterwall\K[0-9]+(?=\.service)' | sort -n || true
}

function get_local_version() {
    local bin="$BASE_DIR/Waterwall"
    [[ -x "$bin" ]] && "$bin" version 2>/dev/null | grep -oP 'v\K[0-9.]+' || echo ""
}

function get_latest_version() {
    curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | \
        jq -r '.tag_name // empty' | sed 's/^v//' || echo ""
}

function download_waterwall() {
    mkdir -p "$BASE_DIR"
    local existing
    existing="$(find "$BASE_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        [[ "$existing" != "$BASE_DIR/Waterwall" ]] && mv "$existing" "$BASE_DIR/Waterwall"
        chmod +x "$BASE_DIR/Waterwall"
        log "Waterwall binary exists, skipping download."
        return 0
    fi
    
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) error "Unsupported architecture: $arch"; return 1 ;;
    esac
    
    local latest_url
    latest_url="$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | \
        jq -r --arg arch "$arch" '.assets[] | select(.name | test("Waterwall.*\($arch\)")) | .browser_download_url' | head -n1)"
    
    [[ -z "$latest_url" ]] && { error "Could not find Waterwall download URL"; return 1; }
    
    log "Downloading Waterwall from $latest_url..."
    if ! curl -L -o "$BASE_DIR/Waterwall" "$latest_url"; then
        error "Download failed"
        return 1
    fi
    chmod +x "$BASE_DIR/Waterwall"
    log "Waterwall downloaded successfully."
}

function generate_core_json() {
    local mtu="$1"
    local tunnel_num="$2"
    local t_core
    t_core="$(tunnel_core "$tunnel_num")"
    
    cat > "$t_core" <<EOF
{
  "log": {
    "level": "info",
    "output": "$(tunnel_log_dir "$tunnel_num")/core.log",
    "error-output": "$(tunnel_log_dir "$tunnel_num")/core.err"
  },
  "misc": {
    "mtu": $mtu,
    "tcp-fast-open": true,
    "tcp-no-delay": true
  }
}
EOF
}

function generate_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen_json="$3"
    local port_connect_kharej="$4"
    local tunnel_num="$5"
    
    local t_ip_iran t_ip_kharej t_dev_primary t_dev_secondary t_subnet2 t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev_primary="$(tunnel_dev_primary "$tunnel_num")"
    t_dev_secondary="$(tunnel_dev_secondary "$tunnel_num")"
    t_subnet2="$(tunnel_subnet_secondary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    
    cat > "$t_cfg" <<EOF
{
  "name": "bitswap-iran-$tunnel_num",
  "listen": "0.0.0.0:$port_listen_json",
  "nodes": [
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$t_dev_primary",
        "device-ip": "$t_ip_iran/24"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "up": {
          "source-ip": {"ipv4": "$ip_kharej"},
          "dest-ip": {"ipv4": "$ip_iran"}
        },
        "down": {
          "source-ip": {"ipv4": "$t_ip_kharej"},
          "dest-ip": {"ipv4": "$t_ip_iran"}
        }
      },
      "next": "obfuscator-c"
    },
    {
      "name": "obfuscator-c",
      "type": "ObfuscatorClient",
      "settings": {
        "method": "xor",
        "xor_key": 90,
        "skip": "transport"
      },
      "next": "ip-manipulator"
    },
    {
      "name": "ip-manipulator",
      "type": "IpManipulator",
      "settings": {
        "up-tcp-bit-psh": "packet->rst",
        "up-tcp-bit-rst": "packet->psh"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "12.13.12.13"
      }
    }
  ]
}
EOF
}

function generate_bitswap_kharej_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen="$3"
    local final_port="$4"
    local tunnel_num="$5"
    local final_ip="${6:-127.0.0.1}"
    
    local t_ip_iran t_ip_kharej t_dev_primary t_dev_secondary t_subnet2 t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev_primary="$(tunnel_dev_primary "$tunnel_num")"
    t_dev_secondary="$(tunnel_dev_secondary "$tunnel_num")"
    t_subnet2="$(tunnel_subnet_secondary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    
    cat > "$t_cfg" <<EOF
{
  "name": "bitswap-kharej-$tunnel_num",
  "listen": "0.0.0.0:$port_listen",
  "nodes": [
    {
      "name": "rdin",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$ip_iran"
      }
    },
    {
      "name": "ip-manipulator-in",
      "type": "IpManipulator",
      "settings": {
        "dw-tcp-bit-psh": "packet->cwr",
        "dw-tcp-bit-cwr": "packet->psh"
      },
      "next": "rdin"
    },
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$t_dev_primary",
        "device-ip": "$t_ip_iran/24"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "up": {
          "source-ip": {"ipv4": "$ip_kharej"},
          "dest-ip": {"ipv4": "$ip_iran"}
        },
        "down": {
          "source-ip": {"ipv4": "$t_ip_kharej"},
          "dest-ip": {"ipv4": "$t_ip_iran"}
        }
      },
      "next": "obfuscator-c"
    },
    {
      "name": "obfuscator-c",
      "type": "ObfuscatorClient",
      "settings": {
        "method": "xor",
        "xor_key": 90,
        "skip": "transport"
      },
      "next": "ip-manipulator"
    },
    {
      "name": "ip-manipulator",
      "type": "IpManipulator",
      "settings": {
        "up-tcp-bit-psh": "packet->rst",
        "up-tcp-bit-rst": "packet->psh"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "12.13.12.13"
      }
    }
  ]
}
EOF
}

function generate_reverse_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local reverse_port="$3"
    local final_port="$4"
    local tunnel_num="$5"
    local min_connections="${6:-32}"
    local final_ip="${7:-127.0.0.1}"
    
    local t_ip_iran t_ip_kharej t_dev_primary t_dev_secondary t_subnet2 t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev_primary="$(tunnel_dev_primary "$tunnel_num")"
    t_dev_secondary="$(tunnel_dev_secondary "$tunnel_num")"
    t_subnet2="$(tunnel_subnet_secondary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    
    cat > "$t_cfg" <<EOF
{
  "name": "reverse-bitswap-iran-$tunnel_num",
  "listen": "0.0.0.0:$reverse_port",
  "nodes": [
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$ip_iran"
      }
    },
    {
      "name": "obfuscator-s",
      "type": "ObfuscatorServer",
      "settings": {
        "method": "xor",
        "xor_key": 90,
        "skip": "transport"
      },
      "next": "ip-manipulator"
    },
    {
      "name": "ip-manipulator",
      "type": "IpManipulator",
      "settings": {
        "dw-tcp-bit-psh": "packet->rst",
        "dw-tcp-bit-rst": "packet->psh"
      },
      "next": "rd2"
    },
    {
      "name": "rd2",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "12.12.12.12/32"
      }
    }
  ]
}
EOF
}

function generate_reverse_bitswap_kharej_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local reverse_port="$3"
    local final_port="$4"
    local tunnel_num="$5"
    local min_connections="${6:-32}"
    local final_ip="${7:-127.0.0.1}"
    
    local t_ip_iran t_ip_kharej t_dev_primary t_dev_secondary t_subnet2 t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev_primary="$(tunnel_dev_primary "$tunnel_num")"
    t_dev_secondary="$(tunnel_dev_secondary "$tunnel_num")"
    t_subnet2="$(tunnel_subnet_secondary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    
    cat > "$t_cfg" <<EOF
{
  "name": "reverse-bitswap-kharej-$tunnel_num",
  "listen": "0.0.0.0:$reverse_port",
  "nodes": [
    {
      "name": "rdin",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$ip_iran"
      }
    },
    {
      "name": "ip-manipulator-in",
      "type": "IpManipulator",
      "settings": {
        "dw-tcp-bit-psh": "packet->cwr",
        "dw-tcp-bit-cwr": "packet->psh"
      },
      "next": "rdin"
    },
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$t_dev_primary",
        "device-ip": "$t_ip_iran/24"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "up": {
          "source-ip": {"ipv4": "$ip_kharej"},
          "dest-ip": {"ipv4": "$ip_iran"}
        },
        "down": {
          "source-ip": {"ipv4": "$t_ip_kharej"},
          "dest-ip": {"ipv4": "$t_ip_iran"}
        }
      },
      "next": "obfuscator-c"
    },
    {
      "name": "obfuscator-c",
      "type": "ObfuscatorClient",
      "settings": {
        "method": "xor",
        "xor_key": 90,
        "skip": "transport"
      },
      "next": "ip-manipulator"
    },
    {
      "name": "ip-manipulator",
      "type": "IpManipulator",
      "settings": {
        "up-tcp-bit-psh": "packet->rst",
        "up-tcp-bit-rst": "packet->psh"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "12.13.12.13"
      }
    }
  ]
}
EOF
}

function install_service() {
    local tunnel_num="$1"
    local svc_file
    svc_file="$(tunnel_svc_file "$tunnel_num")"
    
    cat > "$svc_file" <<EOF
[Unit]
Description=WaterWall Tunnel $tunnel_num
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/Waterwall -c $(tunnel_config "$tunnel_num") -core $(tunnel_core "$tunnel_num")
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=unlimited

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$(tunnel_svc_name "$tunnel_num")" >/dev/null 2>&1
    systemctl restart "$(tunnel_svc_name "$tunnel_num")"
    log "Service waterwall$tunnel_num installed and started."
}

function install_bitswap() {
    local tunnel_num
    tunnel_num="$(ask_tunnel_num)"
    [[ -z "$tunnel_num" ]] && return
    
    download_waterwall || { pause_return_menu; return; }
    
    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return
    
    local server_ip
    server_ip="$(choose_server_ip)"
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi
    
    local mtu_val
    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400
    
    mkdir -p "$(tunnel_dir "$tunnel_num")"
    mkdir -p "$(tunnel_log_dir "$tunnel_num")"
    
    if [[ "$role" == "1" ]]; then
        local ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"
        local ip_kharej
        ip_kharej="$(ask_ip "Enter Kharej server public IP")"
        [[ -z "$ip_kharej" ]] && return
        
        local port_listen_json
        port_listen_json="$(ask_port_json "Enter port(s) to listen on (Iran side)" "false")"
        [[ -z "$port_listen_json" || "$port_listen_json" == "SKIP" ]] && return
        
        local port_connect_kharej
        port_connect_kharej="$(ask_port "Enter port to connect to on Kharej (Waterwall listen port)")"
        [[ -z "$port_connect_kharej" ]] && return
        
        generate_core_json "$mtu_val" "$tunnel_num"
        generate_bitswap_iran_config "$ip_iran" "$ip_kharej" "$port_listen_json" "$port_connect_kharej" "$tunnel_num"
        
    elif [[ "$role" == "2" ]]; then
        local ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"
        local ip_iran
        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return
        
        local port_listen
        port_listen="$(ask_port "Enter port to listen (Waterwall listen port, same as Iran's connect port)")"
        [[ -z "$port_listen" ]] && return
        
        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return
        
        local final_ip
        read -rp "Enter final destination IP (where the service runs) [default: 127.0.0.1]: " final_ip
        [[ -z "$final_ip" ]] && final_ip="127.0.0.1"
        
        generate_core_json "$mtu_val" "$tunnel_num"
        generate_bitswap_kharej_config "$ip_iran" "$ip_kharej" "$port_listen" "$final_port" "$tunnel_num" "$final_ip"
    fi
    
    install_service "$tunnel_num"
    log "BitSwap tunnel $tunnel_num setup complete. Service is running."
    
    if [[ "$role" == "2" ]]; then
        echo
        local test_ans
        read -rp "Do you want to test the tunnel now? (y/N): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            local t_ip
            t_ip="$(tunnel_ip_kharej "$tunnel_num")"
            log "Testing tunnel (ping $t_ip - 10 packets)..."
            echo
            if ping -c 10 -W 2 "$t_ip" >/dev/null 2>&1; then
                echo "=== Tunnel is UP and working ==="
            else
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi
    pause_return_menu
}

function install_reverse_bitswap() {
    local tunnel_num
    tunnel_num="$(ask_tunnel_num)"
    [[ -z "$tunnel_num" ]] && return
    
    download_waterwall || { pause_return_menu; return; }
    
    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return
    
    local server_ip
    server_ip="$(choose_server_ip)"
    if [[ -z "$server_ip" ]]; then
        echo "Could not detect public IP automatically."
        server_ip="$(ask_ip "Enter this server public IP")"
        [[ -z "$server_ip" ]] && return
    fi
    
    local mtu_val
    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400
    
    mkdir -p "$(tunnel_dir "$tunnel_num")"
    mkdir -p "$(tunnel_log_dir "$tunnel_num")"
    
    if [[ "$role" == "1" ]]; then
        local ip_iran="$server_ip"
        echo "Detected Iran server IP: $ip_iran"
        local ip_kharej
        ip_kharej="$(ask_ip "Enter Kharej server public IP")"
        [[ -z "$ip_kharej" ]] && return
        
        local reverse_port
        reverse_port="$(ask_port "Enter reverse tunnel listen port (Iran side)")"
        [[ -z "$reverse_port" ]] && return
        
        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return
        
        local min_conn
        read -rp "Enter minimum connections for reverse tunnel [default: 32]: " min_conn
        [[ -z "$min_conn" ]] && min_conn=32
        
        local final_ip
        read -rp "Enter final destination IP [default: 127.0.0.1]: " final_ip
        [[ -z "$final_ip" ]] && final_ip="127.0.0.1"
        
        generate_core_json "$mtu_val" "$tunnel_num"
        generate_reverse_bitswap_iran_config "$ip_iran" "$ip_kharej" "$reverse_port" "$final_port" "$tunnel_num" "$min_conn" "$final_ip"
        
    elif [[ "$role" == "2" ]]; then
        local ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"
        local ip_iran
        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return
        
        local reverse_port
        reverse_port="$(ask_port "Enter reverse tunnel connect port (Kharej side)")"
        [[ -z "$reverse_port" ]] && return
        
        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return
        
        local min_conn
        read -rp "Enter minimum connections for reverse tunnel [default: 32]: " min_conn
        [[ -z "$min_conn" ]] && min_conn=32
        
        local final_ip
        read -rp "Enter final destination IP [default: 127.0.0.1]: " final_ip
        [[ -z "$final_ip" ]] && final_ip="127.0.0.1"
        
        generate_core_json "$mtu_val" "$tunnel_num"
        generate_reverse_bitswap_kharej_config "$ip_iran" "$ip_kharej" "$reverse_port" "$final_port" "$tunnel_num" "$min_conn" "$final_ip"
    fi
    
    install_service "$tunnel_num"
    log "Reverse BitSwap tunnel $tunnel_num setup complete. Service is running."
    
    if [[ "$role" == "2" ]]; then
        echo
        local test_ans
        read -rp "Do you want to test the tunnel now? (y/N): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            local t_ip
            t_ip="$(tunnel_ip_kharej "$tunnel_num")"
            log "Testing tunnel (ping $t_ip - 10 packets)..."
            echo
            if ping -c 10 -W 2 "$t_ip" >/dev/null 2>&1; then
                echo "=== Tunnel is UP and working ==="
            else
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi
    pause_return_menu
}

function service_management_menu() {
    while true; do
        echo
        echo "Service Management"
        echo "=================="
        echo "1) List Tunnels"
        echo "2) Check Status"
        echo "3) Test Tunnel"
        echo "4) Change Ports"
        echo "5) iperf3 Test"
        echo "6) MTU Test"
        echo "7) Uninstall Tunnel"
        echo "0) Return to Main Menu"
        echo
        read -rp "Choose [0-7]: " choice || break
        
        case "$choice" in
            1)
                echo "Installed tunnels:"
                get_installed_tunnels | while read -r tn; do
                    echo "  Tunnel $tn: $(tunnel_svc_name "$tn")"
                done
                pause_return_menu
                ;;
            2)
                get_installed_tunnels | while read -r tn; do
                    echo "=== Tunnel $tn ==="
                    systemctl status "$(tunnel_svc_name "$tn")" --no-pager -l
                    echo
                done
                pause_return_menu
                ;;
            3)
                local tn
                read -rp "Enter tunnel number to test: " tn
                if [[ -n "$tn" ]]; then
                    local t_ip
                    t_ip="$(tunnel_ip_kharej "$tn" 2>/dev/null || echo "")"
                    if [[ -n "$t_ip" ]]; then
                        log "Testing tunnel $tn (ping $t_ip)..."
                        ping -c 5 -W 2 "$t_ip" && echo "Tunnel $tn: OK" || echo "Tunnel $tn: FAILED"
                    else
                        echo "Could not determine tunnel IP for tunnel $tn"
                    fi
                fi
                pause_return_menu
                ;;
            4)
                echo "Port change feature - coming soon"
                pause_return_menu
                ;;
            5)
                echo "iperf3 test - requires manual setup on both ends"
                pause_return_menu
                ;;
            6)
                echo "MTU test - use ping -M do -s <size>"
                pause_return_menu
                ;;
            7)
                local tn
                read -rp "Enter tunnel number to uninstall: " tn
                if [[ -n "$tn" ]]; then
                    systemctl stop "$(tunnel_svc_name "$tn")" 2>/dev/null || true
                    systemctl disable "$(tunnel_svc_name "$tn")" 2>/dev/null || true
                    rm -f "$(tunnel_svc_file "$tn")"
                    rm -rf "$(tunnel_dir "$tn")"
                    log "Tunnel $tn uninstalled"
                fi
                pause_return_menu
                ;;
            0) return ;;
            *) echo "Invalid option." ;;
        esac
    done
}

function update_core() {
    echo
    local local_ver latest_ver
    local_ver="$(get_local_version)"
    latest_ver="$(get_latest_version)"
    
    if [[ -z "$local_ver" ]]; then
        echo "Waterwall binary not found. Use Install first."
        pause_return_menu
        return
    fi
    if [[ -z "$latest_ver" ]]; then
        echo "Could not fetch latest version from GitHub."
        pause_return_menu
        return
    fi
    
    if [[ "$local_ver" == "$latest_ver" ]]; then
        echo "You already have the latest version (v$local_ver)."
        pause_return_menu
        return
    fi
    
    echo "Current version: v$local_ver"
    echo "Latest version: v$latest_ver"
    echo
    local ans
    read -rp "Update to v$latest_ver? (y/N): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
        echo "Update cancelled."
        pause_return_menu
        return
    fi
    
    rm -f "$BASE_DIR/Waterwall"
    download_waterwall || { pause_return_menu; return; }
    
    if is_installed; then
        local tunnels
        tunnels="$(get_installed_tunnels)"
        if [[ -n "$tunnels" ]]; then
            echo "Restarting $(echo "$tunnels" | wc -w) tunnel(s)..."
            echo "$tunnels" | while read -r tn; do
                systemctl restart "$(tunnel_svc_name "$tn")" 2>/dev/null || true
            done
        fi
    fi
    
    echo "Update complete."
    pause_return_menu
}

function is_installed() {
    command -v "$BASE_DIR/Waterwall" >/dev/null 2>&1
}

function banner() {
    echo -e "\e[36m"
    echo " ╔═╗╔═╗╔╦╗╔═╗╦  ╔═╗╔═╗╔╦╗╔═╗╦ ╦"
    echo " ╠╣ ║ ║║║║╣ ║  ║╣ ║   ║ ║╣ ╚╦╝"
    echo " ╚  ╚═╝╩ ╩╚═╝╩═╝╚═╝╚═╝ ╩ ╚═╝ ╩ "
    echo -e "\e[31m"
    echo " ╔═╗╦ ╦╔═╗╔╗╔╔╦╗╦ ╦╔═╗  ╔╦╗╔═╗╦  ╔═╗╔═╗╔╦╗"
    echo " ║  ╠═╣╠═╣║║║ ║ ║ ║╠═╝   ║ ║ ║║  ╠═╝╠═╣ ║ "
    echo " ╚═╝╩ ╩╩ ╩╝╚╝ ╩ ╚═╝╩      ╩ ╚═╝╩═╝╩  ╩ ╩ ╩ "
    echo -e "\e[0m"
    echo " WATERWALL - \e[36mBY MEYSAM\e[31m"
    local ver_status
    ver_status="$(get_local_version)"
    [[ -z "$ver_status" ]] && ver_status="Not Installed" || ver_status="v$ver_status"
    echo " SERVER IP: $(get_public_ip || echo 'N/A')"
    echo " CORE: $ver_status"
    echo -e "\e[31m==================================================\e[0m"
}

function mesh_parse_file() {
    local file="$1"
    mesh_names=()
    mesh_ips=()
    mesh_users=()
    mesh_passes=()
    mesh_roles=()
    
    [[ ! -f "$file" ]] && { error "Mesh file not found: $file"; return 1; }
    
    while IFS=',' read -r name ip user pass role; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        name="$(echo "$name" | xargs)"
        ip="$(echo "$ip" | xargs)"
        user="$(echo "$user" | xargs)"
        pass="$(echo "$pass" | xargs)"
        role="$(echo "$role" | xargs)"
        
        mesh_names+=("$name")
        mesh_ips+=("$ip")
        mesh_users+=("${user:-root}")
        mesh_passes+=("$pass")
        mesh_roles+=("${role:-2}")
    done < "$file"
}

function mesh_deploy() {
    echo
    echo "Mesh Network Deployment"
    echo "======================="
    
    local mesh_file
    read -rp "Enter path to mesh servers file [default: /root/mesh-servers.txt]: " mesh_file
    [[ -z "$mesh_file" ]] && mesh_file="/root/mesh-servers.txt"
    
    if [[ ! -f "$mesh_file" ]]; then
        echo "File not found: $mesh_file"
        echo "Example format (CSV):"
        echo "  server1,1.2.3.4,root,password123,2"
        echo "  server2,5.6.7.8,root,password456,1"
        echo "  # role: 1=Iran, 2=Kharej"
        pause_return_menu
        return
    fi
    
    mesh_parse_file "$mesh_file" || return
    
    if [[ "${#mesh_ips[@]}" -eq 0 ]]; then
        echo "No valid servers found in file."
        pause_return_menu
        return
    fi
    
    echo "Found ${#mesh_ips[@]} server(s):"
    for i in "${!mesh_ips[@]}"; do
        echo "  $((i+1))) ${mesh_names[$i]} @ ${mesh_ips[$i]} (role: ${mesh_roles[$i]})"
    done
    echo
    
    local tunnel_type
    echo "Select tunnel type:"
    echo "1) BitSwap"
    echo "2) Reverse BitSwap"
    read -rp "Choose [1-2]: " tunnel_type
    case "$tunnel_type" in
        1) tunnel_type="bitswap" ;;
        2) tunnel_type="reverse" ;;
        *) echo "Invalid choice."; pause_return_menu; return ;;
    esac
    
    local mtu_val
    read -rp "Enter MTU value [default: 1400]: " mtu_val
    [[ -z "$mtu_val" ]] && mtu_val=1400
    
    # Build tunnels JSON array using jq
    local tunnels_json="[]"
    local iran_idx=0 kharej_idx=0
    
    for i in "${!mesh_ips[@]}"; do
        local s_role="${mesh_roles[$i]}"
        local s_ip="${mesh_ips[$i]}"
        local s_name="${mesh_names[$i]}"
        
        if [[ "$tunnel_type" == "bitswap" ]]; then
            if [[ "$s_role" == "1" ]]; then
                # Iran server
                local iran_up iran_tp
                iran_up="$(ask_port "Enter user port for $s_name (Iran)")"
                [[ -z "$iran_up" ]] && continue
                iran_tp="$(ask_port "Enter tunnel port for $s_name (Iran)")"
                [[ -z "$iran_tp" ]] && continue
                
                tunnels_json="$(echo "$tunnels_json" | jq \
                    --argjson tn "$((iran_idx+1))" \
                    --arg peer "${mesh_ips[$kharej_idx]:-}" \
                    --argjson cp "$iran_tp" \
                    --argjson up "$iran_up" \
                    --arg fip "127.0.0.1" \
                    '. + [{"tunnel_num": $tn, "peer_ip": $peer, "core_port": $cp, "user_port": $up, "final_ip": $fip}]')"
                iran_idx=$((iran_idx + 1))
            elif [[ "$s_role" == "2" ]]; then
                # Kharej server
                local kharej_up kharej_tp
                kharej_up="$(ask_port "Enter user port for $s_name (Kharej)")"
                [[ -z "$kharej_up" ]] && continue
                kharej_tp="$(ask_port "Enter tunnel port for $s_name (Kharej)")"
                [[ -z "$kharej_tp" ]] && continue
                
                tunnels_json="$(echo "$tunnels_json" | jq \
                    --argjson tn "$((kharej_idx+1))" \
                    --arg peer "${mesh_ips[$iran_idx]:-}" \
                    --argjson cp "$kharej_tp" \
                    --argjson up "$kharej_up" \
                    --arg fip "127.0.0.1" \
                    '. + [{"tunnel_num": $tn, "peer_ip": $peer, "core_port": $cp, "user_port": $up, "final_ip": $fip}]')"
                kharej_idx=$((kharej_idx + 1))
            fi
        elif [[ "$tunnel_type" == "reverse" ]]; then
            # Similar logic for reverse - simplified for brevity
            local up tp
            up="$(ask_port "Enter user port for $s_name")"
            [[ -z "$up" ]] && continue
            tp="$(ask_port "Enter tunnel port for $s_name")"
            [[ -z "$tp" ]] && continue
            
            tunnels_json="$(echo "$tunnels_json" | jq \
                --argjson tn "$((i+1))" \
                --arg peer "" \
                --argjson cp "$tp" \
                --argjson up "$up" \
                --arg fip "127.0.0.1" \
                '. + [{"tunnel_num": $tn, "peer_ip": $peer, "core_port": $cp, "user_port": $up, "final_ip": $fip}]')"
        fi
    done
    
    local b64
    b64="$(echo "$tunnels_json" | base64 -w0)"
    
    echo
    echo "Deployment Summary:"
    echo "  Tunnel Type: $tunnel_type"
    echo "  MTU: $mtu_val"
    echo "  Servers: ${#mesh_ips[@]}"
    echo
    local confirm
    read -rp "Proceed with deployment? (y/N): " confirm || { pause_return_menu; return; }
    confirm="$(echo "$confirm" | tr '[:upper:]' '[:lower:]')"
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Deployment cancelled."
        pause_return_menu
        return
    fi
    
    if ! command -v sshpass >/dev/null 2>&1; then
        log "Installing sshpass..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq sshpass >/dev/null 2>&1 || {
            error "Failed to install sshpass"
            return 1
        }
    fi
    
    echo "Deploying to servers..."
    for i in "${!mesh_ips[@]}"; do
        local s_name="${mesh_names[$i]}"
        local s_ip="${mesh_ips[$i]}"
        local s_user="${mesh_users[$i]}"
        local s_pass="${mesh_passes[$i]}"
        local s_role="${mesh_roles[$i]}"
        
        echo "  -> $s_name ($s_ip)..."
        
        # Copy script
        if ! sshpass -p "$s_pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$0" "${s_user}@${s_ip}:/root/packettunnel.sh" >/dev/null 2>&1; then
            echo "    ERROR: Failed to copy script. Skipping."
            continue
        fi
        
        # Execute remote deployment
        sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${s_user}@${s_ip}" \
            "MESH_ROLE=$s_role MESH_SERVER_IP=$s_ip MESH_TUNNEL_TYPE=$tunnel_type MESH_MTU=$mtu_val MESH_TUNNELS_B64=$b64 bash /root/packettunnel.sh --mesh-deploy" \
            2>&1 | tee "mesh-${s_name}.log"
        
        echo "    Log saved: mesh-${s_name}.log"
    done
    
    echo
    echo "Mesh deployment complete. Check mesh-*.log files for details."
    pause_return_menu
}

function mesh_deploy_remote() {
    # Called on remote servers during mesh deployment
    [[ -z "${MESH_TUNNELS_B64:-}" ]] && { error "MESH_TUNNELS_B64 not set"; exit 1; }
    
    install_prerequisites || exit 1
    download_waterwall || { echo "Error: Failed to download Waterwall." >&2; exit 1; }
    
    local tunnels_json
    tunnels_json="$(echo "$MESH_TUNNELS_B64" | base64 -d)"
    
    local count
    count="$(echo "$tunnels_json" | jq -r '. | length')"
    
    for ((i = 0; i < count; i++)); do
        local tn peer_ip core_port user_port final_ip
        tn="$(echo "$tunnels_json" | jq -r ".[$i].tunnel_num")"
        peer_ip="$(echo "$tunnels_json" | jq -r ".[$i].peer_ip")"
        core_port="$(echo "$tunnels_json" | jq -r ".[$i].core_port")"
        user_port="$(echo "$tunnels_json" | jq -r ".[$i].user_port")"
        final_ip="$(echo "$tunnels_json" | jq -r ".[$i].final_ip")"
        
        mkdir -p "$(tunnel_dir "$tn")"
        mkdir -p "$(tunnel_log_dir "$tn")"
        
        if [[ "$MESH_ROLE" == "1" ]]; then
            # Iran side
            generate_core_json "$MESH_MTU" "$tn"
            if [[ "$MESH_TUNNEL_TYPE" == "bitswap" ]]; then
                generate_bitswap_iran_config "$MESH_SERVER_IP" "$peer_ip" "$(echo "[$user_port]" | jq -c .)" "$core_port" "$tn"
            else
                generate_reverse_bitswap_iran_config "$MESH_SERVER_IP" "$peer_ip" "$core_port" "$user_port" "$tn" 32 "$final_ip"
            fi
        elif [[ "$MESH_ROLE" == "2" ]]; then
            # Kharej side
            generate_core_json "$MESH_MTU" "$tn"
            if [[ "$MESH_TUNNEL_TYPE" == "bitswap" ]]; then
                generate_bitswap_kharej_config "$peer_ip" "$MESH_SERVER_IP" "$core_port" "$user_port" "$tn" "$final_ip"
            else
                generate_reverse_bitswap_kharej_config "$peer_ip" "$MESH_SERVER_IP" "$core_port" "$user_port" "$tn" 32 "$final_ip"
            fi
        fi
        
        install_service "$tn"
        log "Mesh tunnel $tn deployed on $(hostname)"
    done
}

function main_menu() {
    is_root
    install_prerequisites
    
    while true; do
        banner
        echo "Waterwall Setup"
        echo "==============="
        echo "1) Install BitSwap Tunnel"
        echo "2) Install Reverse BitSwap Tunnel"
        echo "3) Service Management"
        echo "4) Update Core"
        echo "5) Mesh Deploy"
        echo "0) Exit"
        echo
        read -rp "Choose [0-5]: " choice || exit 0
        
        case "$choice" in
            1) install_bitswap ;;
            2) install_reverse_bitswap ;;
            3) service_management_menu ;;
            4) update_core ;;
            5) mesh_deploy ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ===== Entry Point =====
if [[ "${1:-}" == "--mesh-deploy" ]]; then
    mesh_deploy_remote
    exit 0
fi

main_menu
