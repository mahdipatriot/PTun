#!/bin/bash

BASE_DIR="/root/waterwall"
LIBS_DIR="/root/waterwall/libs"
GITHUB_REPO="radkesvat/WaterWall"
OPTIMIZE_MARKER="/etc/waterwall_optimize.ver"
OPTIMIZE_VERSION="3"

# --- Per-tunnel path helpers ---
function tunnel_dir()       { echo "$BASE_DIR/tunnel$1"; }
function tunnel_config()    { echo "$(tunnel_dir "$1")/config.json"; }
function tunnel_core()      { echo "$(tunnel_dir "$1")/core.json"; }
function tunnel_log_dir()   { echo "$(tunnel_dir "$1")/log"; }
function tunnel_svc_name()  { echo "waterwall$1"; }
function tunnel_svc_file()  { echo "/etc/systemd/system/waterwall$1.service"; }
function tunnel_ip_iran()   { echo "10.10.$(($1-1)).1"; }
function tunnel_ip_kharej() { echo "10.10.$(($1-1)).2"; }
function tunnel_dev_primary()   { echo "wtun$((2*$1-1))"; }
function tunnel_dev_secondary() { echo "wtun$((2*$1))"; }
function tunnel_subnet_secondary() { echo "10.20.$(($1-1)).1/24"; }

function get_installed_tunnels() {
    systemctl list-unit-files 2>/dev/null \
        | grep -oP '^waterwall\K[0-9]+(?=\.service)' \
        | sort -n
}

function get_next_tunnel_num() {
    local existing max
    existing="$(get_installed_tunnels)"
    if [[ -z "$existing" ]]; then
        echo 1
        return
    fi
    max="$(echo "$existing" | tail -1)"
    echo $((max + 1))
}

function ask_tunnel_num() {
    local suggested
    suggested="$(get_next_tunnel_num)"
    while true; do
        read -rp "Enter tunnel number [default: $suggested]: " tn || { echo ""; return; }
        [[ -z "$tn" ]] && tn="$suggested"
        if [[ "$tn" =~ ^[0-9]+$ ]] && (( tn >= 1 )); then
            if systemctl list-unit-files 2>/dev/null | grep -q "^waterwall${tn}\.service"; then
                echo "Tunnel $tn is already installed. Choose a different number." >&2
                continue
            fi
            if [[ -d "$(tunnel_dir "$tn")" ]]; then
                echo "Directory $(tunnel_dir "$tn") already exists." >&2
                continue
            fi
            echo "$tn"
            return
        fi
        echo "Invalid tunnel number. Must be a positive integer." >&2
    done
}

function select_tunnel() {
    local tunnels
    mapfile -t tunnels < <(get_installed_tunnels)
    if [[ "${#tunnels[@]}" -eq 0 ]]; then
        echo ""
        return
    fi
    if [[ "${#tunnels[@]}" -eq 1 ]]; then
        echo "${tunnels[0]}"
        return
    fi
    echo "Installed tunnels:" >&2
    for t in "${tunnels[@]}"; do
        echo "  $t) Tunnel $t" >&2
    done
    local tunnel_list
    tunnel_list="$(IFS=', '; echo "${tunnels[*]}")"
    while true; do
        read -rp "Select tunnel [$tunnel_list]: " choice || { echo ""; return; }
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            for t in "${tunnels[@]}"; do
                if [[ "$t" == "$choice" ]]; then
                    echo "$choice"
                    return
                fi
            done
        fi
        echo "Invalid selection." >&2
    done
}

function log() { echo "[+] $1"; }

function pause_return_menu() {
    echo
    read -rp "Press Enter to return to menu..." _
}

function kill_apt_locks() {
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
        /var/cache/debconf/config.dat
    )
    for lf in "${lock_files[@]}"; do
        local pids
        pids="$(fuser "$lf" 2>/dev/null)" || true
        if [[ -n "$pids" ]]; then
            log "Killing process holding $lf (PIDs: $pids)..."
            kill -9 $pids 2>/dev/null || true
        fi
    done
    sleep 1
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
    dpkg --configure -a >/dev/null 2>&1 || true
}

function wait_for_apt() {
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
        /var/cache/debconf/config.dat
    )
    local waited=0
    local max_wait=30

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

        waited=$((waited + 2))
        if [[ "$waited" -ge "$max_wait" ]]; then
            log "Timeout reached. Force-clearing apt locks..."
            kill_apt_locks
            break
        fi
        sleep 2
    done

    # Fix any broken/interrupted installs
    if [[ "$waited" -gt 0 ]]; then
        dpkg --configure -a >/dev/null 2>&1 || true
    fi
}

function install_prerequisites() {
    local pkgs=()
    command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
    command -v jq >/dev/null 2>&1 || pkgs+=(jq)
    command -v iptables >/dev/null 2>&1 || pkgs+=(iptables)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    if [[ "${#pkgs[@]}" -gt 0 ]]; then
        log "Installing prerequisites: ${pkgs[*]}..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1
        log "Prerequisites installed."
    fi
}

function get_local_version() {
    local existing
    existing="$(find "$BASE_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        "$existing" -v 2>&1 | grep -oP 'version \K[0-9]+(\.[0-9]+)+' | head -n1
    fi
}

function get_latest_version() {
    curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v?\K[0-9]+(\.[0-9]+)+' | head -n1
}

function banner() {
    clear
    echo -e "\e[31m"
    local server_ip
    server_ip=$(get_public_ip)
    [[ -z "$server_ip" ]] && server_ip="Unknown"

    local local_ver latest_ver ver_status
    local_ver="$(get_local_version)"
    latest_ver="$(get_latest_version)"

    local BLUE="\e[34m" GREEN="\e[32m" YELLOW="\e[33m" RED="\e[31m" RST="\e[0m"

    if [[ -z "$local_ver" ]]; then
        ver_status="\e[37mNot installed${RST}"
    elif [[ -z "$latest_ver" ]]; then
        ver_status="${BLUE}v$local_ver${RST}"
    elif [[ "$local_ver" == "$latest_ver" ]]; then
        ver_status="${BLUE}v$local_ver${RST} - ${GREEN}latest${RST}"
    else
        ver_status="${BLUE}v$local_ver${RST} - ${YELLOW}new version available: v$latest_ver${RST}"
    fi

    local tunnel_count tunnel_info
    tunnel_count="$(get_installed_tunnels | wc -l)"
    if [[ "$tunnel_count" -gt 0 ]]; then
        tunnel_info="${GREEN}Tunnels: $tunnel_count${RST}"
    else
        tunnel_info="\e[37mNo tunnels${RST}"
    fi

    echo "=================================================="
    echo "██╗    ██╗ █████╗ ████████╗███████╗██████╗ ██╗    ██╗ █████╗ ██╗     ██╗"
    echo "██║    ██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗██║    ██║██╔══██╗██║     ██║"
    echo "██║ █╗ ██║███████║   ██║   █████╗  ██████╔╝██║ █╗ ██║███████║██║     ██║"
    echo "██║███╗██║██╔══██║   ██║   ██╔══╝  ██╔══██╗██║███╗██║██╔══██║██║     ██║"
    echo "╚███╔███╔╝██║  ██║   ██║   ███████╗██║  ██║╚███╔███╔╝██║  ██║███████╗███████╗"
    echo " ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝"
    echo -e "                  WATERWALL - \e[36mBY MEYSAM\e[31m"
    echo "                  SERVER IP: $server_ip"
    echo -e "                  CORE: $ver_status"
    echo -e "                  $tunnel_info"
    echo -e "\e[31m=================================================="
    echo -e "\e[0m"
}

function get_public_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" && "$ip" != 127.* ]] && echo "$ip"
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
        echo "  $((i+1))) ${all_ips[i]}" >&2
    done
    while true; do
        read -rp "Choose IP [1-${#all_ips[@]}]: " choice || { echo ""; return; }
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
    for o in "${octets[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

function validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

function ask_ip() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result || { echo ""; return; }
        [[ "$result" == "0" ]] && echo "" && return
        if validate_ip "$result"; then
            echo "$result"
            return
        fi
        echo "Invalid IP address. Please enter a valid IPv4 (e.g. 1.2.3.4)." >&2
    done
}

function ask_port() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result || { echo ""; return; }
        [[ "$result" == "0" ]] && echo "" && return
        if validate_port "$result"; then
            echo "$result"
            return
        fi
        echo "Invalid port. Must be a number between 1 and 65535." >&2
    done
}

function ask_port_json() {
    local label="$1"
    local allow_empty="${2:-false}"
    local input
    while true; do
        read -rp "$label (comma-separated for multiport, e.g. 443 or 443,80,8443): " input || { echo ""; return; }
        [[ "$input" == "0" ]] && echo "" && return
        if [[ -z "$input" ]]; then
            if [[ "$allow_empty" == "true" ]]; then
                echo "SKIP"
                return
            fi
            echo "Cannot be empty. Please enter at least one port." >&2
            continue
        fi
        input="${input// /}"
        if [[ "$input" == *","* ]]; then
            local json_arr="["
            local first=true
            local valid=true
            IFS=',' read -ra port_arr <<< "$input"
            for p in "${port_arr[@]}"; do
                if ! validate_port "$p"; then
                    echo "Invalid port: $p. Must be between 1 and 65535." >&2
                    valid=false
                    break
                fi
                if [[ "$first" == true ]]; then
                    json_arr+="$p"
                    first=false
                else
                    json_arr+=", $p"
                fi
            done
            [[ "$valid" == false ]] && continue
            json_arr+="]"
            echo "$json_arr"
            return
        else
            if validate_port "$input"; then
                echo "$input"
                return
            fi
            echo "Invalid port. Must be a number between 1 and 65535." >&2
        fi
    done
}

