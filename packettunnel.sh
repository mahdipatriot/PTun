#!/bin/bash
set -euo pipefail

# ============================================================================
# WaterWall Full Mesh Installer
# Deploys N×M mesh network with ONE WaterWall instance per server
# All listeners can share port 443 by binding to different IPs
# ============================================================================

BASE_DIR="/root/waterwall"
LIBS_DIR="/root/waterwall/libs"
GITHUB_REPO="radkesvat/WaterWall"
OPTIMIZE_MARKER="/etc/waterwall_optimize.ver"
OPTIMIZE_VERSION="3"
MESH_SVC_NAME="waterwall-mesh"
MESH_SVC_FILE="/etc/systemd/system/waterwall-mesh.service"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

function log() { echo "[+] $1"; }

function pause_return_menu() {
    echo
    read -rp "Press Enter to return to menu..." _
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
    local default="${2:-}"
    local result=""
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$label [default: $default]: " result || { echo ""; return; }
            [[ -z "$result" ]] && result="$default"
        else
            read -rp "$label: " result || { echo ""; return; }
        fi
        [[ "$result" == "0" ]] && echo "" && return
        if validate_port "$result"; then
            echo "$result"
            return
        fi
        echo "Invalid port. Must be a number between 1 and 65535." >&2
    done
}

