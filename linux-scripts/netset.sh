#!/usr/bin/env bash
# netset - 管理 Debian/Ubuntu ifupdown 网络配置

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

PROGRAM_NAME="netset"
INSTALL_PATH="/usr/local/bin/netset"
DEFAULT_CIDR="24"
INTERFACES_FILE="/etc/network/interfaces"
INTERFACES_DIR="/etc/network/interfaces.d"
DEFAULT_CONFIG="/etc/network/interfaces.d/99-netset"
BACKUP_DIR="/etc/network/netset-backup"
LOCK_FILE="/run/lock/netset.lock"
RESOLV_CONF="/etc/resolv.conf"
TEMPORARY_FILE=""
LAST_BACKUP_FILE=""
INCLUDE_CHANGED=0
INCLUDE_BACKUP_FILE=""
CONFIG_CHANGED=0

cleanup() {
    if [[ -n "${TEMPORARY_FILE:-}" ]]; then
        rm -f -- "$TEMPORARY_FILE" || true
    fi
}

trap cleanup EXIT

show_short_help() {
    cat <<'EOF'
netset - ifupdown 网络配置工具

常用命令：
  netset install
  netset show
  netset static <IP[/CIDR]> [Gateway [DNS...]]
  netset dhcp

运行 netset help 查看完整帮助。
EOF
}