function ask_role() {
    while true; do
        echo >&2
        echo "Which server is this?" >&2
        echo "  1) Iran" >&2
        echo "  2) Kharej" >&2
        echo "  0) Back" >&2
        read -rp "Choose [0-2]: " role || { echo ""; return; }
        case "$role" in
            0|1|2) echo "$role"; return ;;
            *) echo "Invalid choice. Please enter 1 or 2." >&2 ;;
        esac
    done
}

function ask_string() {
    local label="$1"
    local result=""
    while true; do
        read -rp "$label: " result || { echo ""; return; }
        [[ "$result" == "0" ]] && echo "" && return
        if [[ -n "$result" ]]; then
            echo "$result"
            return
        fi
        echo "Cannot be empty." >&2
    done
}

function ask_kharej_ips_whitelist() {
    local input
    while true; do
        read -rp "Enter Kharej server IP(s) (comma-separated for multiple helpers): " input || { echo ""; return; }
        [[ "$input" == "0" ]] && echo "" && return
        if [[ -z "$input" ]]; then
            echo "Cannot be empty." >&2
            continue
        fi
        input="${input// /}"
        local valid=true
        local whitelist=""
        local first=true
        IFS=',' read -ra arr <<< "$input"
        for kip in "${arr[@]}"; do
            if ! validate_ip "$kip"; then
                echo "Invalid IP: $kip" >&2
                valid=false
                break
            fi
            if [[ "$first" == true ]]; then
                whitelist="\"${kip}/32\""
                first=false
            else
                whitelist="${whitelist},
                    \"${kip}/32\""
            fi
        done
        [[ "$valid" == false ]] && continue
        echo "$whitelist"
        return
    done
}

function is_installed() {
    [[ -n "$(get_installed_tunnels)" ]]
}

function is_tunnel_installed() {
    local tn="$1"
    systemctl list-unit-files 2>/dev/null | grep -q "^waterwall${tn}\\.service"
}

function prompt_ports() {
    ports=()
    log "Enter ports to forward (e.g. 443 8443 80), type 'done' to finish:"
    while true; do
        read -rp "Port: " p || { ports=(); return 1; }
        [[ "$p" == "0" ]] && ports=() && return 1
        [[ "$p" == "done" ]] && break
        if validate_port "$p"; then
            ports+=("$p")
        else
            echo "Invalid port. Must be between 1 and 65535."
        fi
    done
    if [[ "${#ports[@]}" -eq 0 ]]; then
        echo "No ports entered. At least one port is required." >&2
        return 1
    fi
    return 0
}

# ========================================
#   Waterwall Download
# ========================================

function download_waterwall() {
    mkdir -p "$BASE_DIR"
    local existing
    existing="$(find "$BASE_DIR" -maxdepth 1 -iname 'waterwall' -type f 2>/dev/null | head -n1)"
    if [[ -n "$existing" ]]; then
        if [[ "$existing" != "$BASE_DIR/Waterwall" ]]; then
            mv "$existing" "$BASE_DIR/Waterwall"
            chmod +x "$BASE_DIR/Waterwall"
        fi
        log "Waterwall binary already exists, skipping download."
        return
    fi

    local arch
    arch="$(uname -m)"
    log "Detecting CPU architecture: $arch"

    echo
    local oldcpu
    read -rp "Download old CPU build? (y/N): " oldcpu || oldcpu=""
    oldcpu="$(echo "$oldcpu" | tr '[:upper:]' '[:lower:]')"

    local asset_name=""
    case "$arch" in
        x86_64|amd64)
            if [[ "$oldcpu" == "y" || "$oldcpu" == "yes" ]]; then
                asset_name="Waterwall-linux-gcc-x64-old-cpu.zip"
            else
                asset_name="Waterwall-linux-gcc-x64.zip"
            fi
            ;;
        aarch64|arm64)
            if [[ "$oldcpu" == "y" || "$oldcpu" == "yes" ]]; then
                asset_name="Waterwall-linux-gcc-arm64-old-cpu.zip"
            else
                asset_name="Waterwall-linux-gcc-arm64.zip"
            fi
            ;;
    esac

    if [[ -z "$asset_name" ]]; then
        echo "Unsupported CPU architecture: $arch"
        echo "Supported: x86_64, aarch64 (arm64)"
        return 1
    fi

    log "Fetching latest release from GitHub..."
    local download_url
    download_url="$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases" \
        | grep -o "\"browser_download_url\": \"[^\"]*${asset_name}\"" \
        | head -n1 \
        | cut -d'"' -f4)"

    if [[ -z "$download_url" ]]; then
        echo "Could not find download URL for: $asset_name"
        return 1
    fi

    local version
    version="$(echo "$download_url" | grep -oP '/download/\K[^/]+')"
    log "Downloading $asset_name (version: $version)..."
    curl -fsSL "$download_url" -o "$BASE_DIR/$asset_name"

    log "Extracting..."
    unzip -o "$BASE_DIR/$asset_name" -d "$BASE_DIR"
    rm -f "$BASE_DIR/$asset_name"
    mkdir -p "$LIBS_DIR"
    chmod +x "$BASE_DIR/Waterwall"
    log "Waterwall downloaded and ready (version: $version)."
}

# ========================================
#   Systemd Service
# ========================================

function install_service() {
    local tn="$1"
    local svc_name svc_file tdir
    svc_name="$(tunnel_svc_name "$tn")"
    svc_file="$(tunnel_svc_file "$tn")"
    tdir="$(tunnel_dir "$tn")"
    log "Creating systemd service: $svc_name ..."
    cat > "$svc_file" <<EOF
[Unit]
Description=Waterwall Tunnel Service $tn
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$tdir
ExecStart=$BASE_DIR/Waterwall
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    log "Reloading systemd and enabling $svc_name ..."
    systemctl daemon-reload
    systemctl enable "${svc_name}.service"
    systemctl restart "${svc_name}.service"
}

# ========================================
#   PacketTunnel (Classic) Config Generators
# ========================================

function generate_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local tunnel_num="$3"
    local t_ip_iran t_ip_kharej t_dev t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev="$(tunnel_dev_primary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    cat > "$t_cfg" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev",
                "device-ip": "$t_ip_iran/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_iran"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 18
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "$t_ip_kharej"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "$t_ip_iran"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_kharej"
            }
        }
EOF
    for i in "${!ports[@]}"; do
        cat >> "$t_cfg" <<EOF
,
        {
            "name": "input$((i+1))",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${ports[i]},
                "nodelay": true
            },
            "next": "output$((i+1))"
        },
        {
            "name": "output$((i+1))",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$t_ip_kharej",
                "port": ${ports[i]}
            }
        }
EOF
    done
    echo "    ]" >> "$t_cfg"
    echo "}" >> "$t_cfg"
}

function generate_kharej_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local tunnel_num="$3"
    local t_ip_iran t_ip_kharej t_dev t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev="$(tunnel_dev_primary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    cat > "$t_cfg" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev",
                "device-ip": "$t_ip_iran/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "$ip_kharej"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "$ip_iran"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": 18
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "$t_ip_kharej"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "$t_ip_iran"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "$ip_iran"
            }
        }
    ]
}
EOF
}

# ========================================
#   BitSwap Config Generators
# ========================================

function generate_core_json() {
    local mtu="$1"
    local tunnel_num="$2"
    local t_core
    t_core="$(tunnel_core "$tunnel_num")"
    cat > "$t_core" <<EOF
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "DEBUG",
            "file": "internal.log",
            "console": true
        },
        "core": {
            "loglevel": "DEBUG",
            "file": "core.log",
            "console": true
        },
        "network": {
            "loglevel": "DEBUG",
            "file": "network.log",
            "console": true
        },
        "dns": {
            "loglevel": "SILENT",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 0,
        "ram-profile": "server",
        "mtu": $mtu,
        "libs-path": "$LIBS_DIR/"
    },
    "configs": [
        "config.json"
    ]
}
EOF
}