function ask_string() {
    local label="$1"
    local default="${2:-}"
    local result=""
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$label [default: $default]: " result || { echo ""; return; }
            [[ -z "$result" ]] && result="$default"
        else
            read -rp "$label: " result || { echo ""; return; }
        fi
        if [[ -n "$result" ]]; then
            echo "$result"
            return
        fi
        echo "Cannot be empty." >&2
    done
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

# ============================================================================
# APT HELPERS
# ============================================================================

function kill_apt_locks() {
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
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
    rm -f "${lock_files[@]}" 2>/dev/null || true
    dpkg --configure -a >/dev/null 2>&1 || true
}

function wait_for_apt() {
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
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

# ============================================================================
# WATERWALL DOWNLOAD
# ============================================================================

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

    local oldcpu=""
    if [[ -z "${MESH_ROLE:-}" ]]; then
        echo
        read -rp "Download old CPU build? (y/N): " oldcpu || oldcpu=""
        oldcpu="$(echo "$oldcpu" | tr '[:upper:]' '[:lower:]')"
    fi

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

# ============================================================================
# IP ADDRESSING HELPERS (parametric for N×M mesh)
# ============================================================================

function mesh_tun_ip_a()       { echo "10.$1.$2.1"; }
function mesh_tun_ip_b()       { echo "10.$1.$2.2"; }
function mesh_tun_cidr_a()     { echo "10.$1.$2.1/24"; }
function mesh_tun_cidr_b()     { echo "10.$1.$2.2/24"; }
function mesh_dummy_iran()     { echo "12.$1.$2.12"; }
function mesh_dummy_kharej()   { echo "12.$1.$2.13"; }
function mesh_tun_subnet2()    { echo "10.$((100 + $1)).$2.1/24"; }
function mesh_tun_dev_a()      { echo "tunA$1B$2"; }
function mesh_tun_dev_b_pri()  { echo "tunB$2A$1"; }
function mesh_tun_dev_b_sec()  { echo "tunB$2A${1}s"; }

# ============================================================================
# SYSTEMD SERVICE
# ============================================================================

function install_mesh_service() {
    log "Creating systemd service: $MESH_SVC_NAME ..."
    cat > "$MESH_SVC_FILE" <<EOF
[Unit]
Description=WaterWall Full Mesh Service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/Waterwall
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    log "Reloading systemd and enabling $MESH_SVC_NAME ..."
    systemctl daemon-reload
    systemctl enable "${MESH_SVC_NAME}.service"
    systemctl restart "${MESH_SVC_NAME}.service"
}

# ============================================================================
# CONFIG GENERATORS - TUNNEL CONFIGS
# ============================================================================

function generate_tunnel_a_config() {
    local ai=$1 bj=$2 iran_ip=$3 kharej_ip=$4 outdir=$5
    local t_ip_iran t_ip_kharej t_cidr_iran t_dev d_iran d_kharej
    t_ip_iran="$(mesh_tun_ip_a $ai $bj)"
    t_ip_kharej="$(mesh_tun_ip_b $ai $bj)"
    t_cidr_iran="$(mesh_tun_cidr_a $ai $bj)"
    t_dev="$(mesh_tun_dev_a $ai $bj)"
    d_iran="$(mesh_dummy_iran $ai $bj)"
    d_kharej="$(mesh_dummy_kharej $ai $bj)"

    mkdir -p "$outdir"
    cat > "$outdir/tunnel_a${ai}_b${bj}.json" <<EOF
{
    "name": "bitswap-a${ai}-b${bj}",
    "variables": {
        "ip_server_iran": "$iran_ip",
        "ip_server_kharej": "$kharej_ip",
        "t_ip_iran": "$t_ip_iran",
        "t_ip_kharej": "$t_ip_kharej",
        "t_cidr_iran": "$t_cidr_iran",
        "t_dev": "$t_dev",
        "dummy_iran": "$d_iran",
        "dummy_kharej": "$d_kharej"
    },
    "nodes": [
        {
            "name": "my_tun",
            "type": "TunDevice",
            "settings": {
                "device-name": \$t_dev\$,
                "device-ip": \$t_cidr_iran\$
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": { "ipv4": \$ip_server_iran\$ },
                    "dest-ip": { "ipv4": \$ip_server_kharej\$ }
                },
                "down": {
                    "source-ip": { "ipv4": \$t_ip_kharej\$ },
                    "dest-ip": { "ipv4": \$t_ip_iran\$ }
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
                "capture-ip": \$dummy_iran\$
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

function generate_tunnel_b_config() {
    local ai=$1 bj=$2 iran_ip=$3 kharej_ip=$4 outdir=$5
    local t_ip_iran t_ip_kharej t_cidr_iran t_cidr_kharej
    local t_dev_p t_dev_s d_iran d_kharej
    t_ip_iran="$(mesh_tun_ip_a $ai $bj)"
    t_ip_kharej="$(mesh_tun_ip_b $ai $bj)"
    t_cidr_iran="$(mesh_tun_cidr_a $ai $bj)"
    t_cidr_kharej="$(mesh_tun_cidr_b $ai $bj)"
    t_dev_p="$(mesh_tun_dev_b_pri $ai $bj)"
    t_dev_s="$(mesh_tun_dev_b_sec $ai $bj)"
    d_iran="$(mesh_dummy_iran $ai $bj)"
    d_kharej="$(mesh_dummy_kharej $ai $bj)"
    local t_subnet2
    t_subnet2="$(mesh_tun_subnet2 $ai $bj)"

    mkdir -p "$outdir"
    cat > "$outdir/tunnel_b${bj}_a${ai}.json" <<EOF
{
    "name": "bitswap-b${bj}-a${ai}",
    "variables": {
        "ip_server_iran": "$iran_ip",
        "ip_server_kharej": "$kharej_ip",
        "t_ip_iran": "$t_ip_iran",
        "t_ip_kharej": "$t_ip_kharej",
        "t_cidr_iran": "$t_cidr_iran",
        "t_cidr_kharej": "$t_cidr_kharej",
        "t_dev_primary": "$t_dev_p",
        "t_dev_secondary": "$t_dev_s",
        "t_subnet2": "$t_subnet2",
        "dummy_iran": "$d_iran",
        "dummy_kharej": "$d_kharej"
    },
    "nodes": [
        {
            "name": "my_tun2",
            "type": "TunDevice",
            "settings": {
                "device-name": \$t_dev_secondary\$,
                "device-ip": \$t_subnet2\$
            },
            "next": "ipcorrect"
        },
        {
            "name": "ipcorrect",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": { "ipv4": \$t_ip_kharej\$ },
                    "dest-ip": { "ipv4": \$t_ip_iran\$ }
                },
                "down": {
                    "source-ip": { "ipv4": \$t_ip_kharej\$ },
                    "dest-ip": { "ipv4": \$t_ip_iran\$ }
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
            "name": "my_tun",
            "type": "TunDevice",
            "settings": {
                "device-name": \$t_dev_primary\$,
                "device-ip": \$t_cidr_iran\$
            },
            "next": "ipovsrc"
        },
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "up": {
                    "source-ip": { "ipv4": \$ip_server_kharej\$ },
                    "dest-ip": { "ipv4": \$ip_server_iran\$ }
                },
                "down": {
                    "source-ip": { "ipv4": \$t_ip_kharej\$ },
                    "dest-ip": { "ipv4": \$t_ip_iran\$ }
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
                "capture-ip": \$dummy_kharej\$
            }
        }
    ]
}
EOF
}

# ============================================================================
# CONFIG GENERATORS - REVERSE APPROACH
# ============================================================================

function generate_reverse_server_config() {
    local ai=$1 iran_ip=$2 reverse_port=$3 reverse_secret=$4 user_port=$5 outdir=$6
    shift 6
    local -a tun_ips=("$@")

    mkdir -p "$outdir"

    # Build whitelist of kharej TUN source IPs (10.{ai}.{bj}.2)
    local whitelist=""
    local bj=1
    for tip in "${tun_ips[@]}"; do
        # Iran TUN IP is 10.{ai}.{bj}.1, kharej side is 10.{ai}.{bj}.2
        local kharej_tip
        kharej_tip="$(echo "$tip" | sed 's/\.[0-9]*$/\.2/')"
        if [[ -n "$whitelist" ]]; then
            whitelist+=", "
        fi
        whitelist+="\"${kharej_tip}/32\""
        bj=$((bj + 1))
    done

    cat > "$outdir/reverse_server_a${ai}.json" <<EOF
{
    "name": "a${ai}-reverse-mesh-server",
    "variables": {
        "user_port": $user_port,
        "reverse_port": $reverse_port,
        "reverse_secret": "$reverse_secret"
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": { "address": "0.0.0.0", "port": \$user_port\$, "nodelay": true },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": { "data": "src_context->port" },
            "next": "bridge_user_side"
        },
        {
            "name": "bridge_user_side",
            "type": "Bridge",
            "settings": { "pair": "bridge_reverse_side" }
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": { "pair": "bridge_user_side" }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": { "reverse-secret": \$reverse_secret\$ },
            "next": "bridge_reverse_side"
        },
        {
            "name": "kharej_inbound",
            "type": "TcpListener",
            "settings": { "address": "0.0.0.0", "port": \$reverse_port\$, "nodelay": true, "whitelist": [ $whitelist ] },
            "next": "reverse_server"
        }
    ]
}
EOF
}

function generate_reverse_client_config() {
    local bj=$1 ai=$2 tun_ip_a=$3 reverse_port=$4 final_ip=$5 final_port=$6 min_unused=$7 reverse_secret=$8 outdir=$9

    mkdir -p "$outdir"
    cat > "$outdir/reverse_client_b${bj}_a${ai}.json" <<EOF
{
    "name": "b${bj}-reverse-client-to-a${ai}",
    "variables": {
        "reverse_port": $reverse_port,
        "final_ip": "$final_ip",
        "final_port": $final_port,
        "min_held_connections": $min_unused,
        "reverse_secret": "$reverse_secret",
        "tun_ip_a": "$tun_ip_a"
    },
    "nodes": [
        {
            "name": "outbound_to_service",
            "type": "TcpConnector",
            "settings": {
                "address": \$final_ip\$,
                "port": \$final_port\$,
                "nodelay": true
            }
        },
        {
            "name": "header-server",
            "type": "HeaderServer",
            "settings": { "override": "dest_context->port" },
            "next": "outbound_to_service"
        },
        {
            "name": "bridge_local_side",
            "type": "Bridge",
            "settings": { "pair": "bridge_reverse_side" },
            "next": "header-server"
        },
        {
            "name": "bridge_reverse_side",
            "type": "Bridge",
            "settings": { "pair": "bridge_local_side" },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": \$min_held_connections\$,
                "reverse-secret": \$reverse_secret\$
            },
            "next": "tcp_to_iran"
        },
        {
            "name": "tcp_to_iran",
            "type": "TcpConnector",
            "settings": {
                "address": \$tun_ip_a\$,
                "port": \$reverse_port\$,
                "nodelay": true
            }
        }
    ]
}
EOF
}

# ============================================================================
# CONFIG GENERATORS - HAPROXY SINGLE-TARGET VARIANTS
# ============================================================================

function generate_forward_user_config_single() {
    local ai=$1 bj=$2 local_port=$3 forward_port=$4 mux_count=$5 kharej_tun_ip=$6 outdir=$7

    mkdir -p "$outdir"
    cat > "$outdir/user_forward_a${ai}_b${bj}.json" <<EOF
{
    "name": "a${ai}-forward-b${bj}",
    "variables": {
        "local_port": $local_port,
        "port_to_connect": $forward_port,
        "each_worker_mux_connections_count": $mux_count
    },
    "nodes": [
        {
            "name": "users_inbound_b${bj}",
            "type": "TcpListener",
            "settings": { "address": "127.0.0.1", "port": \$local_port\$, "nodelay": true },
            "next": "header-client-b${bj}"
        },
        {
            "name": "header-client-b${bj}",
            "type": "HeaderClient",
            "settings": { "data": "src_context->port" },
            "next": "mux-client-b${bj}"
        },
        {
            "name": "mux-client-b${bj}",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "tcp-out-b${bj}"
        },
        {
            "name": "tcp-out-b${bj}",
            "type": "TcpConnector",
            "settings": {
                "address": "$kharej_tun_ip",
                "port": \$port_to_connect\$,
                "nodelay": true
            }
        }
    ]
}
EOF
}

function generate_reverse_server_config_single() {
    local ai=$1 bj=$2 tun_ip_a=$3 reverse_port=$4 reverse_secret=$5 local_port=$6 outdir=$7

    mkdir -p "$outdir"
    cat > "$outdir/reverse_server_a${ai}_b${bj}.json" <<EOF
{
    "name": "a${ai}-reverse-b${bj}",
    "variables": {
        "local_port": $local_port,
        "reverse_port": $reverse_port,
        "reverse_secret": "$reverse_secret"
    },
    "nodes": [
        {
            "name": "users_inbound_b${bj}",
            "type": "TcpListener",
            "settings": { "address": "127.0.0.1", "port": \$local_port\$, "nodelay": true },
            "next": "header-client-b${bj}"
        },
        {
            "name": "header-client-b${bj}",
            "type": "HeaderClient",
            "settings": { "data": "src_context->port" },
            "next": "bridge_user_side_b${bj}"
        },
        {
            "name": "bridge_user_side_b${bj}",
            "type": "Bridge",
            "settings": { "pair": "bridge_reverse_side_b${bj}" }
        },
        {
            "name": "bridge_reverse_side_b${bj}",
            "type": "Bridge",
            "settings": { "pair": "bridge_user_side_b${bj}" }
        },
        {
            "name": "reverse_server_b${bj}",
            "type": "ReverseServer",
            "settings": { "reverse-secret": \$reverse_secret\$ },
            "next": "bridge_reverse_side_b${bj}"
        },
        {
            "name": "kharej_inbound_b${bj}",
            "type": "TcpListener",
            "settings": { "address": "$tun_ip_a", "port": \$reverse_port\$, "nodelay": true },
            "next": "reverse_server_b${bj}"
        }
    ]
}
EOF
}

function generate_haproxy_config() {
    local bind_addr="$1" hc_sni="$2" outfile="$3"
    shift 3
    local -a servers=("$@")

    local sni_line=""
    if [[ -n "$hc_sni" ]]; then
        sni_line=" sni $hc_sni"
    fi

    cat > "$outfile" <<EOF
global
    log /dev/log local0
    maxconn 100000

defaults
    mode tcp
    log global
    option dontlognull
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend ww_in
    bind ${bind_addr}:443
    default_backend ww_be

backend ww_be
    balance roundrobin
    default-server check check-ssl verify none inter 3s fall 3 rise 2${sni_line}
$(printf '    %s\n' "${servers[@]}")
EOF
}

function install_haproxy() {
    if ! command -v haproxy >/dev/null 2>&1; then
        log "Installing HAProxy..."
        wait_for_apt
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq haproxy >/dev/null 2>&1
        log "HAProxy installed."
    fi
    mkdir -p /etc/haproxy
    if [[ -f /etc/default/haproxy ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/haproxy 2>/dev/null || true
        grep -q '^ENABLED=' /etc/default/haproxy 2>/dev/null || echo 'ENABLED=1' >> /etc/default/haproxy
    fi
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable haproxy 2>/dev/null || true
    systemctl restart haproxy
    log "HAProxy service enabled and restarted."
}

# ============================================================================
# CONFIG GENERATORS - FORWARD APPROACH
# ============================================================================

function generate_forward_user_config() {
    local ai=$1 user_port=$2 forward_port=$3 mux_count=$4 outdir=$5
    shift 5
    local -a kharej_tun_ips=("$@")

    mkdir -p "$outdir"
    local addresses=""
    local bj=1
    for ktip in "${kharej_tun_ips[@]}"; do
        if [[ -n "$addresses" ]]; then
            addresses+=","
        fi
        addresses+=$(cat <<EOF
          { "address": "$ktip", "port": \$port_to_connect\$, "weight": 1, "nodelay": true }
EOF
)
        bj=$((bj + 1))
    done

    cat > "$outdir/user_forward_a${ai}.json" <<EOF
{
    "name": "a${ai}-forward-mesh",
    "variables": {
        "port_to_listen": $user_port,
        "port_to_connect": $forward_port,
        "each_worker_mux_connections_count": $mux_count
    },
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": { "address": "0.0.0.0", "port": \$port_to_listen\$, "nodelay": true },
            "next": "header-client"
        },
        {
            "name": "header-client",
            "type": "HeaderClient",
            "settings": { "data": "src_context->port" },
            "next": "mux-client"
        },
        {
            "name": "mux-client",
            "type": "MuxClient",
            "settings": {
                "mode": "fixed-connections-count",
                "per-worker-connections-count": \$each_worker_mux_connections_count\$
            },
            "next": "weighted-out"
        },
        {
            "name": "weighted-out",
            "type": "TcpConnector",
            "settings": {
                "addresses": [
$addresses
                ]
            }
        }
    ]
}
EOF
}

function generate_forward_server_config() {
    local bj=$1 forward_port=$2 final_ip=$3 final_port=$4 outdir=$5
    shift 5
    local -a iran_tun_ips=("$@")

    mkdir -p "$outdir"
    local blocks=""
    local ai=1
    for itip in "${iran_tun_ips[@]}"; do
        if [[ -n "$blocks" ]]; then
            blocks+=","
        fi
        blocks+=$(cat <<EOF
        {
            "name": "users_inbound_a${ai}",
            "type": "TcpListener",
            "settings": { "address": "$itip", "port": \$port_to_listen\$, "nodelay": true },
            "next": "mux-s-a${ai}"
        },
        {
            "name": "mux-s-a${ai}",
            "type": "MuxServer",
            "settings": {},
            "next": "header-server-a${ai}"
        },
        {
            "name": "header-server-a${ai}",
            "type": "HeaderServer",
            "settings": { "override": "dest_context->port" },
            "next": "tcp-out-a${ai}"
        },
        {
            "name": "tcp-out-a${ai}",
            "type": "TcpConnector",
            "settings": { "address": \$final_ip\$, "port": \$final_port\$, "nodelay": true }
        }
EOF
)
        ai=$((ai + 1))
    done

    cat > "$outdir/server_forward_b${bj}.json" <<EOF
{
    "name": "b${bj}-forward-server",
    "variables": {
        "port_to_listen": $forward_port,
        "final_ip": "$final_ip",
        "final_port": $final_port
    },
    "nodes": [
$blocks
    ]
}
EOF
}

# ============================================================================
# CORE.JSON GENERATOR
# ============================================================================

function generate_core_json() {
    local mtu=$1 outdir=$2
    shift 2
    local -a config_files=("$@")

    mkdir -p "$outdir"
    local configs=""
    for cf in "${config_files[@]}"; do
        if [[ -n "$configs" ]]; then
            configs+=","
        fi
        configs+="\"$cf\""
    done

    cat > "$outdir/core.json" <<EOF
{
    "log": {
        "path": "log/",
        "internal": { "loglevel": "DEBUG", "file": "internal.log", "console": true },
        "core": { "loglevel": "DEBUG", "file": "core.log", "console": true },
        "network": { "loglevel": "DEBUG", "file": "network.log", "console": true },
        "dns": { "loglevel": "SILENT", "file": "dns.log", "console": false }
    },
    "dns": { "domain-strategy": "prefer-ipv4" },
    "misc": {
        "workers": 4,
        "ram-profile": "server",
        "mtu": $mtu,
        "try-enabling-bbr": true,
        "libs-path": "$LIBS_DIR/"
    },
    "configs": [
        $configs
    ]
}
EOF
}

# ============================================================================
# SERVER FILE PARSING
# ============================================================================

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
        line_num=$((line_num + 1))
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

        for existing_ip in "${mesh_ips[@]:-}"; do
            if [[ "$existing_ip" == "$ip" ]]; then
                echo "Error: Duplicate IP $ip on line $line_num" >&2
                return 1
            fi
        done

        for existing_name in "${mesh_names[@]:-}"; do
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
        [[ "$r" == "iran" ]] && iran_count=$((iran_count + 1))
        [[ "$r" == "kharej" ]] && kharej_count=$((kharej_count + 1))
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

# ============================================================================
# MESH DEPLOY - REMOTE (runs on target server via SSH)
# ============================================================================

function mesh_deploy_remote() {
    local role="$MESH_ROLE"
    local server_ip="$MESH_SERVER_IP"
    local approach="$MESH_APPROACH"
    local mtu="${MESH_MTU:-1400}"
    local tunnels_b64="$MESH_TUNNELS_B64"
    local reverse_secret="${MESH_REVERSE_SECRET:-}"
    local min_unused="${MESH_MIN_UNUSED:-32}"
    local final_ip="${MESH_FINAL_IP:-127.0.0.1}"
    local final_port="${MESH_FINAL_PORT:-443}"
    local user_port="${MESH_USER_PORT:-443}"
    local reverse_port="${MESH_REVERSE_PORT:-443}"
    local mux_count="${MESH_MUX_COUNT:-9}"
    local use_haproxy="${MESH_USE_HAPROXY:-false}"
    local hc_sni="${MESH_HC_SNI:-}"

    if [[ -z "$role" || -z "$server_ip" || -z "$approach" || -z "$tunnels_b64" ]]; then
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

    mkdir -p "$BASE_DIR/configs"
    mkdir -p "$BASE_DIR/log"

    local count
    count="$(echo "$tunnels_json" | jq -r '. | length')"
    local i ai bj peer_ip
    local -a config_files=()

    echo "Setting up $count tunnel pair(s) on this $role server..."

    for ((i = 0; i < count; i++)); do
        ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
        bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
        peer_ip="$(echo "$tunnels_json" | jq -r ".[$i].peer_ip")"

        if [[ "$role" == "iran" ]]; then
            generate_tunnel_a_config "$ai" "$bj" "$server_ip" "$peer_ip" "$BASE_DIR/configs"
            config_files+=("configs/tunnel_a${ai}_b${bj}.json")
            echo "  Generated tunnel_a${ai}_b${bj}.json"
        else
            generate_tunnel_b_config "$ai" "$bj" "$peer_ip" "$server_ip" "$BASE_DIR/configs"
            config_files+=("configs/tunnel_b${bj}_a${ai}.json")
            echo "  Generated tunnel_b${bj}_a${ai}.json"
        fi
    done

    if [[ "$approach" == "reverse" ]]; then
        if [[ "$role" == "iran" ]]; then
            if [[ "$use_haproxy" == "true" ]]; then
                # HAProxy mode: generate one reverse server config per kharej
                local -a haproxy_servers=()
                for ((i = 0; i < count; i++)); do
                    ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
                    bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                    local tun_ip_a
                    tun_ip_a="$(mesh_tun_ip_a $ai $bj)"
                    local local_port=$((9000 + bj))

                    generate_reverse_server_config_single "$ai" "$bj" "$tun_ip_a" "$reverse_port" "$reverse_secret" "$local_port" "$BASE_DIR/configs"
                    config_files+=("configs/reverse_server_a${ai}_b${bj}.json")
                    echo "  Generated reverse_server_a${ai}_b${bj}.json (HAProxy local port $local_port)"
                    haproxy_servers+=("server ww_b${bj} 127.0.0.1:${local_port}")
                done

                # Generate and install HAProxy config
                generate_haproxy_config "$server_ip" "$hc_sni" "/etc/haproxy/haproxy.cfg" "${haproxy_servers[@]}"
                echo "  Generated HAProxy config with ${#haproxy_servers[@]} backend(s)"
                install_haproxy
            else
                # Standard mode: single reverse server config with all TUN IPs
                local -a tun_ips=()
                for ((i = 0; i < count; i++)); do
                    ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
                    bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                    tun_ips+=("$(mesh_tun_ip_a $ai $bj)")
                done

                local my_ai
                my_ai="$(echo "$tunnels_json" | jq -r ".[0].ai")"

                generate_reverse_server_config "$my_ai" "$server_ip" "$reverse_port" "$reverse_secret" "$user_port" "$BASE_DIR/configs" "${tun_ips[@]}"
                config_files+=("configs/reverse_server_a${my_ai}.json")
                echo "  Generated reverse_server_a${my_ai}.json"
            fi
        else
            # Generate reverse client config for each A server
            for ((i = 0; i < count; i++)); do
                ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
                bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                local tun_ip_a
                tun_ip_a="$(mesh_tun_ip_b $ai $bj)"

                generate_reverse_client_config "$bj" "$ai" "$tun_ip_a" "$reverse_port" "$final_ip" "$final_port" "$min_unused" "$reverse_secret" "$BASE_DIR/configs"
                config_files+=("configs/reverse_client_b${bj}_a${ai}.json")
                echo "  Generated reverse_client_b${bj}_a${ai}.json"
            done
        fi
    elif [[ "$approach" == "forward" ]]; then
        if [[ "$role" == "iran" ]]; then
            if [[ "$use_haproxy" == "true" ]]; then
                # HAProxy mode: generate one forward user config per kharej
                local -a haproxy_servers=()
                local my_ai
                my_ai="$(echo "$tunnels_json" | jq -r ".[0].ai")"
                for ((i = 0; i < count; i++)); do
                    bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                    local kharej_tun_ip
                    kharej_tun_ip="$(mesh_tun_ip_b $my_ai $bj)"
                    local local_port=$((9000 + bj))

                    generate_forward_user_config_single "$my_ai" "$bj" "$local_port" "$reverse_port" "$mux_count" "$kharej_tun_ip" "$BASE_DIR/configs"
                    config_files+=("configs/user_forward_a${my_ai}_b${bj}.json")
                    echo "  Generated user_forward_a${my_ai}_b${bj}.json (HAProxy local port $local_port)"
                    haproxy_servers+=("server ww_b${bj} 127.0.0.1:${local_port}")
                done

                # Generate and install HAProxy config
                generate_haproxy_config "$server_ip" "$hc_sni" "/etc/haproxy/haproxy.cfg" "${haproxy_servers[@]}"
                echo "  Generated HAProxy config with ${#haproxy_servers[@]} backend(s)"
                install_haproxy
            else
                # Standard mode: single forward user config with weighted TcpConnector
                local -a kharej_tun_ips=()
                for ((i = 0; i < count; i++)); do
                    ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
                    bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                    kharej_tun_ips+=("$(mesh_tun_ip_b $ai $bj)")
                done

                local my_ai
                my_ai="$(echo "$tunnels_json" | jq -r ".[0].ai")"

                generate_forward_user_config "$my_ai" "$user_port" "$reverse_port" "$mux_count" "$BASE_DIR/configs" "${kharej_tun_ips[@]}"
                config_files+=("configs/user_forward_a${my_ai}.json")
                echo "  Generated user_forward_a${my_ai}.json"
            fi
        else
            # Generate forward server config with all A TUN IPs
            local -a iran_tun_ips=()
            for ((i = 0; i < count; i++)); do
                ai="$(echo "$tunnels_json" | jq -r ".[$i].ai")"
                bj="$(echo "$tunnels_json" | jq -r ".[$i].bj")"
                iran_tun_ips+=("$(mesh_tun_ip_a $ai $bj)")
            done

            local my_bj
            my_bj="$(echo "$tunnels_json" | jq -r ".[0].bj")"

            generate_forward_server_config "$my_bj" "$reverse_port" "$final_ip" "$final_port" "$BASE_DIR/configs" "${iran_tun_ips[@]}"
            config_files+=("configs/server_forward_b${my_bj}.json")
            echo "  Generated server_forward_b${my_bj}.json"
        fi
    fi

    # Generate core.json with all config files
    generate_core_json "$mtu" "$BASE_DIR" "${config_files[@]}"
    echo "  Generated core.json with ${#config_files[@]} config(s)"

    # Install and start service
    install_mesh_service
    echo "Mesh service installed and started."

    # Run optimizations
    echo "Running server optimizations..."
    local distro
    distro="$(detect_distro)"
    sysctl_optimizations
    enable_bbr "$distro"
    limits_optimizations
    optimize_tunnel_interfaces
    install_tunnel_tune_service

    echo "Mesh deployment on $server_ip complete."
}

# ============================================================================
# MESH DEPLOY - INTERACTIVE (runs on control server)
# ============================================================================

function mesh_deploy() {
    clear
    echo
    echo "Full Mesh Network Deployment"
    echo "=============================="
    echo
    echo "This will create a full mesh of WaterWall tunnels."
    echo "Each Iran server connects to every Kharej server."
    echo "ONE WaterWall instance per server (all tunnels in one core.json)."
    echo
    echo "Server file format (space/tab-delimited, # for comments):"
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
    echo "Approach:"
    echo "  1) Reverse (recommended - faster failover, Kharej connects to Iran)"
    echo "  2) Forward (Iran connects to Kharej via weighted TcpConnector)"
    echo "  0) Back"
    echo
    local approach_choice approach
    read -rp "Choose [0-2]: " approach_choice || { pause_return_menu; return; }
    case "$approach_choice" in
        1) approach="reverse" ;;
        2) approach="forward" ;;
        0) return ;;
        *) echo "Invalid option."; pause_return_menu; return ;;
    esac

    local user_port reverse_port final_ip final_port min_unused reverse_secret mtu_val mux_count
    local use_haproxy="false" hc_sni=""

    user_port="$(ask_port "User-facing port on A servers" "443")"
    [[ -z "$user_port" ]] && return

    reverse_port="$(ask_port "Reverse/Mux port on TUN IPs" "443")"
    [[ -z "$reverse_port" ]] && return

    final_ip="$(ask_string "Final service IP on B servers" "127.0.0.1")"
    final_port="$(ask_port "Final service port on B servers (Xray/VLESS listen port)" "$user_port")"
    [[ -z "$final_port" ]] && return

    if [[ "$approach" == "reverse" ]]; then
        mux_count=9
        min_unused="$(ask_string "Minimum held reverse connections per worker" "32")"
        reverse_secret="$(ask_string "Reverse secret (shared across all servers)" "")"
        [[ -z "$reverse_secret" ]] && { echo "Reverse secret cannot be empty."; pause_return_menu; return; }
    else
        mux_count="$(ask_string "MuxClient connections per worker" "9")"
        min_unused=32
        reverse_secret="unused"
    fi

    mtu_val="$(ask_string "MTU value" "1400")"

    echo
    echo "Use HAProxy for load balancing on Iran? (deep TLS health check, auto failover)"
    local haproxy_choice
    read -rp "  [y/N]: " haproxy_choice || haproxy_choice=""
    if [[ "$haproxy_choice" =~ ^[Yy] ]]; then
        use_haproxy="true"
        echo "  Health-check SNI (for Xray REALITY strict-SNI; leave blank for plain TLS/Vision)"
        read -rp "  SNI [none]: " hc_sni || hc_sni=""
    fi

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
    echo "Mesh plan: $num_iran Iran × $num_kharej Kharej = $total_tunnels tunnel pair(s)"
    echo "Approach: $approach"
    echo "Ports: user=$user_port, reverse/mux=$reverse_port, final=$final_ip:$final_port"
    if [[ "$use_haproxy" == "true" ]]; then
        echo "HAProxy: enabled (deep TLS health check, auto failover)"
    fi
    echo

    printf "%-8s %-10s %-12s %-14s %-14s\n" "Pair#" "Iran" "Kharej" "A TUN IP" "B TUN IP"
    printf "%-8s %-10s %-12s %-14s %-14s\n" "-----" "----" "------" "--------" "--------"

    local iran_i kharej_j ai bj iran_idx kharej_idx
    for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
        for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
            ai=$((iran_i + 1))
            bj=$((kharej_j + 1))
            iran_idx="${iran_indices[$iran_i]}"
            kharej_idx="${kharej_indices[$kharej_j]}"
            printf "%-8s %-10s %-12s %-14s %-14s\n" \
                "A${ai}B${bj}" "${mesh_names[$iran_idx]}" "${mesh_names[$kharej_idx]}" \
                "$(mesh_tun_ip_a $ai $bj)" "$(mesh_tun_ip_b $ai $bj)"
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

    local s_idx s_name s_ip s_user s_pass s_role
    local tunnels_json b64
    local ssh_status
    local iran_i_pos kharej_j_pos ii jj
    local peer_ip ai bj

    for ((s_idx = 0; s_idx < ${#mesh_names[@]}; s_idx++)); do
        s_name="${mesh_names[$s_idx]}"
        s_ip="${mesh_ips[$s_idx]}"
        s_user="${mesh_users[$s_idx]}"
        s_pass="${mesh_passes[$s_idx]}"
        s_role="${mesh_roles[$s_idx]}"

        echo "========================================"
        echo "Deploying to: $s_name ($s_ip) [$s_role]"
        echo "========================================"

        tunnels_json="[]"

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
            ai=$((iran_i_pos + 1))
            for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
                kharej_idx="${kharej_indices[$kharej_j]}"
                peer_ip="${mesh_ips[$kharej_idx]}"
                bj=$((kharej_j + 1))

                tunnels_json="$(echo "$tunnels_json" | jq --argjson ai "$ai" --argjson bj "$bj" --arg peer "$peer_ip" \
                    '. + [{"ai": $ai, "bj": $bj, "peer_ip": $peer}]')"
            done
        else
            bj=$((kharej_j_pos + 1))
            for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
                iran_idx="${iran_indices[$iran_i]}"
                peer_ip="${mesh_ips[$iran_idx]}"
                ai=$((iran_i + 1))

                tunnels_json="$(echo "$tunnels_json" | jq --argjson ai "$ai" --argjson bj "$bj" --arg peer "$peer_ip" \
                    '. + [{"ai": $ai, "bj": $bj, "peer_ip": $peer}]')"
            done
        fi

        b64="$(echo "$tunnels_json" | base64 -w0)"

        echo "  Copying script to $s_ip..."
        if ! sshpass -p "$s_pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$0" "${s_user}@${s_ip}:/root/fullmesh.sh" >/dev/null 2>&1; then
            echo "  ERROR: Failed to copy script to $s_name ($s_ip). Skipping."
            continue
        fi

        echo "  Running mesh deployment on $s_ip..."
        local env_vars="MESH_ROLE=$s_role MESH_SERVER_IP=$s_ip MESH_APPROACH=$approach MESH_MTU=$mtu_val MESH_TUNNELS_B64=$b64 MESH_MIN_UNUSED=$min_unused MESH_FINAL_IP=$final_ip MESH_FINAL_PORT=$final_port MESH_USER_PORT=$user_port MESH_REVERSE_PORT=$reverse_port MESH_MUX_COUNT=$mux_count MESH_USE_HAPROXY=$use_haproxy MESH_HC_SNI=$hc_sni"
        if [[ "$approach" == "reverse" ]]; then
            env_vars="$env_vars MESH_REVERSE_SECRET=$reverse_secret"
        fi
        sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${s_user}@${s_ip}" \
            "$env_vars bash /root/fullmesh.sh --mesh-deploy" \
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
    echo "Full mesh deployment complete!"
    echo "========================================"
    echo
    echo "Summary:"
    echo "  $num_iran Iran × $num_kharej Kharej = $total_tunnels tunnel pair(s)"
    echo "  Approach: $approach"
    echo "  One waterwall-mesh service per server"
    echo "  Ports: user=$user_port, reverse/mux=$reverse_port, final=$final_ip:$final_port"
    if [[ "$use_haproxy" == "true" ]]; then
        echo "  HAProxy: enabled (deep TLS health check, auto failover)"
    fi
    echo
    echo "Log files saved as mesh-*.log in current directory."
    pause_return_menu
}

# ============================================================================
# MESH STATUS
# ============================================================================

function mesh_status() {
    clear
    echo
    echo "Mesh Status"
    echo "============="
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }
    [[ ! -f "$file_path" ]] && { echo "File not found: $file_path"; pause_return_menu; return; }

    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        log "Installing sshpass..."
        wait_for_apt
        apt-get install -y -qq sshpass >/dev/null 2>&1
    fi

    local s_idx s_name s_ip s_user s_pass
    for ((s_idx = 0; s_idx < ${#mesh_names[@]}; s_idx++)); do
        s_name="${mesh_names[$s_idx]}"
        s_ip="${mesh_ips[$s_idx]}"
        s_user="${mesh_users[$s_idx]}"
        s_pass="${mesh_passes[$s_idx]}"

        echo "========================================"
        echo "$s_name ($s_ip) [${mesh_roles[$s_idx]}]"
        echo "========================================"

        sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${s_user}@${s_ip}" \
            "systemctl is-active waterwall-mesh.service 2>/dev/null && echo 'Service: ACTIVE' || echo 'Service: INACTIVE/NOT INSTALLED'; \
             systemctl is-enabled waterwall-mesh.service 2>/dev/null || true; \
             echo '--- TUN devices ---'; \
             ip link show 2>/dev/null | grep -oP 'tun[A-Za-z0-9]+' | sort -u || echo 'No TUN devices'; \
             echo '--- Recent log ---'; \
             tail -5 /root/waterwall/log/core.log 2>/dev/null || echo 'No log file'" 2>&1
        echo
    done

    pause_return_menu
}

# ============================================================================
# MESH RESTART
# ============================================================================

function mesh_restart() {
    clear
    echo
    echo "Restart Mesh Service"
    echo "======================"
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }
    [[ ! -f "$file_path" ]] && { echo "File not found: $file_path"; pause_return_menu; return; }

    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq sshpass >/dev/null 2>&1
    fi

    echo "Restart waterwall-mesh on:"
    echo "  a) All servers"
    echo "  b) Specific server"
    echo "  0) Back"
    local choice
    read -rp "Choose [a/b/0]: " choice

    case "$choice" in
        a)
            local s_idx
            for ((s_idx = 0; s_idx < ${#mesh_names[@]}; s_idx++)); do
                echo "Restarting ${mesh_names[$s_idx]} (${mesh_ips[$s_idx]})..."
                sshpass -p "${mesh_passes[$s_idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                    "${mesh_users[$s_idx]}@${mesh_ips[$s_idx]}" \
                    "systemctl restart waterwall-mesh.service" 2>&1
                echo "  Done."
            done
            ;;
        b)
            echo
            local i
            for ((i = 0; i < ${#mesh_names[@]}; i++)); do
                echo "  $((i+1))) ${mesh_names[$i]} (${mesh_ips[$i]})"
            done
            local sel
            read -rp "Select server [1-${#mesh_names[@]}]: " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#mesh_names[@]} )); then
                local idx=$((sel - 1))
                echo "Restarting ${mesh_names[$idx]}..."
                sshpass -p "${mesh_passes[$idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                    "${mesh_users[$idx]}@${mesh_ips[$idx]}" \
                    "systemctl restart waterwall-mesh.service" 2>&1
                echo "  Done."
            else
                echo "Invalid selection."
            fi
            ;;
        *) return ;;
    esac

    pause_return_menu
}

# ============================================================================
# MESH TEST
# ============================================================================

function mesh_test() {
    clear
    echo
    echo "Test Mesh Connectivity"
    echo "========================"
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }
    [[ ! -f "$file_path" ]] && { echo "File not found: $file_path"; pause_return_menu; return; }

    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq sshpass >/dev/null 2>&1
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

    echo
    echo "Testing TUN connectivity from each Iran to each Kharej..."
    echo

    printf "%-10s %-10s %-14s %-8s\n" "Iran" "Kharej" "TUN IP" "Status"
    printf "%-10s %-10s %-14s %-8s\n" "----" "------" "-------" "------"

    local iran_i kharej_j ai bj iran_idx kharej_idx tun_ip_b result
    for ((iran_i = 0; iran_i < num_iran; iran_i++)); do
        for ((kharej_j = 0; kharej_j < num_kharej; kharej_j++)); do
            ai=$((iran_i + 1))
            bj=$((kharej_j + 1))
            iran_idx="${iran_indices[$iran_i]}"
            kharej_idx="${kharej_indices[$kharej_j]}"
            tun_ip_b="$(mesh_tun_ip_b $ai $bj)"

            result="$(sshpass -p "${mesh_passes[$iran_idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                "${mesh_users[$iran_idx]}@${mesh_ips[$iran_idx]}" \
                "ping -c 3 -W 2 $tun_ip_b >/dev/null 2>&1 && echo UP || echo DOWN" 2>/dev/null)"

            printf "%-10s %-10s %-14s %-8s\n" \
                "${mesh_names[$iran_idx]}" "${mesh_names[$kharej_idx]}" "$tun_ip_b" "${result:-TIMEOUT}"
        done
    done

    echo
    pause_return_menu
}

# ============================================================================
# MESH UNINSTALL
# ============================================================================

function mesh_uninstall() {
    clear
    echo
    echo "Uninstall Mesh"
    echo "==============="
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }
    [[ ! -f "$file_path" ]] && { echo "File not found: $file_path"; pause_return_menu; return; }

    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq sshpass >/dev/null 2>&1
    fi

    echo
    echo "Uninstall mesh from:"
    echo "  a) All servers"
    echo "  b) Specific server"
    echo "  0) Back"
    local choice
    read -rp "Choose [a/b/0]: " choice

    local targets=()
    case "$choice" in
        a)
            local i
            for ((i = 0; i < ${#mesh_names[@]}; i++)); do
                targets+=("$i")
            done
            ;;
        b)
            echo
            local i
            for ((i = 0; i < ${#mesh_names[@]}; i++)); do
                echo "  $((i+1))) ${mesh_names[$i]} (${mesh_ips[$i]})"
            done
            local sel
            read -rp "Select server [1-${#mesh_names[@]}]: " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#mesh_names[@]} )); then
                targets+=("$((sel - 1))")
            else
                echo "Invalid selection."
                pause_return_menu
                return
            fi
            ;;
        *) return ;;
    esac

    local del_bin
    read -rp "Also delete WaterWall binary on target servers? (y/N): " del_bin
    del_bin="$(echo "$del_bin" | tr '[:upper:]' '[:lower:]')"

    local idx
    for idx in "${targets[@]}"; do
        echo "Uninstalling ${mesh_names[$idx]} (${mesh_ips[$idx]})..."
        local cmd="systemctl stop waterwall-mesh.service 2>/dev/null || true; \
                   systemctl disable waterwall-mesh.service 2>/dev/null || true; \
                   systemctl stop waterwall-tune.service 2>/dev/null || true; \
                   systemctl disable waterwall-tune.service 2>/dev/null || true; \
                   pkill -x Waterwall 2>/dev/null || true; \
                   rm -f /etc/systemd/system/waterwall-mesh.service; \
                   rm -f /etc/systemd/system/waterwall-tune.service; \
                   systemctl daemon-reload; \
                   rm -rf $BASE_DIR/configs $BASE_DIR/core.json $BASE_DIR/log; \
                   echo '  Mesh configs removed.'"
        if [[ "$del_bin" == "y" || "$del_bin" == "yes" ]]; then
            cmd="$cmd; rm -rf $BASE_DIR; echo '  WaterWall binary and all files removed.'"
        fi
        sshpass -p "${mesh_passes[$idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${mesh_users[$idx]}@${mesh_ips[$idx]}" "$cmd" 2>&1 || true
    done

    log "Uninstall complete."
    pause_return_menu
}

# ============================================================================
# MESH UPDATE CORE
# ============================================================================

function mesh_update_core() {
    clear
    echo
    echo "Update WaterWall Core on All Mesh Servers"
    echo "=========================================="
    echo

    local file_path
    read -rp "Enter server file path: " file_path || { pause_return_menu; return; }
    [[ -z "$file_path" ]] && { echo "No file specified."; pause_return_menu; return; }
    [[ ! -f "$file_path" ]] && { echo "File not found: $file_path"; pause_return_menu; return; }

    if ! mesh_parse_file "$file_path"; then
        pause_return_menu
        return
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq sshpass >/dev/null 2>&1
    fi

    local s_idx
    for ((s_idx = 0; s_idx < ${#mesh_names[@]}; s_idx++)); do
        echo "Updating ${mesh_names[$s_idx]} (${mesh_ips[$s_idx]})..."
        local remote_arch
        remote_arch="$(sshpass -p "${mesh_passes[$s_idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${mesh_users[$s_idx]}@${mesh_ips[$s_idx]}" 'uname -m' 2>/dev/null)"
        local asset_pattern
        case "$remote_arch" in
            x86_64|amd64)  asset_pattern="Waterwall-linux-gcc-x64.zip" ;;
            aarch64|arm64) asset_pattern="Waterwall-linux-gcc-arm64.zip" ;;
            *)             asset_pattern="Waterwall-linux-gcc-x64.zip" ;;
        esac
        sshpass -p "${mesh_passes[$s_idx]}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${mesh_users[$s_idx]}@${mesh_ips[$s_idx]}" \
            "systemctl stop waterwall-mesh.service 2>/dev/null || true; \
             rm -f $BASE_DIR/Waterwall; \
             cd /tmp && curl -sL \"https://api.github.com/repos/$GITHUB_REPO/releases\" | \
             grep -o '\"browser_download_url\": \"[^\"]*${asset_pattern}\"' | head -1 | cut -d'\"' -f4 | \
             xargs curl -fsSL -o /tmp/ww.zip && unzip -o /tmp/ww.zip -d $BASE_DIR && rm -f /tmp/ww.zip && \
             chmod +x $BASE_DIR/Waterwall && \
             systemctl restart waterwall-mesh.service && \
             echo '  Updated and restarted.'" 2>&1
    done

    log "Core update complete."
    pause_return_menu
}

# ============================================================================
# SERVER OPTIMIZATION
# ============================================================================

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
    log "Backing up /etc/sysctl.conf..."
    cp -f /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true
    log "Applying sysctl optimizations..."
    cat > /etc/sysctl.conf <<'SYSEOF'
fs.file-max = 67108864
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
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 250
vm.min_free_kbytes = 65536
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
SYSEOF
    sysctl -p >/dev/null 2>&1 || true
    log "sysctl parameters applied."
}

function limits_optimizations() {
    log "Applying system limits..."
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
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        log "BBR module set to load on boot."
    fi
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log "BBR is active."
    else
        log "BBR may require a reboot to take effect."
    fi
}

function optimize_tunnel_interfaces() {
    log "Optimizing tunnel interfaces..."
    if ! command -v ethtool >/dev/null 2>&1; then
        wait_for_apt
        apt-get install -y -qq ethtool >/dev/null 2>&1 || true
    fi
    local iface
    for iface in $(ip link show 2>/dev/null | grep -oP 'tun[A-Za-z0-9]+' | sort -u); do
        if ip link show "$iface" >/dev/null 2>&1; then
            ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true
            ip link set "$iface" txqueuelen 10000 2>/dev/null || true
            log "  $iface: offload disabled, txqueuelen=10000"
        fi
    done
    local phys_iface
    phys_iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)"
    if [[ -n "$phys_iface" ]]; then
        ip link set "$phys_iface" txqueuelen 10000 2>/dev/null || true
        log "  $phys_iface: txqueuelen=10000"
    fi
}

function install_tunnel_tune_service() {
    log "Creating tunnel-tune service..."
    cat > /etc/systemd/system/waterwall-tune.service <<TUNESVC
[Unit]
Description=Waterwall Tunnel Interface Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/bin/bash -c 'for iface in \$(ip link show 2>/dev/null | grep -oP "tun[A-Za-z0-9]+" | sort -u); do ethtool -K "\$iface" gro off gso off tso off 2>/dev/null || true; ip link set "\$iface" txqueuelen 10000 2>/dev/null || true; done; PHYS=\$(ip route show default | awk "/default/ {print \\\$5}" | head -n1); [ -n "\$PHYS" ] && ip link set "\$PHYS" txqueuelen 10000 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
TUNESVC
    systemctl daemon-reload
    systemctl enable waterwall-tune.service >/dev/null 2>&1
    log "waterwall-tune.service enabled."
}

function optimize_server() {
    echo
    echo "Server Optimization"
    echo "====================="
    local distro
    distro="$(detect_distro)"
    case "$distro" in
        ubuntu|debian) log "Detected OS: $distro" ;;
        *)
            echo "This optimization supports Ubuntu and Debian only."
            pause_return_menu
            return
            ;;
    esac

    echo "This will apply: kernel/TCP tuning, BBR, ulimits, conntrack, interface tuning."
    local ans
    read -rp "Continue? (y/N): " ans
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
        echo "Cancelled."
        pause_return_menu
        return
    fi

    modprobe nf_conntrack 2>/dev/null || true
    if ! grep -q "nf_conntrack" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "nf_conntrack" >> /etc/modules-load.d/bbr.conf
    fi

    sysctl_optimizations
    limits_optimizations
    enable_bbr "$distro"
    optimize_tunnel_interfaces
    install_tunnel_tune_service
    echo "$OPTIMIZE_VERSION" > "$OPTIMIZE_MARKER"

    echo
    echo "========================================="
    echo " Optimization v${OPTIMIZE_VERSION} applied!"
    echo "========================================="
    echo "A reboot is recommended for full effect."
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

# ============================================================================
# BANNER & MAIN MENU
# ============================================================================

function banner() {
    clear
    echo -e "\e[36m"
    echo "=================================================="
    echo "     W A T E R W A L L   F U L L   M E S H"
    echo "=================================================="
    echo -e "\e[0m"
    local server_ip
    server_ip=$(get_public_ip)
    [[ -z "$server_ip" ]] && server_ip="Unknown"

    local local_ver
    local_ver="$(get_local_version)"

    if [[ -n "$local_ver" ]]; then
        echo "  Server IP: $server_ip"
        echo "  WaterWall: v$local_ver"
    else
        echo "  Server IP: $server_ip"
        echo "  WaterWall: Not installed"
    fi

    if systemctl is-active waterwall-mesh.service >/dev/null 2>&1; then
        echo -e "  Mesh Service: \e[32mACTIVE\e[0m"
    else
        echo -e "  Mesh Service: \e[37mNot running\e[0m"
    fi
    echo "=================================================="
    echo
}

function main_menu() {
    install_prerequisites
    while true; do
        banner
        echo "Full Mesh Setup"
        echo "=================="
        echo "1) Deploy Full Mesh"
        echo "2) Mesh Status"
        echo "3) Restart Mesh Service"
        echo "4) Test Mesh Connectivity"
        echo "5) Update WaterWall Core"
        echo "6) Uninstall Mesh"
        echo "7) Optimize Server"
        echo "0) Exit"
        echo
        local choice
        read -rp "Choose an option [0-7]: " choice || exit 0
        case "$choice" in
            1) mesh_deploy ;;
            2) mesh_status ;;
            3) mesh_restart ;;
            4) mesh_test ;;
            5) mesh_update_core ;;
            6) mesh_uninstall ;;
            7) optimize_server ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Invalid option."; pause_return_menu ;;
        esac
    done
}

# ============================================================================
# ENTRY POINT
# ============================================================================

if [[ "${1:-}" == "--mesh-deploy" ]]; then
    mesh_deploy_remote
    exit 0
fi
main_menu