show_help() {
    cat <<'EOF'
用法：
  netset install
  netset show
  netset status
  netset static <IP[/CIDR]> [Gateway [DNS...]]
  netset dhcp
  netset help

命令：
  install
      将当前脚本安装到 /usr/local/bin/netset。

  show / status
      显示主要网卡、IPv4 地址、默认网关、DNS 和配置文件。

  static <IP[/CIDR]> [Gateway [DNS...]]
      设置静态 IPv4 地址、默认网关和 DNS。

      IP 未指定 CIDR 时，默认使用 /24。
      Gateway 未指定时，保留当前网关。
      DNS 未指定时，保留当前网卡正在使用的 DNS。
      可以指定一个或多个 DNS 地址。

  dhcp
      将 IPv4 地址、默认网关和 DNS 改为 DHCP 自动获取。

  help
      显示此帮助。

示例：
  sudo bash netset.sh install

  netset show

  netset static 192.0.2.62

  netset static 192.0.2.62 192.0.2.1

  netset static 192.0.2.62/24 192.0.2.1 \
      192.0.2.53 198.51.100.53

  netset dhcp

  以上 IP 地址属于文档示例网段，使用时必须替换为实际网络参数。

适用环境：
  · Debian、Ubuntu 等使用 ifupdown 管理网络的系统。
  · 网卡配置位于 /etc/network/interfaces 或其 source 包含文件中。
  · 使用 ifup 和 ifdown 启停网卡。
  · 适合 PVE 中普通的单网卡 Debian 虚拟机。
  · 自动选择当前默认路由所使用的网卡。

不适用：
  · NetworkManager 管理的网卡，例如使用 nmcli 或 nmtui 的系统。
  · systemd-networkd 管理的网卡。
  · Netplan 管理的系统。
  · PVE 宿主机本身。
  · 网桥、Bond、VLAN、多默认路由或复杂多网卡配置。

文件：
  /usr/local/bin/netset
      install 命令安装的脚本。

  /etc/network/interfaces
      ifupdown 主配置文件。
      必要时会加入 source /etc/network/interfaces.d/*。

  /etc/network/interfaces.d/99-netset
      找不到目标网卡的现有 IPv4 配置时，默认创建此文件。

  /etc/resolv.conf
      未使用 systemd-resolved 或 resolvconf 时，直接同步静态 DNS。

  /etc/network/netset-backup/
      修改前保存网络和 DNS 配置文件备份。

  /run/lock/netset.lock
      防止多个 netset 配置命令同时运行。

注意：
  · 执行 static 或 dhcp 后会重新启动网卡。
  · 需要 root 的命令会自动通过 sudo 重新执行。
  · 通过 SSH 执行时，连接可能立即中断。
  · 修改前会备份原配置文件。
  · static 模式会将 DNS 同步到当前系统实际使用的解析器。
EOF
}

die() {
    echo "错误：$*" >&2
    exit 1
}

warn() {
    echo "警告：$*" >&2
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        command_exists sudo ||
            die "此操作需要 root 权限，但系统中未安装 sudo。"

        local script_path
        script_path="$(readlink -f -- "$0")" ||
            die "无法确定当前脚本路径：$0"

        exec sudo -- /bin/bash "$script_path" "$@"
    fi
}

command_exists() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        [[ -x "/usr/sbin/$command_name" ]] ||
        [[ -x "/sbin/$command_name" ]]
}

path_is_root_owned_and_not_writable() {
    local path="$1"
    local owner_uid
    local mode
    local mode_value

    owner_uid="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    mode_value=$((8#$mode))

    [[ "$owner_uid" == "0" ]] && (( (mode_value & 0022) == 0 ))
}

acquire_lock() {
    command_exists flock ||
        die "缺少 flock 命令，请安装 util-linux。"

    mkdir -p -- "$(dirname -- "$LOCK_FILE")"
    exec 9>>"$LOCK_FILE"
    flock -x 9
}

command_install() {
    local source_path
    source_path="$(readlink -f -- "$0")" ||
        die "无法确定当前脚本路径：$0"

    if [[ "$source_path" == "$INSTALL_PATH" ]]; then
        chmod 755 -- "$INSTALL_PATH"
        echo "$PROGRAM_NAME 已经安装在：$INSTALL_PATH"
        return
    fi

    install -m 755 -- "$source_path" "$INSTALL_PATH"

    echo "安装完成：$INSTALL_PATH"
    echo
    echo "可以运行："
    echo "  netset show"
}

detect_interface() {
    local iface=""
    local -a candidates=()

    # 优先选择当前默认 IPv4 路由使用的网卡。
    iface="$(
        ip -4 route show default 2>/dev/null |
        awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && (i + 1) <= NF) {
                        print $(i + 1)
                        exit
                    }
                }
            }
        '
    )"

    # 没有默认路由时，选择第一张非 lo 且已启用的网卡。
    if [[ -z "$iface" ]]; then
        mapfile -t candidates < <(
            ip -o link show up 2>/dev/null |
            awk -F': ' '$2 != "lo" {
                split($2, parts, "@")
                print parts[1]
            }'
        )

        if (( ${#candidates[@]} == 1 )); then
            iface="${candidates[0]}"
        elif (( ${#candidates[@]} > 1 )); then
            printf '没有默认路由，发现多个已启用网卡：\n' >&2
            printf '  %s\n' "${candidates[@]}" >&2
            die "无法安全地自动选择网卡。"
        fi
    fi

    [[ -n "$iface" ]] || die "无法自动识别主要网卡。"
    [[ "$iface" != "lo" ]] || die "不能修改回环接口 lo。"
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
        die "检测到不受支持的网卡名称：$iface"
    ip link show dev "$iface" >/dev/null 2>&1 ||
        die "网卡不存在：$iface"

    printf '%s\n' "$iface"
}

get_current_gateway() {
    local iface="$1"

    ip -4 route show default 2>/dev/null |
        awk -v iface="$iface" '
            {
                route_iface = ""
                gateway = ""

                for (i = 1; i <= NF; i++) {
                    if ($i == "via" && (i + 1) <= NF) {
                        gateway = $(i + 1)
                    } else if ($i == "dev" && (i + 1) <= NF) {
                        route_iface = $(i + 1)
                    }
                }

                if (route_iface == iface && gateway != "") {
                    print gateway
                    exit
                }
            }
        '
}

validate_ipv4() {
    local address="$1"
    local part
    local -a octets

    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a octets <<<"$address"

    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        [[ "$part" == "0" || "$part" != 0* ]] || return 1

        # 避免 08、09 被 Bash 当作八进制处理。
        ((10#$part >= 0 && 10#$part <= 255)) || return 1
    done
}

validate_cidr() {
    local cidr="$1"

    [[ "$cidr" =~ ^[0-9]{1,2}$ ]] || return 1
    [[ "$cidr" == "0" || "$cidr" != 0* ]] || return 1
    ((10#$cidr >= 0 && 10#$cidr <= 32))
}

normalize_address() {
    local input="$1"
    local ip
    local cidr

    if [[ "$input" == */* ]]; then
        ip="${input%/*}"
        cidr="${input##*/}"
    else
        ip="$input"
        cidr="$DEFAULT_CIDR"
    fi

    validate_ipv4 "$ip" ||
        die "无效的 IPv4 地址：$ip"

    validate_cidr "$cidr" ||
        die "无效的 CIDR：$cidr"

    printf '%s/%s\n' "$ip" "$cidr"
}