function generate_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen_json="$3"
    local port_connect_kharej="$4"
    local tunnel_num="$5"
    local t_ip_iran t_ip_kharej t_dev t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev="$(tunnel_dev_primary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    cat > "$t_cfg" <<EOF
{
    "name": "iran-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen_json,
        "port_to_connect_to_kharej": $port_connect_kharej,
        "each_worker_mux_connections_count": 8
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "mux-client"
        },
        {
            "name": "mux-client",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "tcp-out"
        },
        {
            "name": "tcp-out",
            "type": "TcpConnector",
            "settings": {
                "address": "$t_ip_kharej",
                "port": \$port_to_connect_to_kharej\$,
                "nodelay": true
            }
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev",
                "device-ip": "$t_ip_iran/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_iran\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_kharej\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                }
            },
            "next": "splitter"
        },
        {
            "name": "splitter",
            "type": "PacketSplitStream",
            "settings": {
                "up": "obfuscator-c",
                "down": "obfuscator-s"
            }
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-up"
        },
        {
            "name": "ip-manipulator-up",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->cwr",
                "up-tcp-bit-cwr": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.12.12.12/32"
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
                "capture-ip": \$ip_server_kharej\$
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
    "name": "germany-tcp-bitswap-mux",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen,
        "final_ip": "$final_ip",
        "final_port": $final_port
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "mux-s"
        },
        {
            "name": "mux-s",
            "type": "MuxServer",
            "settings": {},
            "next": "header-server"
        },
        {
            "name": "header-server",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "tcp-out"
        },
        {
            "name": "tcp-out",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": "dest_context->port",
                "nodelay": true
            }
        },
        {
            "name": "my tun2",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev_secondary",
                "device-ip": "$t_subnet2"
            },
            "next": "ipcorrect"
        },
        {
            "name": "ipcorrect",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                }
            },
            "next": "obfuscator-s"
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-in"
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
            "name": "rdin",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_iran\$
            }
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
                    "source-ip": {
                        "ipv4": \$ip_server_kharej\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_iran\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
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

# ========================================
#   Reverse BitSwap Config Generators
# ========================================

function generate_reverse_bitswap_iran_config() {
    local ip_iran="$1"
    local ip_kharej="$2"
    local port_listen_json="$3"
    local reverse_port="$4"
    local tunnel_num="$5"
    local t_ip_iran t_ip_kharej t_dev t_cfg
    t_ip_iran="$(tunnel_ip_iran "$tunnel_num")"
    t_ip_kharej="$(tunnel_ip_kharej "$tunnel_num")"
    t_dev="$(tunnel_dev_primary "$tunnel_num")"
    t_cfg="$(tunnel_config "$tunnel_num")"
    cat > "$t_cfg" <<EOF
{
    "name": "iran-tcp-bitswap-mux-reverse",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "port_to_listen": $port_listen_json,
        "reverse_port": $reverse_port,
        "each_worker_mux_connections_count": 8
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$port_to_listen\$,
                "nodelay": true
            },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "bridge_user_side"
        },
        {
            "name": "bridge_user_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_side"
            }
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_user_side"
            }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": {},
            "next": "bridge_reverse_side"
        },
        {
            "name": "kharej_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": \$reverse_port\$,
                "nodelay": true
            },
            "next": "reverse_server"
        },
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev",
                "device-ip": "$t_ip_iran/24"
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": \$ip_server_iran\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_kharej\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                }
            },
            "next": "splitter"
        },
        {
            "name": "splitter",
            "type": "PacketSplitStream",
            "settings": {
                "up": "obfuscator-c",
                "down": "obfuscator-s"
            }
        },
        {
            "name": "obfuscator-c",
            "type": "ObfuscatorClient",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-up"
        },
        {
            "name": "ip-manipulator-up",
            "type": "IpManipulator",
            "settings": {
                "up-tcp-bit-psh": "packet->cwr",
                "up-tcp-bit-cwr": "packet->psh"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "12.12.12.12/32"
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
                "capture-ip": \$ip_server_kharej\$
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
    "name": "kharej-tcp-bitswap-mux-reverse",
    "variables": {
        "ip_server_iran": "$ip_iran",
        "ip_server_kharej": "$ip_kharej",
        "reverse_port": $reverse_port,
        "final_ip": "$final_ip",
        "final_port": $final_port,
        "min_held_connections": $min_connections
    },
    "nodes": [
        {
            "name": "outbound_to_service",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": "dest_context->port",
                "nodelay": true
            }
        },
        {
            "name": "header-server",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "outbound_to_service"
        },
        {
            "name": "bridge_local_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_reverse_side"
            },
            "next": "header-server"
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": {
                "pair": "bridge_local_side"
            },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": \$min_held_connections\$
            },
            "next": "tcp_to_iran"
        },
        {
            "name": "tcp_to_iran",
            "type": "TcpConnector",
            "settings": {
                "address": "$t_ip_kharej",
                "port": \$reverse_port\$,
                "nodelay": true
            }
        },
        {
            "name": "my tun2",
            "type": "TunDevice",
            "settings": {
                "device-name": "$t_dev_secondary",
                "device-ip": "$t_subnet2"
            },
            "next": "ipcorrect"
        },
        {
            "name": "ipcorrect",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
                }
            },
            "next": "obfuscator-s"
        },
        {
            "name": "obfuscator-s",
            "type": "ObfuscatorServer",
            "settings": {
                "method": "xor",
                "xor_key": 90,
                "skip": "transport"
            },
            "next": "ip-manipulator-in"
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
            "name": "rdin",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": \$ip_server_iran\$
            }
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
                    "source-ip": {
                        "ipv4": \$ip_server_kharej\$
                    },
                    "dest-ip": {
                        "ipv4": \$ip_server_iran\$
                    }
                },
                "down": {
                    "source-ip": {
                        "ipv4": "$t_ip_kharej"
                    },
                    "dest-ip": {
                        "ipv4": "$t_ip_iran"
                    }
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

# ========================================
#   Install - BitSwap
# ========================================

function install_bitswap() {
    local tunnel_num
    tunnel_num="$(ask_tunnel_num)"
    [[ -z "$tunnel_num" ]] && return

    download_waterwall || { pause_return_menu; return; }

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    local server_ip
    server_ip=$(choose_server_ip)
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
        port_listen_json="$(ask_port_json "Enter listen port(s)")"
        [[ -z "$port_listen_json" ]] && return

        local port_connect_kharej
        port_connect_kharej="$(ask_port "Enter port to connect to Kharej (Waterwall port on Kharej)")"
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
            echo
            log "Testing tunnel (ping $t_ip - 10 packets)..."
            echo
            if ping -c 10 -W 2 "$t_ip"; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install - Reverse BitSwap
# ========================================

function install_reverse_bitswap() {
    local tunnel_num
    tunnel_num="$(ask_tunnel_num)"
    [[ -z "$tunnel_num" ]] && return

    download_waterwall || { pause_return_menu; return; }

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    local server_ip
    server_ip=$(choose_server_ip)
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
        port_listen_json="$(ask_port_json "Enter user listen port(s)")"
        [[ -z "$port_listen_json" ]] && return

        local reverse_port
        reverse_port="$(ask_port "Enter reverse port (Kharej connects to this port)")"
        [[ -z "$reverse_port" ]] && return

        generate_core_json "$mtu_val" "$tunnel_num"
        generate_reverse_bitswap_iran_config "$ip_iran" "$ip_kharej" "$port_listen_json" "$reverse_port" "$tunnel_num"

    elif [[ "$role" == "2" ]]; then
        local ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"

        local ip_iran
        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return

        local reverse_port
        reverse_port="$(ask_port "Enter reverse port (same port set on Iran)")"
        [[ -z "$reverse_port" ]] && return

        local final_port
        final_port="$(ask_port "Enter final inbound port (Xray listen port)")"
        [[ -z "$final_port" ]] && return

        local min_conn
        read -rp "Minimum held connections [default: 32]: " min_conn
        [[ -z "$min_conn" ]] && min_conn=32

        local final_ip
        read -rp "Enter final destination IP (where the service runs) [default: 127.0.0.1]: " final_ip
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
            echo
            log "Testing tunnel (ping $t_ip - 10 packets)..."
            echo
            if ping -c 10 -W 2 "$t_ip"; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install - PacketTunnel (Classic)
# ========================================

function install_packettunnel() {
    local tunnel_num
    tunnel_num="$(ask_tunnel_num)"
    [[ -z "$tunnel_num" ]] && return

    download_waterwall || { pause_return_menu; return; }

    local role
    role="$(ask_role)"
    [[ "$role" == "0" ]] && return

    local server_ip
    server_ip=$(choose_server_ip)
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

        prompt_ports || { pause_return_menu; return; }
        generate_core_json "$mtu_val" "$tunnel_num"
        generate_iran_config "$ip_iran" "$ip_kharej" "$tunnel_num"

    elif [[ "$role" == "2" ]]; then
        local ip_kharej="$server_ip"
        echo "Detected Kharej server IP: $ip_kharej"

        local ip_iran
        ip_iran="$(ask_ip "Enter Iran server public IP")"
        [[ -z "$ip_iran" ]] && return

        generate_core_json "$mtu_val" "$tunnel_num"
        generate_kharej_config "$ip_iran" "$ip_kharej" "$tunnel_num"
    fi

    install_service "$tunnel_num"
    log "PacketTunnel $tunnel_num setup complete. Service is running."

    if [[ "$role" == "2" ]]; then
        echo
        local test_ans
        read -rp "Do you want to test the tunnel now? (y/N): " test_ans
        test_ans="$(echo "$test_ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$test_ans" == "y" || "$test_ans" == "yes" ]]; then
            local t_ip
            t_ip="$(tunnel_ip_kharej "$tunnel_num")"
            echo
            log "Testing tunnel (ping $t_ip - 10 packets)..."
            echo
            if ping -c 10 -W 2 "$t_ip"; then
                echo
                echo "=== Tunnel is UP and working ==="
            else
                echo
                echo "=== Tunnel is NOT connected ==="
            fi
        fi
    fi

    pause_return_menu
}

# ========================================
#   Install Menu
# ========================================

function install_menu() {
    clear
    echo
    echo "Install Tunnel"
    echo "=================="
    echo "1) BitSwap"
    echo "2) Reverse BitSwap"
    echo "3) PacketTunnel (Classic)"
    echo "0) Back"
    echo
    local install_choice
    read -rp "Choose an option [0-3]: " install_choice
    case "$install_choice" in
        1) install_bitswap ;;
        2) install_reverse_bitswap ;;
        3) install_packettunnel ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Service Management
# ========================================

function restart_service() {
    local tn="$1"
    [[ -z "$tn" ]] && tn="$(select_tunnel)"
    if [[ -z "$tn" ]]; then
        echo "No tunnel installed."
        pause_return_menu
        return
    fi
    local svc_name
    svc_name="$(tunnel_svc_name "$tn")"
    echo
    if is_tunnel_installed "$tn"; then
        systemctl restart "${svc_name}.service"
        echo "Tunnel $tn ($svc_name) restarted successfully."
    else
        echo "$svc_name.service is not installed."
    fi
    pause_return_menu
}

function status_service() {
    local tn="$1"
    [[ -z "$tn" ]] && tn="$(select_tunnel)"
    if [[ -z "$tn" ]]; then
        echo "No tunnel installed."
        pause_return_menu
        return
    fi
    local svc_name
    svc_name="$(tunnel_svc_name "$tn")"
    echo
    if is_tunnel_installed "$tn"; then
        systemctl status "${svc_name}.service" --no-pager || true
    else
        echo "$svc_name.service is not installed."
    fi
    pause_return_menu
}

function test_tunnel() {
    local tn="$1"
    [[ -z "$tn" ]] && tn="$(select_tunnel)"
    if [[ -z "$tn" ]]; then
        echo "No tunnel installed."
        pause_return_menu
        return
    fi
    local t_ip
    t_ip="$(tunnel_ip_kharej "$tn")"
    echo
    log "Testing tunnel $tn (ping $t_ip - 10 packets)..."
    echo
    if ping -c 10 -W 2 "$t_ip"; then
        echo
        echo "=== Tunnel $tn is UP and working ==="
    else
        echo
        echo "=== Tunnel $tn is NOT connected ==="
    fi
    pause_return_menu
}

function uninstall() {
    echo
    if ! is_installed; then
        echo "Nothing to uninstall."
        pause_return_menu
        return
    fi

    local tunnels
    mapfile -t tunnels < <(get_installed_tunnels)

    if [[ "${#tunnels[@]}" -eq 1 ]]; then
        local tn="${tunnels[0]}"
        echo "Only tunnel $tn is installed."
        local ans
        read -rp "Uninstall tunnel $tn? (y/N): " ans
        ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
            echo "Uninstall cancelled."
            pause_return_menu
            return
        fi
        uninstall_tunnel "$tn"
        # If no tunnels left, offer to delete shared binary
        if ! is_installed && [[ -f "$BASE_DIR/Waterwall" ]]; then
            echo
            local del_bin
            read -rp "Delete the shared Waterwall binary too? (y/N): " del_bin
            del_bin="$(echo "$del_bin" | tr '[:upper:]' '[:lower:]')"
            if [[ "$del_bin" == "y" || "$del_bin" == "yes" ]]; then
                rm -rf "$BASE_DIR"
                log "All files removed."
            fi
        fi
    else
        echo "Installed tunnels: ${tunnels[*]}"
        echo
        echo "  a) Uninstall a specific tunnel"
        echo "  b) Uninstall all tunnels"
        echo "  0) Back"
        local uninstall_choice
        read -rp "Choose [a/b/0]: " uninstall_choice
        case "$uninstall_choice" in
            a)
                local tn
                tn="$(select_tunnel)"
                [[ -z "$tn" ]] && { pause_return_menu; return; }
                local ans
                read -rp "Uninstall tunnel $tn? (y/N): " ans
                ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
                if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
                    uninstall_tunnel "$tn"
                    # If no tunnels left, offer to delete shared binary
                    if ! is_installed && [[ -f "$BASE_DIR/Waterwall" ]]; then
                        echo
                        local del_bin
                        read -rp "Delete the shared Waterwall binary too? (y/N): " del_bin
                        del_bin="$(echo "$del_bin" | tr '[:upper:]' '[:lower:]')"
                        if [[ "$del_bin" == "y" || "$del_bin" == "yes" ]]; then
                            rm -rf "$BASE_DIR"
                            log "All files removed."
                        fi
                    fi
                else
                    echo "Cancelled."
                fi
                ;;
            b)
                local ans
                read -rp "Uninstall ALL tunnels? (y/N): " ans
                ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
                if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
                    local tn
                    for tn in "${tunnels[@]}"; do
                        uninstall_tunnel "$tn"
                    done
                    # Remove shared binary if no tunnels left
                    if [[ -f "$BASE_DIR/Waterwall" ]]; then
                        local del_bin
                        read -rp "Delete the shared Waterwall binary too? (y/N): " del_bin
                        del_bin="$(echo "$del_bin" | tr '[:upper:]' '[:lower:]')"
                        if [[ "$del_bin" == "y" || "$del_bin" == "yes" ]]; then
                            rm -rf "$BASE_DIR"
                            log "All files removed."
                        fi
                    fi
                else
                    echo "Cancelled."
                fi
                ;;
            *) return ;;
        esac
    fi

    log "Uninstall complete."
    pause_return_menu
}

function uninstall_tunnel() {
    local tn="$1"
    local svc_name svc_file tdir
    svc_name="$(tunnel_svc_name "$tn")"
    svc_file="$(tunnel_svc_file "$tn")"
    tdir="$(tunnel_dir "$tn")"

    log "Uninstalling tunnel $tn ..."
    systemctl stop "${svc_name}.service" 2>/dev/null || true
    systemctl disable "${svc_name}.service" 2>/dev/null || true
    rm -f "$svc_file"
    systemctl daemon-reload
    log "  Service $svc_name removed."

    rm -rf "$tdir"
    log "  Directory $tdir removed."
}

# ========================================
#   Change Ports
# ========================================

function port_change_restart_prompt() {
    local tn="$1"
    local svc_name
    svc_name="$(tunnel_svc_name "$tn")"
    echo
    echo "What next?"
    echo "1) Restart service (recommended)"
    echo "2) Reboot server"
    echo "0) Return to menu"
    local next
    read -rp "Choose [0-2]: " next
    case "$next" in
        1)
            if is_tunnel_installed "$tn"; then
                systemctl restart "${svc_name}.service" || true
                echo "Tunnel $tn service restarted."
            else
                echo "Tunnel $tn service not installed."
            fi
            pause_return_menu
            ;;
        2)
            echo "Rebooting..."
            reboot
            ;;
        *)
            return
            ;;
    esac
}

function detect_config_type() {
    local cfg_file="$1"
    local name
    name="$(jq -r '.name // empty' "$cfg_file" 2>/dev/null)"
    case "$name" in
        *bitswap*) echo "bitswap" ;;
        *) echo "classic" ;;
    esac
}

function change_ports_bitswap() {
    local cfg_file="$1"
    local config_name
    config_name="$(jq -r '.name // empty' "$cfg_file")"

    local backup
    backup="${cfg_file}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$cfg_file" "$backup"
    log "Backup saved: $backup"

    echo "Detected BitSwap config: $config_name"
    echo

    local -a PORT_VARS
    mapfile -t PORT_VARS < <(jq -r '.variables | to_entries[] | select(.key | test("port";"i")) | "\(.key)=\(.value)"' "$cfg_file" 2>/dev/null)

    if [[ "${#PORT_VARS[@]}" -eq 0 ]]; then
        echo "No port variables found in config."
        return
    fi

    for entry in "${PORT_VARS[@]}"; do
        local var_name="${entry%%=*}"
        local var_value="${entry#*=}"

        echo "Variable: $var_name"
        echo "Current value: $var_value"

        local new_port_json
        new_port_json="$(ask_port_json "Enter new value (or press Enter to keep current)" "true")"

        if [[ "$new_port_json" == "SKIP" || -z "$new_port_json" ]]; then
            echo "Keeping $var_value"
        else
            local tmp
            tmp="$(mktemp)"
            jq --arg key "$var_name" --argjson val "$new_port_json" '.variables[$key] = $val' "$cfg_file" > "$tmp"
            mv -f "$tmp" "$cfg_file"
            echo "Updated $var_name to: $new_port_json"
        fi
        echo "----------------------------------------"
    done
}