check_environment() {
    [[ -f "$INTERFACES_FILE" && ! -L "$INTERFACES_FILE" ]] ||
        die "未找到普通配置文件 $INTERFACES_FILE，系统可能未使用 ifupdown。"

    path_is_root_owned_and_not_writable "$INTERFACES_FILE" ||
        die "$INTERFACES_FILE 必须属于 root，且不能允许组或其他用户写入。"

    command_exists ip ||
        die "未找到 ip 命令，请安装 iproute2。"

    command_exists ifup ||
        die "未找到 ifup，系统可能未安装或未使用 ifupdown。"

    command_exists ifdown ||
        die "未找到 ifdown，系统可能未安装或未使用 ifupdown。"

    command_exists ifquery ||
        die "未找到 ifquery，无法在应用前检查网络配置。"

    if command_exists systemctl &&
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        die "检测到 NetworkManager 正在运行，不应使用此脚本修改网卡。"
    fi

    if command_exists systemctl &&
       systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        die "检测到 systemd-networkd 正在运行，不应使用此脚本修改网卡。"
    fi

    if [[ -d /etc/netplan ]] &&
       find /etc/netplan -maxdepth 1 -name '*.yaml' -print -quit 2>/dev/null |
       grep -q .; then
        die "检测到 Netplan 配置，不应使用此脚本。"
    fi

    [[ ! -d /etc/pve ]] ||
        die "检测到 PVE 宿主机环境，不应使用此脚本修改网络。"
}

check_interface_complexity() {
    local iface="$1"

    [[ ! -d "/sys/class/net/$iface/bridge" ]] ||
        die "目标网卡是 Linux 网桥，不支持自动修改：$iface"
    [[ ! -f "/proc/net/bonding/$iface" ]] ||
        die "目标网卡是 Bond，不支持自动修改：$iface"
    [[ ! -f "/proc/net/vlan/$iface" ]] ||
        die "目标网卡是 VLAN，不支持自动修改：$iface"
}