function change_ports_classic_both() {
    local cfg_file="$1"
    local -a INDICES
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^input[0-9]+$")))
            | .name
          ]
          | map(sub("^input";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$cfg_file"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No inputN nodes found in config.json."
        return
    fi

    local backup
    backup="${cfg_file}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$cfg_file" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        local current_in current_out
        current_in=$(jq -r --arg name "input$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$cfg_file" | head -n1)
        current_out=$(jq -r --arg name "output$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$cfg_file" | head -n1)

        if [[ -z "$current_in" || -z "$current_out" ]]; then
            echo "Skipping input$n/output$n (missing port field)."
            continue
        fi

        echo "Pair: input$n/output$n"
        echo "Current port: $current_in"
        local newp
        while true; do
            read -rp "Enter new port (or press Enter to keep $current_in): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_in"
                break
            fi
            if validate_port "$newp"; then
                local tmp
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg in "input$n" --arg out "output$n" '
                  (.. | objects
                    | select(has("name") and (.name==$in or .name==$out) and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$cfg_file" > "$tmp"
                mv -f "$tmp" "$cfg_file"
                echo "Updated input$n/output$n to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports_classic_input_only() {
    local cfg_file="$1"
    local -a INDICES
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^input[0-9]+$")))
            | .name
          ]
          | map(sub("^input";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$cfg_file"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No inputN nodes found in config.json."
        return
    fi

    local backup
    backup="${cfg_file}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$cfg_file" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        local current_in
        current_in=$(jq -r --arg name "input$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$cfg_file" | head -n1)

        if [[ -z "$current_in" ]]; then
            echo "Skipping input$n (missing port field)."
            continue
        fi

        echo "Node: input$n"
        echo "Current port: $current_in"
        local newp
        while true; do
            read -rp "Enter new port for input$n (or press Enter to keep $current_in): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_in"
                break
            fi
            if validate_port "$newp"; then
                local tmp
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg name "input$n" '
                  (.. | objects
                    | select(has("name") and .name==$name and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$cfg_file" > "$tmp"
                mv -f "$tmp" "$cfg_file"
                echo "Updated input$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports_classic_output_only() {
    local cfg_file="$1"
    local -a INDICES
    mapfile -t INDICES < <(
        jq -r '
          [ .. | objects
            | select(has("name") and (.name|test("^output[0-9]+$")))
            | .name
          ]
          | map(sub("^output";""))
          | map(tonumber)
          | unique
          | sort
          | .[]
        ' "$cfg_file"
    )

    if [[ "${#INDICES[@]}" -eq 0 ]]; then
        echo "No outputN nodes found in config.json."
        return
    fi

    local backup
    backup="${cfg_file}.bak_$(date +%Y%m%d_%H%M%S)"
    cp -f "$cfg_file" "$backup"
    log "Backup saved: $backup"

    for n in "${INDICES[@]}"; do
        local current_out
        current_out=$(jq -r --arg name "output$n" '..|objects|select(has("name") and .name==$name and has("settings") and (.settings|has("port")))|.settings.port' "$cfg_file" | head -n1)

        if [[ -z "$current_out" ]]; then
            echo "Skipping output$n (missing port field)."
            continue
        fi

        echo "Node: output$n"
        echo "Current port: $current_out"
        local newp
        while true; do
            read -rp "Enter new port for output$n (or press Enter to keep $current_out): " newp
            if [[ -z "$newp" ]]; then
                echo "Keeping port $current_out"
                break
            fi
            if validate_port "$newp"; then
                local tmp
                tmp="$(mktemp)"
                jq --argjson p "$newp" --arg name "output$n" '
                  (.. | objects
                    | select(has("name") and .name==$name and has("settings") and (.settings|has("port")))
                  ) |= (.settings.port = $p)
                ' "$cfg_file" > "$tmp"
                mv -f "$tmp" "$cfg_file"
                echo "Updated output$n port to: $newp"
                break
            else
                echo "Invalid port. Must be 1..65535."
            fi
        done
        echo "----------------------------------------"
    done
}

function change_ports() {
    local tn
    tn="$(select_tunnel)"
    if [[ -z "$tn" ]]; then
        echo "No tunnel installed."
        pause_return_menu
        return
    fi

    local cfg_file
    cfg_file="$(tunnel_config "$tn")"
    [[ -f "$cfg_file" ]] || { echo "Config file not found: $cfg_file"; pause_return_menu; return; }

    local config_type
    config_type="$(detect_config_type "$cfg_file")"

    if [[ "$config_type" == "bitswap" ]]; then
        change_ports_bitswap "$cfg_file"
    else
        echo
        echo "Change Ports (Classic) - Tunnel $tn"
        echo "======================"
        echo "1) Change both Input & Output ports"
        echo "2) Change only Input ports"
        echo "3) Change only Output ports"
        echo "0) Back"
        echo
        local port_choice
        read -rp "Choose an option [0-3]: " port_choice

        case "$port_choice" in
            1) change_ports_classic_both "$cfg_file" ;;
            2) change_ports_classic_input_only "$cfg_file" ;;
            3) change_ports_classic_output_only "$cfg_file" ;;
            0) return ;;
            *) echo "Invalid option."; pause_return_menu; return ;;
        esac
    fi

    port_change_restart_prompt "$tn"
}

# ========================================
#   Service Management Menu
# ========================================

function iperf3_test() {
    echo

    # Install iperf3 if not present
    if ! command -v iperf3 >/dev/null 2>&1; then
        log "Installing iperf3..."
        wait_for_apt
        apt-get update
        apt-get install -y -o DPkg::Lock::Timeout=60 iperf3
        if ! command -v iperf3 >/dev/null 2>&1; then
            echo "Failed to install iperf3."
            pause_return_menu
            return
        fi
        log "iperf3 installed."
    fi

    echo "iPerf3 Speed Test"
    echo "===================="
    echo "1) Server (listen mode - run this on destination server first)"
    echo "2) Client (connect mode - run this on source server)"
    echo "0) Back"
    echo
    local iperf_role
    read -rp "Choose [0-2]: " iperf_role
    case "$iperf_role" in
        1)
            echo
            log "Starting iperf3 server (listening on port 5201)..."
            echo "Waiting for client to connect... (Ctrl+C to stop)"
            echo
            iperf3 -s
            ;;
        2)
            local tn default_ip
            tn="$(select_tunnel)"
            if [[ -z "$tn" ]]; then
                echo "No tunnel installed. Enter destination IP manually."
                read -rp "Enter destination IP: " default_ip
                [[ -z "$default_ip" ]] && { pause_return_menu; return; }
            else
                default_ip="$(tunnel_ip_kharej "$tn")"
            fi
            echo
            local dest_ip
            read -rp "Enter destination IP [default: $default_ip]: " dest_ip
            [[ -z "$dest_ip" ]] && dest_ip="$default_ip"
            echo
            log "Running iperf3 client -> $dest_ip (single stream, reverse, 30s)..."
            echo
            iperf3 -c "$dest_ip" -P1 -R -t30
            ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
    pause_return_menu
}

function mtu_test() {
    local tn
    tn="$(select_tunnel)"
    if [[ -z "$tn" ]]; then
        echo "No tunnel installed."
        pause_return_menu
        return
    fi
    local default_ip core_file svc_name
    default_ip="$(tunnel_ip_kharej "$tn")"
    core_file="$(tunnel_core "$tn")"
    svc_name="$(tunnel_svc_name "$tn")"

    echo
    echo "MTU Discovery Test (Tunnel $tn)"
    echo "===================="
    echo
    local dest_ip
    read -rp "Enter destination IP [default: $default_ip]: " dest_ip
    [[ -z "$dest_ip" ]] && dest_ip="$default_ip"

    echo
    log "Finding optimal MTU for $dest_ip ..."
    echo

    local mtu=1500
    local step=10
    local best_mtu=1400

    # First quick check: does 1500 work?
    if ping -c 1 -W 2 -M do -s $((mtu - 28)) "$dest_ip" >/dev/null 2>&1; then
        echo "MTU 1500 works - no fragmentation issues."
        best_mtu=1500
    else
        # Binary search for optimal MTU
        local low=1200
        local high=1500
        while (( low <= high )); do
            mtu=$(( (low + high) / 2 ))
            local payload=$((mtu - 28))
            if ping -c 1 -W 2 -M do -s "$payload" "$dest_ip" >/dev/null 2>&1; then
                best_mtu=$mtu
                low=$((mtu + 1))
            else
                high=$((mtu - 1))
            fi
        done
    fi

    echo "========================================="
    echo " Optimal MTU: $best_mtu"
    echo "========================================="
    echo
    echo " Recommended Waterwall MTU: $((best_mtu - 80))"
    echo " (subtract ~80 bytes for tunnel overhead)"
    echo
    echo "========================================="

    if [[ -f "$core_file" ]] && command -v jq >/dev/null 2>&1; then
        local current_mtu
        current_mtu="$(jq -r '.misc.mtu // empty' "$core_file" 2>/dev/null)"
        if [[ -n "$current_mtu" ]]; then
            echo
            echo "Current Waterwall MTU in core.json: $current_mtu"
            local recommended=$((best_mtu - 80))
            if [[ "$current_mtu" -ne "$recommended" ]]; then
                local update_mtu
                read -rp "Update core.json MTU to $recommended? (y/N): " update_mtu
                update_mtu="$(echo "$update_mtu" | tr '[:upper:]' '[:lower:]')"
                if [[ "$update_mtu" == "y" || "$update_mtu" == "yes" ]]; then
                    local tmp
                    tmp="$(mktemp)"
                    jq --argjson m "$recommended" '.misc.mtu = $m' "$core_file" > "$tmp"
                    mv -f "$tmp" "$core_file"
                    log "core.json MTU updated to $recommended."
                    echo
                    local restart_ans
                    read -rp "Restart service to apply? (y/N): " restart_ans
                    restart_ans="$(echo "$restart_ans" | tr '[:upper:]' '[:lower:]')"
                    if [[ "$restart_ans" == "y" || "$restart_ans" == "yes" ]]; then
                        systemctl restart "${svc_name}.service" || true
                        log "Tunnel $tn service restarted."
                    fi
                fi
            else
                echo "Already set to optimal value."
            fi
        fi
    fi

    pause_return_menu
}

function service_management_menu() {
    if ! is_installed; then
        echo
        echo "No tunnels installed. Please install first."
        pause_return_menu
        return
    fi

    clear
    echo
    echo "Service Management"
    echo "===================="
    echo "1) Restart Service"
    echo "2) Service Status"
    echo "3) Test Tunnel"
    echo "4) Change Ports"
    echo "5) iPerf3 Speed Test"
    echo "6) MTU Test & Optimize"
    echo "7) Uninstall"
    echo "0) Back"
    echo
    local svc_choice
    read -rp "Choose an option [0-7]: " svc_choice
    case "$svc_choice" in
        1) restart_service ;;
        2) status_service ;;
        3) test_tunnel ;;
        4) change_ports ;;
        5) iperf3_test ;;
        6) mtu_test ;;
        7) uninstall ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu ;;
    esac
}

# ========================================
#   Update Core
# ========================================

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
    echo "Latest version:  v$latest_ver"
    echo
    local ans
    read -rp "Update to v$latest_ver? (y/N): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
        echo "Update cancelled."
        pause_return_menu
        return
    fi

    # Remove old binary so download_waterwall fetches new one
    rm -f "$BASE_DIR/Waterwall"

    download_waterwall || { pause_return_menu; return; }

    if is_installed; then
        local tunnels
        mapfile -t tunnels < <(get_installed_tunnels)
        local tn
        for tn in "${tunnels[@]}"; do
            local svc_name
            svc_name="$(tunnel_svc_name "$tn")"
            log "Restarting tunnel $tn ($svc_name)..."
            systemctl restart "${svc_name}.service" || true
        done
        echo "All tunnel services restarted with new version."
    fi

    pause_return_menu
}

# ========================================
#   Server Optimize
# ========================================

function detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -is | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

function sysctl_optimizations() {
    log "Backing up /etc/sysctl.conf to /etc/sysctl.conf.bak ..."
    cp -f /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true

    log "Applying sysctl optimizations..."
    cat > /etc/sysctl.conf <<'SYSEOF'
# ===== File System =====
fs.file-max = 67108864

# ===== Network Core =====
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 20000
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_default = 1048576
net.core.rmem_max = 33554432
net.core.wmem_default = 1048576
net.core.wmem_max = 33554432

# ===== TCP =====
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 8192 1048576 33554432
net.ipv4.tcp_wmem = 8192 1048576 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# ===== UDP =====
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ===== IPv4 Misc =====
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535

# ===== IPv6 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1

# ===== Virtual Memory =====
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 250
vm.min_free_kbytes = 65536

# ===== Netfilter (conntrack) =====
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
SYSEOF

    sysctl -p >/dev/null 2>&1
    log "sysctl parameters applied."
}

function optimize_tunnel_interfaces() {
    log "Optimizing tunnel interfaces..."

    # Install ethtool if not present
    if ! command -v ethtool >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq ethtool >/dev/null 2>&1 || true
    fi

    local iface
    for iface in $(ip link show 2>/dev/null | grep -oP 'wtun\d+' | sort -u); do
        if ip link show "$iface" >/dev/null 2>&1; then
            # Disable offloading on tunnel interfaces to reduce fragmentation
            ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true
            # Set txqueuelen higher for better throughput
            ip link set "$iface" txqueuelen 10000 2>/dev/null || true
            log "  $iface: offload disabled, txqueuelen=10000"
        fi
    done

    # Also optimize physical interfaces
    local phys_iface
    phys_iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)"
    if [[ -n "$phys_iface" ]]; then
        ip link set "$phys_iface" txqueuelen 10000 2>/dev/null || true
        log "  $phys_iface: txqueuelen=10000"
    fi
}

function limits_optimizations() {
    log "Applying system limits..."

    # /etc/security/limits.conf
    local limits_file="/etc/security/limits.conf"
    if ! grep -q "# Waterwall Optimize" "$limits_file" 2>/dev/null; then
        cp -f "$limits_file" "${limits_file}.bak" 2>/dev/null || true
        cat >> "$limits_file" <<'LIMEOF'

# Waterwall Optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
* soft core unlimited
* hard core unlimited
* soft stack unlimited
* hard stack unlimited
LIMEOF
        log "limits.conf updated."
    else
        log "limits.conf already optimized, skipping."
    fi

    # /etc/profile ulimit
    if ! grep -q "# Waterwall Optimize" /etc/profile 2>/dev/null; then
        cat >> /etc/profile <<'PROFEOF'

# Waterwall Optimize
ulimit -n 1048576
ulimit -s unlimited
ulimit -c unlimited
PROFEOF
        log "/etc/profile updated."
    else
        log "/etc/profile already optimized, skipping."
    fi
}

function enable_bbr() {
    log "Checking BBR support..."
    local distro="$1"

    # Load tcp_bbr module if not loaded
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    # Ensure tcp_bbr loads on boot
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        log "BBR module set to load on boot."
    fi

    # Verify
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log "BBR is active."
    else
        log "BBR may require a reboot to take effect."
    fi
}

function install_tunnel_tune_service() {
    log "Creating tunnel-tune service for post-boot interface tuning..."
    cat > /etc/systemd/system/waterwall-tune.service <<TUNESVC
[Unit]
Description=Waterwall Tunnel Interface Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash -c 'for iface in \$(ip link show 2>/dev/null | grep -oP "wtun\\d+" | sort -u); do ethtool -K "\$iface" gro off gso off tso off 2>/dev/null || true; ip link set "\$iface" txqueuelen 10000 2>/dev/null || true; done; PHYS=\$(ip route show default | awk "/default/ {print \\\$5}" | head -n1); [ -n "\$PHYS" ] && ip link set "\$PHYS" txqueuelen 10000 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
TUNESVC
    systemctl daemon-reload
    systemctl enable waterwall-tune.service >/dev/null 2>&1
    log "waterwall-tune.service enabled (runs after each boot)."
}

function get_installed_optimize_version() {
    if [[ -f "$OPTIMIZE_MARKER" ]]; then
        cat "$OPTIMIZE_MARKER" 2>/dev/null
    else
        echo ""
    fi
}

function save_optimize_version() {
    echo "$OPTIMIZE_VERSION" > "$OPTIMIZE_MARKER"
}

function optimize_server() {
    echo
    echo "Server Optimization"
    echo "====================="

    local distro
    distro="$(detect_distro)"

    case "$distro" in
        ubuntu|debian)
            log "Detected OS: $distro"
            ;;
        *)
            echo "This optimization supports Ubuntu and Debian only."
            echo "Detected: $distro"
            pause_return_menu
            return
            ;;
    esac

    local installed_ver
    installed_ver="$(get_installed_optimize_version)"

    if [[ -n "$installed_ver" ]]; then
        if [[ "$installed_ver" == "$OPTIMIZE_VERSION" ]]; then
            # Same version - ask user
            echo
            echo "Optimization v${installed_ver} is already applied on this server."
            local reapply
            read -rp "Re-apply? (y/N): " reapply
            reapply="$(echo "$reapply" | tr '[:upper:]' '[:lower:]')"
            if [[ "$reapply" != "y" && "$reapply" != "yes" ]]; then
                echo "Skipped."
                pause_return_menu
                return
            fi
        else
            # Old version - auto update
            echo
            log "Old optimization (v${installed_ver}) detected. Updating to v${OPTIMIZE_VERSION}..."
        fi
    fi

    echo
    echo "This will apply the following optimizations:"
    echo "  - Kernel & TCP tuning (sysctl + BBR with fq qdisc)"
    echo "  - System limits (ulimits / nofile)"
    echo "  - Network buffer & conntrack optimization"
    echo "  - Tunnel interface tuning (offload, txqueuelen)"
    echo

    if [[ -z "$installed_ver" ]]; then
        local ans
        read -rp "Continue? (y/N): " ans
        ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
            echo "Cancelled."
            pause_return_menu
            return
        fi
    fi

    echo

    # Install required kernel modules package on Debian if needed
    if [[ "$distro" == "debian" ]]; then
        if ! dpkg -l | grep -q linux-modules 2>/dev/null; then
            log "Ensuring kernel headers/modules are available..."
            wait_for_apt
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq linux-headers-"$(uname -r)" 2>/dev/null || true
        fi
    fi

    # Load conntrack module for nf_conntrack sysctl params
    modprobe nf_conntrack 2>/dev/null || true
    if ! grep -q "nf_conntrack" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "nf_conntrack" >> /etc/modules-load.d/bbr.conf
    fi

    sysctl_optimizations
    limits_optimizations
    enable_bbr "$distro"
    optimize_tunnel_interfaces
    install_tunnel_tune_service
    save_optimize_version

    echo
    echo "========================================="
    echo " Optimization v${OPTIMIZE_VERSION} applied!"
    echo "========================================="
    echo
    echo "A reboot is recommended for all changes to take full effect."
    echo
    echo "1) Reboot now"
    echo "0) Return to menu"
    local reboot_choice
    read -rp "Choose [0-1]: " reboot_choice
    case "$reboot_choice" in
        1) echo "Rebooting..."; reboot ;;
        *) return ;;
    esac
}