list_interface_files() {
    local main_file="$INTERFACES_FILE"
    local line
    local pattern
    local file

    printf '%s\n' "$main_file"

    while IFS= read -r line; do
        # 去掉行尾注释。
        line="${line%%#*}"

        if [[ "$line" =~ ^[[:space:]]*source-directory[[:space:]]+(.+)$ ]]; then
            pattern="${BASH_REMATCH[1]}"
            pattern="${pattern%"${pattern##*[![:space:]]}"}"

            if [[ -d "$pattern" ]]; then
                find "$pattern" -maxdepth 1 -type f -print 2>/dev/null
            fi

        elif [[ "$line" =~ ^[[:space:]]*source[[:space:]]+(.+)$ ]]; then
            pattern="${BASH_REMATCH[1]}"
            pattern="${pattern%"${pattern##*[![:space:]]}"}"

            # source 可以包含通配符。
            while IFS= read -r file; do
                [[ -f "$file" ]] && printf '%s\n' "$file"
            done < <(compgen -G "$pattern" || true)
        fi
    done < "$main_file"
}

validate_interface_files_security() {
    local file

    while IFS= read -r file; do
        [[ -f "$file" && ! -L "$file" ]] ||
            die "网络配置必须是普通文件且不能是符号链接：$file"
        path_is_root_owned_and_not_writable "$file" ||
            die "网络配置必须属于 root，且不能允许组或其他用户写入：$file"
    done < <(list_interface_files | awk '!seen[$0]++')
}

find_interface_config() {
    local iface="$1"
    local file
    local -a matches=()

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue

        if awk -v iface="$iface" '
            $1 == "iface" && $2 == iface && $3 == "inet" {
                found = 1
            }
            END {
                exit found ? 0 : 1
            }
        ' "$file"; then
            matches+=("$file")
        fi
    done < <(list_interface_files | awk '!seen[$0]++')

    if (( ${#matches[@]} > 1 )); then
        printf '发现多个 IPv4 配置文件：\n' >&2
        printf '  %s\n' "${matches[@]}" >&2
        die "同一网卡存在重复配置，请先手动清理。"
    fi

    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
    else
        printf '%s\n' "$DEFAULT_CONFIG"
    fi
}

ensure_include_directory() {
    local target_file="$1"

    INCLUDE_CHANGED=0
    INCLUDE_BACKUP_FILE=""

    [[ "$target_file" == "$INTERFACES_DIR/"* ]] || return 0

    if [[ -e "$INTERFACES_DIR" || -L "$INTERFACES_DIR" ]]; then
        [[ -d "$INTERFACES_DIR" && ! -L "$INTERFACES_DIR" ]] ||
            die "$INTERFACES_DIR 必须是普通目录且不能是符号链接。"
        path_is_root_owned_and_not_writable "$INTERFACES_DIR" ||
            die "$INTERFACES_DIR 必须属于 root，且不能允许组或其他用户写入。"
    else
        install -d -m 755 -o root -g root -- "$INTERFACES_DIR"
    fi

    if grep -Eq \
        '^[[:space:]]*(source-directory[[:space:]]+/etc/network/interfaces\.d|source[[:space:]]+/etc/network/interfaces\.d/\*)' \
        "$INTERFACES_FILE"; then
        return 0
    fi

    backup_file "$INTERFACES_FILE"
    INCLUDE_BACKUP_FILE="$LAST_BACKUP_FILE"

    TEMPORARY_FILE="$(mktemp "$INTERFACES_FILE.netset.XXXXXX")" ||
        die "无法创建临时网络配置文件。"

    cp -- "$INTERFACES_FILE" "$TEMPORARY_FILE"
    cat >>"$TEMPORARY_FILE" <<'EOF'

# Load additional interface definitions.
source /etc/network/interfaces.d/*
EOF

    chmod --reference="$INTERFACES_FILE" -- "$TEMPORARY_FILE"
    chown --reference="$INTERFACES_FILE" -- "$TEMPORARY_FILE"
    mv -f -- "$TEMPORARY_FILE" "$INTERFACES_FILE"
    TEMPORARY_FILE=""
    INCLUDE_CHANGED=1
}

backup_file() {
    local file="$1"
    local timestamp
    local backup_name

    LAST_BACKUP_FILE=""
    timestamp="$(date '+%Y%m%d-%H%M%S').$$"
    install -d -m 700 -o root -g root -- "$BACKUP_DIR"

    if [[ -f "$file" ]]; then
        [[ ! -L "$file" ]] ||
            die "拒绝备份符号链接：$file"

        backup_name="${file#/}"
        backup_name="${backup_name//\//_}"
        LAST_BACKUP_FILE="$BACKUP_DIR/${backup_name}.${timestamp}.bak"

        cp -a -- "$file" "$LAST_BACKUP_FILE"

        echo "已备份：$LAST_BACKUP_FILE"
    fi
}

has_auto_declaration() {
    local file="$1"
    local iface="$2"

    [[ -f "$file" ]] || return 1

    awk -v iface="$iface" '
        /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+/ {
            for (i = 2; i <= NF; i++) {
                if ($i == iface) {
                    found = 1
                }
            }
        }
        END {
            exit found ? 0 : 1
        }
    ' "$file"
}

replace_ipv4_stanza() {
    local file="$1"
    local iface="$2"
    local stanza="$3"
    local directory
    local input_file="$file"
    local add_auto=0

    CONFIG_CHANGED=0
    directory="$(dirname -- "$file")"

    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" && ! -L "$file" ]] ||
            die "目标配置必须是普通文件且不能是符号链接：$file"
        path_is_root_owned_and_not_writable "$file" ||
            die "目标配置必须属于 root，且不能允许组或其他用户写入：$file"
    else
        input_file="/dev/null"
    fi

    if ! has_auto_declaration "$file" "$iface"; then
        add_auto=1
    fi

    TEMPORARY_FILE="$(mktemp "$directory/.netset.XXXXXX")" ||
        die "无法在 $directory 中创建临时配置文件。"

    awk \
        -v iface="$iface" \
        -v replacement="$stanza" \
        -v add_auto="$add_auto" '
        BEGIN {
            skipping = 0
            replaced = 0
        }

        {
            if (!skipping &&
                $1 == "iface" && $2 == iface && $3 == "inet") {

                if (!replaced) {
                    if (add_auto) {
                        print "auto " iface
                    }

                    print replacement
                    replaced = 1
                }

                skipping = 1
                next
            }

            if (skipping) {
                # 空行和缩进行属于当前 iface 段，直接跳过。
                if ($0 ~ /^[[:space:]]*$/ ||
                    $0 ~ /^[[:space:]]+/ ||
                    $0 ~ /^[[:space:]]*#/) {
                    next
                }

                # 遇到下一个顶层指令，当前 iface 段结束。
                skipping = 0
            }

            print
        }

        END {
            if (!replaced) {
                if (NR > 0) {
                    print ""
                }

                if (add_auto) {
                    print "auto " iface
                }

                print replacement
            }
        }
    ' "$input_file" >"$TEMPORARY_FILE"

    if [[ -f "$file" ]]; then
        chmod --reference="$file" -- "$TEMPORARY_FILE"
        chown --reference="$file" -- "$TEMPORARY_FILE"
    else
        chmod 644 -- "$TEMPORARY_FILE"
        chown root:root -- "$TEMPORARY_FILE"
    fi

    if [[ -f "$file" ]] && cmp -s -- "$file" "$TEMPORARY_FILE"; then
        rm -f -- "$TEMPORARY_FILE"
        TEMPORARY_FILE=""
        return
    fi

    mv -f -- "$TEMPORARY_FILE" "$file"
    TEMPORARY_FILE=""
    CONFIG_CHANGED=1
}

build_static_stanza() {
    local iface="$1"
    local address="$2"
    local gateway="$3"
    shift 3

    local dns_line=""

    if (( $# > 0 )); then
        dns_line="    dns-nameservers $*"
    fi

    cat <<EOF
iface $iface inet static
    address $address
    gateway $gateway
$dns_line
EOF
}

build_dhcp_stanza() {
    local iface="$1"

    cat <<EOF
iface $iface inet dhcp
EOF
}

check_configuration() {
    local iface="$1"

    if command_exists ifquery; then
        ifquery "$iface" >/dev/null 2>&1
    else
        warn "未找到 ifquery，跳过应用前的配置检查。"
    fi
}

apply_configuration() {
    local iface="$1"

    echo
    echo "正在重新启动网卡：$iface"
    echo "SSH 连接可能会立即中断。"

    # ifdown 在网卡状态记录丢失时可能失败，随后仍尝试 ifup。
    ifdown --force "$iface" 2>/dev/null || true
    ifup "$iface"
}

resolv_conf_target() {
    local target="$RESOLV_CONF"

    if [[ -L "$target" ]]; then
        target="$(readlink -f -- "$target" 2>/dev/null)" || return 1
    fi

    [[ -n "$target" ]] || return 1
    printf '%s\n' "$target"
}

resolv_conf_uses_systemd_resolved() {
    local target

    target="$(resolv_conf_target)" || return 1

    if [[ "$target" == /run/systemd/resolve/* ]]; then
        return 0
    fi

    [[ -r "$RESOLV_CONF" ]] &&
        grep -Eq \
            '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.(53|54)([[:space:]]|$)' \
            "$RESOLV_CONF"
}

resolv_conf_uses_resolvconf() {
    local target

    target="$(resolv_conf_target)" || return 1

    [[ "$target" == /run/resolvconf/* ||
       "$target" == /var/run/resolvconf/* ]]
}

write_static_resolv_conf() {
    local target
    local directory
    local dns
    local -a dns_servers=("$@")

    target="$(resolv_conf_target)" ||
        die "无法确定 $RESOLV_CONF 的实际路径，DNS 尚未应用。"
    directory="$(dirname -- "$target")"

    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] ||
            die "DNS 配置目标必须是普通文件：$target"
        path_is_root_owned_and_not_writable "$target" ||
            die "DNS 配置目标必须属于 root，且不能允许组或其他用户写入：$target"

        backup_file "$target"
    else
        [[ -d "$directory" ]] ||
            die "DNS 配置目录不存在：$directory"
    fi

    TEMPORARY_FILE="$(mktemp "$directory/.resolv.conf.netset.XXXXXX")" ||
        die "无法创建临时 DNS 配置文件。"

    {
        echo "# Generated by netset."

        if [[ -f "$target" ]]; then
            awk '
                $1 == "search" ||
                $1 == "domain" ||
                $1 == "options" ||
                $1 == "sortlist" {
                    print
                }
            ' "$target"
        fi

        for dns in "${dns_servers[@]}"; do
            printf 'nameserver %s\n' "$dns"
        done
    } >"$TEMPORARY_FILE"

    if [[ -f "$target" ]]; then
        chmod --reference="$target" -- "$TEMPORARY_FILE"
        chown --reference="$target" -- "$TEMPORARY_FILE"
    else
        chmod 644 -- "$TEMPORARY_FILE"
        chown root:root -- "$TEMPORARY_FILE"
    fi

    if ! mv -f -- "$TEMPORARY_FILE" "$target" 2>/dev/null; then
        # /etc/resolv.conf 在容器等环境中可能是单文件挂载点，不能被 rename。
        cp -- "$TEMPORARY_FILE" "$target" ||
            die "无法更新 DNS 配置文件：$target"
        rm -f -- "$TEMPORARY_FILE"
    fi

    TEMPORARY_FILE=""

    echo "DNS 已同步到：$RESOLV_CONF"
}

apply_static_dns_configuration() {
    local iface="$1"
    shift
    local dns
    local -a dns_servers=("$@")

    if command_exists resolvectl &&
       resolv_conf_uses_systemd_resolved; then
        if resolvectl dns "$iface" "${dns_servers[@]}" >/dev/null 2>&1; then
            resolvectl domain "$iface" '~.' >/dev/null 2>&1 ||
                warn "无法为 $iface 设置 systemd-resolved 默认 DNS 路由。"
            resolvectl flush-caches >/dev/null 2>&1 || true
            echo "DNS 已同步到 systemd-resolved：${dns_servers[*]}"
            return
        fi

        warn "systemd-resolved DNS 设置失败，尝试直接更新 $RESOLV_CONF。"
    fi

    if command_exists resolvconf &&
       resolv_conf_uses_resolvconf; then
        if {
            for dns in "${dns_servers[@]}"; do
                printf 'nameserver %s\n' "$dns"
            done
        } | resolvconf -a "${iface}.netset"; then
            echo "DNS 已同步到 resolvconf：${dns_servers[*]}"
            return
        fi

        warn "resolvconf DNS 设置失败，尝试直接更新 $RESOLV_CONF。"
    fi

    write_static_resolv_conf "${dns_servers[@]}"
}

clear_resolvconf_static_dns() {
    local iface="$1"

    if command_exists resolvconf; then
        resolvconf -d "${iface}.netset" >/dev/null 2>&1 || true
    fi
}

get_current_dns_servers() {
    local iface="$1"
    local dns_output=""
    local token
    local existing
    local duplicate
    local -a dns_servers=()

    if command_exists resolvectl; then
        dns_output="$(resolvectl dns "$iface" 2>/dev/null)" || true
        dns_output="${dns_output#*:}"

        for token in $dns_output; do
            validate_ipv4 "$token" || continue
            duplicate=0

            for existing in "${dns_servers[@]}"; do
                if [[ "$existing" == "$token" ]]; then
                    duplicate=1
                    break
                fi
            done

            if (( duplicate == 0 )); then
                dns_servers+=("$token")
            fi
        done
    fi

    if (( ${#dns_servers[@]} == 0 )) && [[ -r "$RESOLV_CONF" ]]; then
        while read -r token; do
            validate_ipv4 "$token" || continue
            duplicate=0

            for existing in "${dns_servers[@]}"; do
                if [[ "$existing" == "$token" ]]; then
                    duplicate=1
                    break
                fi
            done

            if (( duplicate == 0 )); then
                dns_servers+=("$token")
            fi
        done < <(
            awk '
                $1 == "nameserver" {
                    print $2
                }
            ' "$RESOLV_CONF"
        )
    fi

    if (( ${#dns_servers[@]} > 0 )); then
        printf '%s\n' "${dns_servers[@]}"
    fi
}

restore_configuration_files() {
    local config_file="$1"
    local config_existed="$2"
    local config_backup="$3"

    if [[ "$config_existed" -eq 1 ]]; then
        if ! cp -a -- "$config_backup" "$config_file"; then
            warn "恢复配置文件失败：$config_file"
        fi
    elif ! rm -f -- "$config_file"; then
        warn "删除新建配置文件失败：$config_file"
    fi

    if [[ $INCLUDE_CHANGED -eq 1 ]]; then
        if ! cp -a -- "$INCLUDE_BACKUP_FILE" "$INTERFACES_FILE"; then
            warn "恢复主配置文件失败：$INTERFACES_FILE"
        fi
    fi

    INCLUDE_CHANGED=0
    INCLUDE_BACKUP_FILE=""
}

write_and_apply_configuration() {
    local iface="$1"
    local config_file="$2"
    local stanza="$3"
    local config_existed=0
    local config_backup=""

    if [[ -e "$config_file" || -L "$config_file" ]]; then
        [[ -f "$config_file" && ! -L "$config_file" ]] ||
            die "目标配置必须是普通文件且不能是符号链接：$config_file"
        path_is_root_owned_and_not_writable "$config_file" ||
            die "目标配置必须属于 root，且不能允许组或其他用户写入：$config_file"

        config_existed=1
        backup_file "$config_file"
        config_backup="$LAST_BACKUP_FILE"
    fi

    ensure_include_directory "$config_file"
    replace_ipv4_stanza "$config_file" "$iface" "$stanza"

    if [[ $CONFIG_CHANGED -eq 0 && $INCLUDE_CHANGED -eq 0 ]]; then
        echo "配置未变化，无需重新启动网卡。"
        return
    fi

    if ! check_configuration "$iface"; then
        restore_configuration_files \
            "$config_file" "$config_existed" "$config_backup"
        die "ifquery 检查失败，已恢复修改前的配置。"
    fi

    echo "配置已写入。"

    if apply_configuration "$iface"; then
        return
    fi

    warn "新配置应用失败，正在恢复修改前的配置。"
    restore_configuration_files \
        "$config_file" "$config_existed" "$config_backup"

    ifdown --force "$iface" 2>/dev/null || true
    if ifup "$iface"; then
        die "新配置应用失败，旧配置已恢复并重新启用。"
    fi

    die "新配置应用失败，旧配置文件已恢复，但网卡重新启用失败，请立即检查控制台。"
}

show_status() {
    local iface
    local config_file=""
    local dns=""
    local dependency

    command_exists ip ||
        die "未找到 ip 命令，请安装 iproute2。"

    iface="$(detect_interface)"

    if [[ -f "$INTERFACES_FILE" ]]; then
        config_file="$(find_interface_config "$iface")"
    else
        config_file="$DEFAULT_CONFIG"
    fi

    echo "netset 状态"
    echo

    echo "脚本："
    if [[ -x "$INSTALL_PATH" ]]; then
        echo "  [正常] 已安装：$INSTALL_PATH"
    else
        echo "  [未安装] $INSTALL_PATH"
    fi

    echo
    echo "依赖："
    for dependency in ip ifup ifdown ifquery flock; do
        if command_exists "$dependency"; then
            echo "  [正常] $dependency 已安装"
        else
            echo "  [缺失] $dependency"
        fi
    done

    echo
    echo "网卡：$iface"
    echo

    echo "IPv4："
    ip -4 -o address show dev "$iface" |
        awk '{print "  " $4}' ||
        true

    echo
    echo "默认路由："
    ip -4 route show default |
        sed 's/^/  /' ||
        true

    echo
    echo "DNS："

    if command_exists resolvectl; then
        dns="$(
            resolvectl dns "$iface" 2>/dev/null |
            sed 's/^/  /' ||
            true
        )"
    fi

    if [[ -n "$dns" ]]; then
        printf '%s\n' "$dns"
    elif [[ -r "$RESOLV_CONF" ]]; then
        grep -E '^[[:space:]]*nameserver[[:space:]]+' "$RESOLV_CONF" |
            sed 's/^/  /' ||
            echo "  未发现 nameserver"
    else
        echo "  无法读取 $RESOLV_CONF"
    fi

    echo
    echo "网络管理器："
    if command_exists systemctl &&
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "  [冲突] NetworkManager 正在运行"
    else
        echo "  [正常] 未检测到活动的 NetworkManager"
    fi

    if command_exists systemctl &&
       systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "  [警告] systemd-networkd 正在运行"
    else
        echo "  [正常] 未检测到活动的 systemd-networkd"
    fi

    if [[ -d /etc/netplan ]] &&
       find /etc/netplan -maxdepth 1 -name '*.yaml' -print -quit 2>/dev/null |
       grep -q .; then
        echo "  [冲突] 检测到 Netplan 配置"
    else
        echo "  [正常] 未检测到 Netplan 配置"
    fi

    if [[ -d /etc/pve ]]; then
        echo "  [冲突] 检测到 PVE 宿主机环境"
    fi

    echo
    echo "配置文件：$config_file"

    if [[ -f "$config_file" ]]; then
        echo
        echo "当前配置："
        sed 's/^/  /' "$config_file"
    else
        echo "  尚未创建"
    fi
}

show_static_examples() {
    local route_info=""
    local gateway=""
    local iface=""
    local address=""
    local -a dns_servers=()

    # 以下内容只是便于复制的提示；读取失败时不影响帮助信息。
    command_exists ip || return 0

    route_info="$(
        ip -4 route show default 2>/dev/null |
        awk '
            {
                gateway = ""
                iface = ""

                for (i = 1; i <= NF; i++) {
                    if ($i == "via" && (i + 1) <= NF) {
                        gateway = $(i + 1)
                    } else if ($i == "dev" && (i + 1) <= NF) {
                        iface = $(i + 1)
                    }
                }

                if (gateway != "" && iface != "") {
                    print gateway, iface
                    exit
                }
            }
        '
    )" || true

    [[ -n "$route_info" ]] || return 0
    read -r gateway iface <<<"$route_info"

    validate_ipv4 "$gateway" || return 0
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 0

    address="$(
        ip -4 -o address show dev "$iface" scope global 2>/dev/null |
        awk 'NR == 1 { print $4 }'
    )" || true

    [[ "$address" == */* ]] || return 0
    validate_ipv4 "${address%/*}" || return 0
    validate_cidr "${address##*/}" || return 0

    mapfile -t dns_servers < <(get_current_dns_servers "$iface")

    echo
    echo "根据当前网络生成的示例（网卡 $iface）："
    echo "  # 仅修改 IP；保留当前网关和 DNS"
    printf '  netset static %s\n' "$address"

    echo "  # 显式指定网关；保留当前 DNS"
    printf '  netset static %s %s\n' "$address" "$gateway"

    if (( ${#dns_servers[@]} > 0 )); then
        echo "  # 显式指定当前 DNS"
        printf '  netset static %s %s %s\n' \
            "$address" "$gateway" "${dns_servers[*]}"
    else
        echo "  # 覆盖 DNS 的格式"
        printf '  netset static %s %s <DNS> [DNS...]\n' \
            "$address" "$gateway"
    fi
}

show_static_usage() {
    cat >&2 <<'EOF'
用法：
  netset static <IP[/CIDR]> [Gateway [DNS...]]
EOF

    show_static_examples >&2
}

set_static() {
    local raw_address="${1:-}"
    local gateway="${2:-}"
    shift "$(( $# >= 2 ? 2 : $# ))"

    local -a dns_servers=("$@")
    local iface
    local address
    local config_file
    local stanza
    local dns
    local gateway_was_supplied=0
    local dns_was_supplied=0

    if [[ -z "$raw_address" ]]; then
        show_static_usage
        exit 1
    fi

    address="$(normalize_address "$raw_address")"

    if [[ -n "$gateway" ]]; then
        gateway_was_supplied=1
        validate_ipv4 "$gateway" ||
            die "无效的网关地址：$gateway"
    fi

    if (( ${#dns_servers[@]} > 0 )); then
        dns_was_supplied=1
    fi

    for dns in "${dns_servers[@]}"; do
        validate_ipv4 "$dns" ||
            die "无效的 DNS 地址：$dns"
    done

    if (( gateway_was_supplied == 1 )); then
        require_root static "$raw_address" "$gateway" "${dns_servers[@]}"
    else
        require_root static "$raw_address"
    fi

    acquire_lock
    check_environment
    validate_interface_files_security

    iface="$(detect_interface)"
    check_interface_complexity "$iface"
    config_file="$(find_interface_config "$iface")"

    if (( gateway_was_supplied == 0 )); then
        gateway="$(get_current_gateway "$iface")" || true
        validate_ipv4 "$gateway" ||
            die "未检测到网卡 $iface 的当前 IPv4 网关，请显式指定 Gateway。"
    fi

    if (( dns_was_supplied == 0 )); then
        mapfile -t dns_servers < <(get_current_dns_servers "$iface")
    fi

    stanza="$(build_static_stanza \
        "$iface" "$address" "$gateway" "${dns_servers[@]}")"

    echo "网卡：$iface"
    echo "配置文件：$config_file"
    echo "IPv4：$address"

    if (( gateway_was_supplied == 1 )); then
        echo "网关：$gateway（显式指定）"
    else
        echo "网关：$gateway（保持当前配置）"
    fi

    if (( dns_was_supplied == 1 )); then
        echo "DNS：${dns_servers[*]}（显式指定）"
    elif (( ${#dns_servers[@]} > 0 )); then
        echo "DNS：${dns_servers[*]}（保持当前配置）"
    else
        echo "DNS：保持当前配置（未检测到 IPv4 DNS，不主动修改）"
        warn "未检测到当前 IPv4 DNS，静态配置中不会写入 dns-nameservers。"
    fi

    echo

    write_and_apply_configuration "$iface" "$config_file" "$stanza"

    if (( ${#dns_servers[@]} > 0 )); then
        apply_static_dns_configuration "$iface" "${dns_servers[@]}"
    else
        echo "DNS 未修改。"
    fi
}

set_dhcp() {
    local iface
    local config_file
    local stanza

    (( $# == 0 )) ||
        die "用法：netset dhcp"

    require_root dhcp
    acquire_lock
    check_environment
    validate_interface_files_security

    iface="$(detect_interface)"
    check_interface_complexity "$iface"
    config_file="$(find_interface_config "$iface")"
    stanza="$(build_dhcp_stanza "$iface")"

    echo "网卡：$iface"
    echo "配置文件：$config_file"
    echo "模式：DHCP"
    echo

    write_and_apply_configuration "$iface" "$config_file" "$stanza"
    clear_resolvconf_static_dns "$iface"
}

main() {
    local command="${1:-}"

    if (( $# > 0 )); then
        shift
    fi

    case "$command" in
        "")
            show_short_help
            show_static_examples
            ;;

        -h)
            (( $# == 0 )) || die "-h 不接受参数"
            show_short_help
            show_static_examples
            ;;

        install)
            (( $# == 0 )) || die "用法：netset install"
            require_root install
            command_install
            ;;

        show|status)
            (( $# == 0 )) || die "用法：netset $command"
            show_status
            ;;

        static)
            set_static "$@"
            ;;

        dhcp)
            set_dhcp "$@"
            ;;

        help|--help)
            (( $# == 0 )) || die "$command 不接受参数"
            show_help
            ;;

        *)
            die "未知命令：$command。运行 netset help 查看完整帮助。"
            ;;
    esac
}

main "$@"