# ========================================
#   Mesh Network Deployment
# ========================================

function mesh_parse_file() {
    local file="$1"
    mesh_names=()
    mesh_ips=()
    mesh_users=()
    mesh_passes=()
    mesh_roles=()
    mesh_tunnel_ports=()
    mesh_user_ports=()

    local line line_num=0
    local name ip user pass role tunnel_port user_port
    local existing_ip existing_name
    local iran_count=0 kharej_count=0 r

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        line="${line%%#*}"
        [[ -z "${line// }" ]] && continue

        read -r name ip user pass role tunnel_port user_port <<< "$line"

        if [[ -z "$name" || -z "$ip" || -z "$user" || -z "$pass" || -z "$role" || -z "$tunnel_port" || -z "$user_port" ]]; then
            echo "Error: Line $line_num has missing fields. Expected: name ip user pass role tunnel_port user_port" >&2
            return 1
        fi

        if ! validate_ip "$ip"; then
            echo "Error: Line $line_num has invalid IP: $ip" >&2
            return 1
        fi

        if [[ "$role" != "iran" && "$role" != "kharej" ]]; then
            echo "Error: Line $line_num has invalid role '$role'. Must be 'iran' or 'kharej'." >&2
            return 1
        fi

        if ! validate_port "$tunnel_port"; then
            echo "Error: Line $line_num has invalid tunnel_port: $tunnel_port" >&2
            return 1
        fi

        if ! validate_port "$user_port"; then
            echo "Error: Line $line_num has invalid user_port: $user_port" >&2
            return 1
        fi

        for existing_ip in "${mesh_ips[@]}"; do
            if [[ "$existing_ip" == "$ip" ]]; then
                echo "Error: Duplicate IP $ip on line $line_num" >&2
                return 1
            fi
        done

        for existing_name in "${mesh_names[@]}"; do
            if [[ "$existing_name" == "$name" ]]; then
                echo "Error: Duplicate name '$name' on line $line_num" >&2
                return 1
            fi
        done

        mesh_names+=("$name")
        mesh_ips+=("$ip")
        mesh_users+=("$user")
        mesh_passes+=("$pass")
        mesh_roles+=("$role")
        mesh_tunnel_ports+=("$tunnel_port")
        mesh_user_ports+=("$user_port")
    done < "$file"

    for r in "${mesh_roles[@]}"; do
        [[ "$r" == "iran" ]] && ((iran_count++))
        [[ "$r" == "kharej" ]] && ((kharej_count++))
    done

    if [[ "$iran_count" -eq 0 ]]; then
        echo "Error: No Iran servers in file." >&2
        return 1
    fi
    if [[ "$kharej_count" -eq 0 ]]; then
        echo "Error: No Kharej servers in file." >&2
        return 1
    fi

    echo "Parsed: $iran_count Iran server(s), $kharej_count Kharej server(s)"
    return 0
}

function mesh_deploy_remote() {
    local role="$MESH_ROLE"
    local server_ip="$MESH_SERVER_IP"
    local tunnel_type="$MESH_TUNNEL_TYPE"
    local mtu="${MESH_MTU:-1400}"
    local tunnels_b64="$MESH_TUNNELS_B64"

    if [[ -z "$role" || -z "$server_ip" || -z "$tunnel_type" || -z "$tunnels_b64" ]]; then
        echo "Error: Missing MESH environment variables." >&2
        return 1
    fi

    local tunnels_json
    tunnels_json="$(echo "$tunnels_b64" | base64 -d 2>/dev/null)"
    if [[ -z "$tunnels_json" ]]; then
        echo "Error: Failed to decode MESH_TUNNELS_B64." >&2
        return 1
    fi

    install_prerequisites
    download_waterwall || { echo "Error: Failed to download Waterwall." >&2; return 1; }

    local count
    count="$(echo "$tunnels_json" | jq -r '. | length')"
    local i tn peer_ip core_port user_port final_ip

    for ((i = 0; i < count; i++)); do
        tn="$(echo "$tunnels_json" | jq -r ".[$i].tunnel_num")"
        peer_ip="$(echo "$tunnels_json" | jq -r ".[$i].peer_ip")"
        core_port="$(echo "$tunnels_json" | jq -r ".[$i].core_port")"
        user_port="$(echo "$tunnels_json" | jq -r ".[$i].user_port")"
        final_ip="$(echo "$tunnels_json" | jq -r ".[$i].final_ip // \"127.0.0.1\"")"

        if is_tunnel_installed "$tn"; then
            echo "Warning: Tunnel $tn already exists on this server, skipping." >&2
            continue
        fi

        mkdir -p "$(tunnel_dir "$tn")"
        mkdir -p "$(tunnel_log_dir "$tn")"

        echo "Setting up tunnel $tn ($role → peer $peer_ip)..."

        if [[ "$tunnel_type" == "bitswap" ]]; then
            if [[ "$role" == "iran" ]]; then
                generate_core_json "$mtu" "$tn"
                generate_bitswap_iran_config "$server_ip" "$peer_ip" "$user_port" "$core_port" "$tn"
            else
                generate_core_json "$mtu" "$tn"
                generate_bitswap_kharej_config "$peer_ip" "$server_ip" "$core_port" "$user_port" "$tn" "$final_ip"
            fi
        elif [[ "$tunnel_type" == "reverse" ]]; then
            if [[ "$role" == "iran" ]]; then
                generate_core_json "$mtu" "$tn"
                generate_reverse_bitswap_iran_config "$server_ip" "$peer_ip" "$user_port" "$core_port" "$tn"
            else
                generate_core_json "$mtu" "$tn"
                generate_reverse_bitswap_kharej_config "$peer_ip" "$server_ip" "$core_port" "$user_port" "$tn" 32 "$final_ip"
            fi
        elif [[ "$tunnel_type" == "packet" ]]; then
            ports=("$user_port")
            if [[ "$role" == "iran" ]]; then
                generate_core_json "$mtu" "$tn"
                generate_iran_config "$server_ip" "$peer_ip" "$tn"
            else
                generate_core_json "$mtu" "$tn"
                generate_kharej_config "$peer_ip" "$server_ip" "$tn"
            fi
        fi

        install_service "$tn"
        echo "Tunnel $tn installed and started."
    done

    echo "Running server optimizations..."
    local distro
    distro="$(detect_distro)"
    sysctl_optimizations
    enable_bbr "$distro"
    limits_optimizations
    optimize_tunnel_interfaces
    install_tunnel_tune_service

    echo "Mesh deployment on $server_ip complete. $count tunnel(s) configured."
}

function mesh_deploy() {
    clear
    echo
    echo "Mesh Network Deployment"
    echo "========================="
    echo
    echo "This will read a server file and create a full mesh of"
    echo "Waterwall tunnels (each Iran connects to every Kharej)."
    echo
    echo "File format (space/tab-delimited, # for comments):"
    echo "  name  ip  user  pass  role  tunnel_port  user_port"
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }

    if [[ ! -f "$file_path" ]]; then
        echo "File not found: $file_path"
        pause_return_menu
        return
    fi

    echo
    echo "Tunnel type:"
    echo "  1) BitSwap (Kharej listens, Iran connects)"
    echo "  2) Reverse BitSwap (Iran listens, Kharej connects)"
    echo "  3) PacketTunnel (Classic, raw IP)"
    echo "  0) Back"
    echo
    local tunnel_choice tunnel_type
    read -rp "Choose [0-3]: " tunnel_choice || { pause_return_menu; return; }
    case "$tunnel_choice" in
        1) tunnel_type="bitswap" ;;
        2) tunnel_type="reverse" ;;
        3) tunnel_type="packet" ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu; return ;;
    esac

    local mtu_val
    read -rp "Enter MTU value [default: 1400]: " mtu_val || mtu_val=""
    [[ -z "$mtu_val" ]] && mtu_val=1400

    echo
    echo "Parsing server file..."
    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    local iran_indices=() kharej_indices=()
    local idx
    for idx in "${!mesh_roles[@]}"; do
        if [[ "${mesh_roles[$idx]}" == "iran" ]]; then
            iran_indices+=("$idx")
        else
            kharej_indices+=("$idx")
        fi
    done

    local num_iran="${#iran_indices[@]}"
    local num_kharej="${#kharej_indices[@]}"
    local total_tunnels=$((num_iran * num_kharej))

    echo
    echo "Mesh plan: $num_iran Iran × $num_kharej Kharej = $total_tunnels tunnel(s)"
    echo

    local iran_i kharej_j tn iran_idx kharej_idx
    local iran_name kharej_name iran_ip kharej_ip
    local iran_user_port kharej_tunnel_port core_port iran_listen_port
    local iran_tunnel_port

    printf "%-8s %-10s %-12s %-12s %-16s %-16s\n" "Tunnel#" "Iran" "Kharej" "Iran port" "Kharej port" "Core port"
    printf "%-8s %-10s %-12s %-12s %-16s %-16s\n" "-------" "----" "------" "---------" "-----------" "---------"

    for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
        for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
            tn=$((iran_i * num_kharej + kharej_j + 1))
            iran_idx="${iran_indices[$iran_i]}"
            kharej_idx="${kharej_indices[$kharej_j]}"
            iran_name="${mesh_names[$iran_idx]}"
            kharej_name="${mesh_names[$kharej_idx]}"
            iran_user_port="${mesh_user_ports[$iran_idx]}"
            kharej_tunnel_port="${mesh_tunnel_ports[$kharej_idx]}"
            iran_tunnel_port="${mesh_tunnel_ports[$iran_idx]}"

            if [[ "$tunnel_type" == "bitswap" ]]; then
                core_port=$((kharej_tunnel_port + iran_i))
                iran_listen_port=$((iran_user_port + kharej_j))
            elif [[ "$tunnel_type" == "reverse" ]]; then
                core_port=$((iran_tunnel_port + kharej_j))
                iran_listen_port=$((iran_user_port + kharej_j))
            else
                core_port="N/A"
                iran_listen_port=$((iran_user_port + kharej_j))
            fi

            printf "%-8s %-10s %-12s %-12s %-16s %-16s\n" "$tn" "$iran_name" "$kharej_name" "$iran_listen_port" "${mesh_user_ports[$kharej_idx]}" "$core_port"
        done
    done

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
        apt-get install -y -qq sshpass >/dev/null 2>&1
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "Failed to install sshpass. Please install it manually."
            pause_return_menu
            return
        fi
    fi

    echo
    echo "Deploying to servers..."
    echo

    local s_idx s_name s_ip s_user s_pass s_role s_tunnel_port s_user_port
    local iran_tunnels_json kharej_tunnels_json
    local iran_tn kharej_tn
    local iran_core_port kharej_core_port
    local iran_up kharej_up
    local iran_tp kharej_tp
    local tunnels_json b64
    local ssh_status
    local kharej_j iran_i ii jj
    local kharej_idx kharej_ip iran_idx iran_ip

    for ((s_idx = 0; s_idx < ${#mesh_names[@]}; s_idx++)); do
        s_name="${mesh_names[$s_idx]}"
        s_ip="${mesh_ips[$s_idx]}"
        s_user="${mesh_users[$s_idx]}"
        s_pass="${mesh_passes[$s_idx]}"
        s_role="${mesh_roles[$s_idx]}"
        s_tunnel_port="${mesh_tunnel_ports[$s_idx]}"
        s_user_port="${mesh_user_ports[$s_idx]}"

        echo "========================================"
        echo "Deploying to: $s_name ($s_ip) [$s_role]"
        echo "========================================"

        tunnels_json="[]"

        local iran_i_pos kharej_j_pos
        iran_i_pos=""
        kharej_j_pos=""
        for ((ii = 0; ii < num_iran; ii++)); do
            if [[ "${iran_indices[$ii]}" == "$s_idx" ]]; then
                iran_i_pos="$ii"
                break
            fi
        done
        for ((jj = 0; jj < num_kharej; jj++)); do
            if [[ "${kharej_indices[$jj]}" == "$s_idx" ]]; then
                kharej_j_pos="$jj"
                break
            fi
        done

        if [[ "$s_role" == "iran" ]]; then
            for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
                kharej_idx="${kharej_indices[$kharej_j]}"
                kharej_ip="${mesh_ips[$kharej_idx]}"
                kharej_tunnel_port="${mesh_tunnel_ports[$kharej_idx]}"

                iran_tn=$((iran_i_pos * num_kharej + kharej_j + 1))

                if [[ "$tunnel_type" == "bitswap" ]]; then
                    iran_core_port=$((kharej_tunnel_port + iran_i_pos))
                elif [[ "$tunnel_type" == "reverse" ]]; then
                    iran_core_port=$((s_tunnel_port + kharej_j))
                else
                    iran_core_port=0
                fi

                iran_up=$((s_user_port + kharej_j))

                tunnels_json="$(echo "$tunnels_json" | jq --argjson tn "$iran_tn" --arg peer "$kharej_ip" --argjson cp "$iran_core_port" --argjson up "$iran_up" --arg fip "127.0.0.1" \
                    '. + [{"tunnel_num": $tn, "peer_ip": $peer, "core_port": $cp, "user_port": $up, "final_ip": $fip}]')"
            done
        else
            for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
                iran_idx="${iran_indices[$iran_i]}"
                iran_ip="${mesh_ips[$iran_idx]}"
                iran_up="${mesh_user_ports[$iran_idx]}"
                iran_tp="${mesh_tunnel_ports[$iran_idx]}"

                kharej_tn=$((iran_i * num_kharej + kharej_j_pos + 1))

                if [[ "$tunnel_type" == "bitswap" ]]; then
                    kharej_core_port=$((s_tunnel_port + iran_i))
                elif [[ "$tunnel_type" == "reverse" ]]; then
                    kharej_core_port=$((iran_tp + kharej_j_pos))
                else
                    kharej_core_port=0
                fi

                tunnels_json="$(echo "$tunnels_json" | jq --argjson tn "$kharej_tn" --arg peer "$iran_ip" --argjson cp "$kharej_core_port" --argjson up "$iran_up" --arg fip "127.0.0.1" \
                    '. + [{"tunnel_num": $tn, "peer_ip": $peer, "core_port": $cp, "user_port": $up, "final_ip": $fip}]')"
            done
        fi

        b64="$(echo "$tunnels_json" | base64 -w0)"

        echo "  Copying script to $s_ip..."
        if ! sshpass -p "$s_pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$0" "${s_user}@${s_ip}:/root/packettunnel.sh" >/dev/null 2>&1; then
            echo "  ERROR: Failed to copy script to $s_name ($s_ip). Skipping."
            continue
        fi

        echo "  Running mesh deployment on $s_ip..."
        sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${s_user}@${s_ip}" \
            "MESH_ROLE=$s_role MESH_SERVER_IP=$s_ip MESH_TUNNEL_TYPE=$tunnel_type MESH_MTU=$mtu_val MESH_TUNNELS_B64=$b64 bash /root/packettunnel.sh --mesh-deploy" \
            2>&1 | tee "mesh-${s_name}.log"

        ssh_status=${PIPESTATUS[0]}
        if [[ "$ssh_status" -ne 0 ]]; then
            echo "  WARNING: SSH command returned non-zero status for $s_name."
        else
            echo "  $s_name deployed successfully."
        fi
        echo
    done

    echo "========================================"
    echo "Mesh deployment complete!"
    echo "========================================"
    echo
    echo "Summary of configured tunnels:"
    echo

    printf "%-8s %-10s %-12s %-12s %-16s\n" "Tunnel#" "Iran" "Kharej" "Iran port" "Kharej port"
    printf "%-8s %-10s %-12s %-12s %-16s\n" "-------" "----" "------" "---------" "-----------"

    local tn iran_name kharej_name iran_user_port kharej_user_port iran_listen_port

    for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
        for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
            tn=$((iran_i * num_kharej + kharej_j + 1))
            iran_idx="${iran_indices[$iran_i]}"
            kharej_idx="${kharej_indices[$kharej_j]}"
            iran_name="${mesh_names[$iran_idx]}"
            kharej_name="${mesh_names[$kharej_idx]}"
            iran_user_port="${mesh_user_ports[$iran_idx]}"
            kharej_user_port="${mesh_user_ports[$kharej_idx]}"

            if [[ "$tunnel_type" == "bitswap" ]]; then
                iran_listen_port=$((iran_user_port + kharej_j))
            elif [[ "$tunnel_type" == "reverse" ]]; then
                iran_listen_port=$((iran_user_port + kharej_j))
            else
                iran_listen_port=$((iran_user_port + kharej_j))
            fi

            printf "%-8s %-10s %-12s %-12s %-16s\n" "$tn" "$iran_name" "$kharej_name" "$iran_listen_port" "$kharej_user_port"
        done
    done

    echo
    echo "Log files saved as mesh-*.log in current directory."
    pause_return_menu
}

# ========================================
#   Main Menu
# ========================================

function main_menu() {
    install_prerequisites
    while true; do
        banner
        echo "Waterwall Setup"
        echo "=================="
        echo "1) Install Tunnel"
        echo "2) Service Management"
        echo "3) Update Core"
        echo "4) Optimize Server"
        echo "5) Mesh Deploy"
        echo "0) Exit"
        echo
        local choice
        read -rp "Choose an option [0-5]: " choice || exit 0
        case "$choice" in
            1) install_menu ;;
            2) service_management_menu ;;
            3) update_core ;;
            4) optimize_server ;;
            5) mesh_deploy ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option."; pause_return_menu ;;
        esac
    done
}

if [[ "$1" == "--mesh-deploy" ]]; then
    mesh_deploy_remote
    exit 0
fi
main_menu