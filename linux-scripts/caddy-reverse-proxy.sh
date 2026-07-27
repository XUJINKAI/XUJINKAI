#!/usr/bin/env bash
# caddy-reverse-proxy - 管理 Caddy HTTP/HTTPS 反向代理

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

PROGRAM_NAME="caddy-reverse-proxy"
INSTALL_PATH="/usr/local/bin/caddy-reverse-proxy"
ALIAS_PATH="/usr/local/bin/crp"
CADDYFILE="/etc/caddy/Caddyfile"
CONFIG_DIR="/etc/caddy/caddy-reverse-proxy.d"
LOCK_FILE="/run/lock/caddy-reverse-proxy.lock"

IMPORT_BEGIN="# BEGIN caddy-reverse-proxy"
IMPORT_LINE="import caddy-reverse-proxy.d/*.caddy"
IMPORT_END="# END caddy-reverse-proxy"
MANAGED_HEADER="# Managed by caddy-reverse-proxy. Do not edit manually."

TRANSACTION_ACTIVE=0
TRANSACTION_SITE_PATH=""
TRANSACTION_SITE_EXISTED=0
TRANSACTION_CADDYFILE_BACKUP=""
TRANSACTION_SITE_BACKUP=""
TEMPORARY_FILES=()

cleanup() {
    local exit_status=$?
    local temporary_file

    if [[ ${TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
        rollback_transaction >/dev/null 2>&1 || true
    fi

    for temporary_file in "${TEMPORARY_FILES[@]:-}"; do
        [[ -n "$temporary_file" ]] && rm -f -- "$temporary_file" || true
    done

    return "$exit_status"
}

trap cleanup EXIT

show_short_help() {
    cat <<'EOF'
caddy-reverse-proxy - Caddy 反向代理管理工具

常用命令：
  crp install
  crp add <域名或IP> <上游地址> [--http|--https] [选项]
  crp allow add|remove <域名或IP> <IP或CIDR列表>
  crp deny add|remove <域名或IP> <IP或CIDR列表>
  crp remove <域名或IP>
  crp status

HTTP 是默认模式。HTTPS 默认使用 Caddy 内部 CA，并临时重定向 HTTP。
运行 crp help 查看完整帮助。
EOF
}

show_help() {
    cat <<'EOF'
caddy-reverse-proxy - 管理 Caddy HTTP/HTTPS 反向代理

用法：
  caddy-reverse-proxy install
  caddy-reverse-proxy add <域名或IP> <上游地址> [选项]
  caddy-reverse-proxy allow add|remove <域名或IP> <IP或CIDR列表>
  caddy-reverse-proxy deny add|remove <域名或IP> <IP或CIDR列表>
  caddy-reverse-proxy remove <域名或IP>
  caddy-reverse-proxy status
  caddy-reverse-proxy help

安装后也可以使用短命令 crp。

命令：

  install
      将当前脚本安装为：

        /usr/local/bin/caddy-reverse-proxy
        /usr/local/bin/crp -> /usr/local/bin/caddy-reverse-proxy


  add <域名或IP> <上游地址> [选项]
      新增或更新一个反向代理。

      域名或IP：
        Caddy 对外提供服务的域名、IPv4 地址或通配符域名。
        不要包含 http://、https://、端口或路径。

      上游地址：
        后端服务地址，支持 HTTP 或 HTTPS，例如：

          127.0.0.1:8080
          http://127.0.0.1:8080
          https://backend.example.test:8443

        未写协议时默认使用 http://。上游地址不能包含路径、
        查询参数、用户信息或片段。

      前端协议选项：

        --http
            只使用 HTTP，不申请或使用 TLS 证书。
            这是默认模式。

        --https
            使用 HTTPS，默认等同于同时指定 --tls internal。
            同时显式创建 HTTP 到 HTTPS 的 302 临时重定向。

        --tls internal
            HTTPS 使用 Caddy 内部 CA 签发的证书。
            适合内网域名或 IP；客户端需要信任 Caddy 根证书。
            单独指定此选项时会自动启用 HTTPS。
            此选项不能和 --http 一起使用。

        --tls automatic
            HTTPS 使用 Caddy 自动管理的公开证书。
            单独指定此选项时会自动启用 HTTPS。
            此选项不能和 --http 一起使用。

      IP 访问控制：

        --allow <IP或CIDR列表>
        --allow-ip <IP或CIDR列表>
            只允许列表中的客户端访问。未指定时允许所有客户端。

        --deny <IP或CIDR列表>
        --deny-ip <IP或CIDR列表>
            拒绝列表中的客户端访问。

        列表使用逗号分隔；选项也可以重复。支持 IPv4、IPv6 和 CIDR。
        同时匹配允许列表和拒绝列表时，拒绝规则优先。

      示例：

        crp add app.example.com 127.0.0.1:8080

        crp add app.example.com https://backend.example.test:8443 \
          --https --tls automatic

        crp add app.home.arpa 192.0.2.10:8080 \
          --https

        crp add status.example.com 127.0.0.1:3000 \
          --allow 192.0.2.0/24,2001:db8::/32 \
          --deny 192.0.2.100


  allow add|remove <域名或IP> <IP或CIDR列表>
  deny add|remove <域名或IP> <IP或CIDR列表>
      单独增加或删除已有代理的 IP 允许/拒绝列表，不需要重新指定上游、
      HTTP/HTTPS 模式或另一份 IP 列表。

      列表可以使用逗号分隔，也可以重复执行命令。删除不存在的项目不会报错。

      示例：

        crp allow add app.example.com 192.0.2.0/24,2001:db8::/32
        crp allow remove app.example.com 192.0.2.0/24
        crp deny add app.example.com 192.0.2.100
        crp deny remove app.example.com 192.0.2.100


  remove <域名或IP>
      删除由本工具管理的对应代理配置并重新加载 Caddy。

      示例：

        crp remove app.example.com


  status / show
      显示：

        - 完整命令和 crp 短命令是否已安装
        - caddy、systemctl、flock 依赖状态
        - Caddy 服务状态
        - 主 Caddyfile 及 import 配置状态
        - Caddy 当前配置能否通过校验
        - 当前由本工具管理的代理及 IP 访问规则
        - 每个代理对应的可复制 crp add 命令


  help
      显示本完整帮助。


文件：

  /usr/local/bin/caddy-reverse-proxy
      安装后的脚本。

  /usr/local/bin/crp
      指向完整命令的符号链接。

  /etc/caddy/Caddyfile
      Caddy 主配置文件。
      本工具会加入带 BEGIN/END 注释的 import 配置块。

  /etc/caddy/caddy-reverse-proxy.d/*.caddy
      每个反向代理对应一个由本工具管理的 Caddy 配置文件。

  /run/lock/caddy-reverse-proxy.lock
      防止多个配置命令同时执行。


适用范围：

  - 已安装 Caddy 的 Debian、Ubuntu 等 Linux 系统。
  - Caddy 由名为 caddy 的 systemd 服务管理。
  - 主配置使用 Caddyfile 适配器。
  - 一个域名或 IP 对应一个由本工具管理的反向代理。


权限：

  install、add、allow、deny、remove 需要 root 权限。
  普通用户运行时，脚本会自动通过 sudo 重新执行。

  help、status、show 不需要 root 权限。


说明：

  - 本工具不会自动安装或升级 Caddy。
  - add、allow、deny 和 remove 会先校验现有配置，再原子更新配置并重新加载 Caddy。
  - 新配置校验或重新加载失败时，会自动恢复修改前的配置。
  - --allow 和 --deny 使用直接连接到 Caddy 的来源 IP。
    如果 Caddy 前面还有 CDN 或其他代理，匹配到的是前置代理 IP；
    本工具不会自动信任 X-Forwarded-For 等客户端可伪造的请求头。
  - 公网通配符证书需要 Caddy DNS provider 模块和对应 DNS challenge 配置；
    未配置这些内容时，通配符域名应使用 --tls internal。
  - --tls internal 的根证书通常位于 Caddy 数据目录的 pki/authorities/local/。
    应按实际安装方式安全地导出并信任根证书。
EOF
}

die() {
    echo "错误：$*" >&2
    exit 1
}

command_is_available() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        [[ -x "/usr/sbin/$command_name" ]] ||
        [[ -x "/sbin/$command_name" ]]
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        command_is_available sudo ||
            die "当前命令需要 root 权限，但系统中未安装 sudo"

        local script_path
        script_path="$(readlink -f -- "$0")" ||
            die "无法确定当前脚本路径：$0"

        exec sudo -- /bin/bash "$script_path" "$@"
    fi
}

acquire_lock() {
    command_is_available flock ||
        die "缺少 flock 命令，请安装 util-linux"

    mkdir -p -- "$(dirname -- "$LOCK_FILE")"
    exec 9>>"$LOCK_FILE"
    flock -x 9
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

validate_regular_root_file() {
    local path="$1"
    local label="$2"

    [[ -f "$path" && ! -L "$path" ]] ||
        die "$label 必须是普通文件且不能是符号链接：$path"
    path_is_root_owned_and_not_writable "$path" ||
        die "$label 必须属于 root，且不能允许组或其他用户写入：$path"
}

validate_root_directory() {
    local path="$1"
    local label="$2"

    [[ -d "$path" && ! -L "$path" ]] ||
        die "$label 必须是普通目录且不能是符号链接：$path"
    path_is_root_owned_and_not_writable "$path" ||
        die "$label 必须属于 root，且不能允许组或其他用户写入：$path"
}

command_install() {
    local source_path
    source_path="$(readlink -f -- "$0")" ||
        die "无法确定当前脚本路径：$0"

    if [[ -e "$ALIAS_PATH" || -L "$ALIAS_PATH" ]]; then
        if [[ ! -L "$ALIAS_PATH" ]] ||
            [[ "$(readlink -- "$ALIAS_PATH" 2>/dev/null)" != "$INSTALL_PATH" ]]; then
            die "短命令路径已被其他文件占用，拒绝覆盖：$ALIAS_PATH"
        fi
    fi

    if [[ "$source_path" == "$INSTALL_PATH" ]]; then
        chmod 755 -- "$INSTALL_PATH"
        ln -sfn -- "$INSTALL_PATH" "$ALIAS_PATH"
        echo "$PROGRAM_NAME 已经安装在：$INSTALL_PATH"
        echo "短命令：$ALIAS_PATH"
        return
    fi

    install -m 755 -- "$source_path" "$INSTALL_PATH"
    ln -sfn -- "$INSTALL_PATH" "$ALIAS_PATH"

    echo "安装完成：$INSTALL_PATH"
    echo "短命令：$ALIAS_PATH"
    echo
    echo "下一步可以运行："
    echo "  crp status"
    echo "  crp add app.example.com 127.0.0.1:8080"
}

validate_ipv4() {
    local address="$1"
    local part
    local -a octets=()

    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"

    for part in "${octets[@]}"; do
        [[ "$part" == "0" || "$part" != 0* ]] || return 1
        ((10#$part >= 0 && 10#$part <= 255)) || return 1
    done
}

normalize_frontend_host() {
    local host="$1"
    local wildcard=0
    local domain
    local label
    local -a labels=()

    [[ -n "$host" ]] || die "域名或 IP 不能为空"
    [[ "$host" != *"://"* ]] ||
        die "域名或 IP 不要包含协议：$host"
    [[ ! "$host" =~ [[:space:][:cntrl:]/\\:] ]] ||
        die "域名或 IP 不能包含空白字符、控制字符、斜杠、反斜杠或端口：$host"

    host="${host,,}"
    [[ ${#host} -le 253 ]] || die "域名过长：$host"

    if validate_ipv4 "$host"; then
        printf '%s\n' "$host"
        return
    fi
    [[ ! "$host" =~ ^[0-9.]+$ ]] ||
        die "IPv4 地址无效：$host"

    domain="$host"
    if [[ "$domain" == \*.* ]]; then
        wildcard=1
        domain="${domain#*.}"
    fi

    [[ -n "$domain" && "$domain" =~ ^[a-z0-9.-]+$ ]] ||
        die "域名格式无效：$host"
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] ||
        die "域名格式无效：$host"

    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] ||
            die "域名标签为空或过长：$host"
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
            die "域名标签格式无效：$host"
    done

    if [[ $wildcard -eq 1 ]]; then
        printf '*.%s\n' "$domain"
    else
        printf '%s\n' "$domain"
    fi
}

normalize_upstream() {
    local upstream="$1"
    local host
    local port
    local label
    local -a labels=()

    [[ -n "$upstream" ]] || die "上游地址不能为空"

    if [[ "$upstream" != *"://"* ]]; then
        upstream="http://$upstream"
    fi

    if [[ "$upstream" =~ ^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]:-}"
    else
        die "上游地址格式无效，仅支持 http(s)://主机[:端口]：$upstream"
    fi

    if [[ "$host" == \[*\] ]]; then
        [[ "$host" == *:* ]] ||
            die "方括号只能用于 IPv6 上游地址：$upstream"
    elif [[ "$host" =~ ^[0-9.]+$ ]]; then
        validate_ipv4 "$host" ||
            die "上游 IPv4 地址无效：$host"
    else
        [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] ||
            die "上游主机名格式无效：$host"

        IFS='.' read -r -a labels <<<"$host"
        for label in "${labels[@]}"; do
            [[ -n "$label" && ${#label} -le 63 ]] ||
                die "上游主机名标签为空或过长：$host"
            [[ "$label" =~ ^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$ ]] ||
                die "上游主机名格式无效：$host"
        done
    fi

    if [[ -n "$port" ]]; then
        [[ "$port" == "0" || "$port" != 0* ]] ||
            die "上游端口不能包含前导零：$port"
        ((10#$port >= 1 && 10#$port <= 65535)) ||
            die "上游端口必须在 1 到 65535 之间：$port"
    fi

    printf '%s\n' "$upstream"
}

validate_ip_range() {
    local value="$1"
    local address="$value"
    local prefix=""

    [[ -n "$value" ]] || return 1
    [[ "$value" != */*/* ]] || return 1

    if [[ "$value" == */* ]]; then
        address="${value%/*}"
        prefix="${value##*/}"
        [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
        [[ "$prefix" == "0" || "$prefix" != 0* ]] || return 1
    fi

    if validate_ipv4 "$address"; then
        [[ -z "$prefix" ]] || ((10#$prefix >= 0 && 10#$prefix <= 32))
        return
    fi

    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$address" != : && "$address" != *:::* ]] || return 1
    [[ -z "$prefix" ]] || ((10#$prefix >= 0 && 10#$prefix <= 128))
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

append_ip_list() {
    local list="$1"
    local destination_name="$2"
    local value
    local -a values=()
    local -n destination="$destination_name"

    [[ -n "$list" && "$list" != ,* && "$list" != *, &&
        "$list" != *,,* && ! "$list" =~ [[:space:][:cntrl:]] ]] ||
        die "IP 列表格式无效：$list"

    IFS=',' read -r -a values <<<"$list"
    for value in "${values[@]}"; do
        validate_ip_range "$value" ||
            die "无效的 IP 或 CIDR：$value"

        if ! array_contains "$value" "${destination[@]:-}"; then
            destination+=("$value")
        fi
    done
}

join_by_comma() {
    local first=1
    local value

    for value in "$@"; do
        if [[ $first -eq 0 ]]; then
            printf ','
        fi
        printf '%s' "$value"
        first=0
    done
}

site_config_path() {
    local host="$1"
    local file_name="${host//\*/_wildcard_}"

    printf '%s/%s.caddy\n' "$CONFIG_DIR" "$file_name"
}

ensure_config_environment() {
    command_is_available caddy ||
        die "未安装 caddy，请先按照 Caddy 官方文档完成安装"
    command_is_available systemctl ||
        die "未找到 systemctl，本工具只支持由 systemd 管理的 Caddy"

    [[ -e "$CADDYFILE" || -L "$CADDYFILE" ]] ||
        die "Caddy 主配置文件不存在：$CADDYFILE"
    validate_regular_root_file "$CADDYFILE" "Caddy 主配置文件"
    validate_root_directory "$(dirname -- "$CADDYFILE")" "Caddy 配置目录"

    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        validate_root_directory "$CONFIG_DIR" "反向代理配置目录"
    else
        install -d -m 755 -o root -g root -- "$CONFIG_DIR"
    fi
    validate_config_directory_contents

    systemctl is-active --quiet caddy ||
        die "Caddy systemd 服务没有运行，请先启动：sudo systemctl start caddy"

    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile \
        >/dev/null 2>&1; then
        die "现有 Caddy 配置校验失败，未进行修改。请先运行：sudo caddy validate --config $CADDYFILE --adapter caddyfile"
    fi
}

import_block_state() {
    local begin_count
    local end_count
    local begin_line
    local end_line
    local import_count
    local extra_count

    begin_count="$(grep -Fxc -- "$IMPORT_BEGIN" "$CADDYFILE" 2>/dev/null || true)"
    end_count="$(grep -Fxc -- "$IMPORT_END" "$CADDYFILE" 2>/dev/null || true)"

    if [[ "$begin_count" == "0" && "$end_count" == "0" ]]; then
        printf 'absent\n'
        return
    fi

    if [[ "$begin_count" != "1" || "$end_count" != "1" ]]; then
        printf 'malformed\n'
        return
    fi

    begin_line="$(grep -Fn -- "$IMPORT_BEGIN" "$CADDYFILE" | cut -d: -f1)"
    end_line="$(grep -Fn -- "$IMPORT_END" "$CADDYFILE" | cut -d: -f1)"

    if ((begin_line >= end_line)); then
        printf 'malformed\n'
        return
    fi

    import_count="$(
        awk -v begin="$begin_line" -v end="$end_line" -v expected="$IMPORT_LINE" '
            NR > begin && NR < end && $0 == expected {
                count++
            }
            END {
                print count + 0
            }
        ' "$CADDYFILE"
    )"
    extra_count="$(
        awk -v begin="$begin_line" -v end="$end_line" -v expected="$IMPORT_LINE" '
            NR > begin && NR < end && $0 != expected &&
                $0 !~ /^[[:space:]]*$/ {
                count++
            }
            END {
                print count + 0
            }
        ' "$CADDYFILE"
    )"

    if [[ "$import_count" == "1" && "$extra_count" == "0" ]]; then
        printf 'present\n'
    else
        printf 'malformed\n'
    fi
}

ensure_import_block() {
    local state
    local temporary_file

    state="$(import_block_state)"
    case "$state" in
        present)
            return
            ;;
        malformed)
            die "$CADDYFILE 中的 $PROGRAM_NAME import 标记不完整或已被修改，请先手动修复"
            ;;
    esac

    temporary_file="$(mktemp "$(dirname -- "$CADDYFILE")/.Caddyfile.crp.XXXXXX")" ||
        die "无法创建临时 Caddyfile"
    TEMPORARY_FILES+=("$temporary_file")

    cp -- "$CADDYFILE" "$temporary_file"
    printf '\n%s\n%s\n%s\n' \
        "$IMPORT_BEGIN" "$IMPORT_LINE" "$IMPORT_END" >>"$temporary_file"
    chown --reference="$CADDYFILE" -- "$temporary_file"
    chmod --reference="$CADDYFILE" -- "$temporary_file"
    mv -f -- "$temporary_file" "$CADDYFILE"
}

validate_managed_site_file() {
    local path="$1"
    local expected_host="$2"
    local configured_host

    [[ -f "$path" && ! -L "$path" ]] ||
        die "目标配置必须是普通文件且不能是符号链接：$path"
    path_is_root_owned_and_not_writable "$path" ||
        die "目标配置必须属于 root，且不能允许组或其他用户写入：$path"
    grep -Fxq -- "$MANAGED_HEADER" "$path" ||
        die "目标文件不属于 $PROGRAM_NAME 管理，拒绝覆盖：$path"

    configured_host="$(
        sed -n 's/^# crp-host: //p' "$path" |
            head -n 1
    )"
    [[ "$configured_host" == "$expected_host" ]] ||
        die "目标文件记录的域名不一致，拒绝覆盖：$path"
}

validate_config_directory_contents() {
    local path

    while IFS= read -r -d '' path; do
        [[ -f "$path" && ! -L "$path" ]] ||
            die "代理配置必须是普通文件且不能是符号链接：$path"
        path_is_root_owned_and_not_writable "$path" ||
            die "代理配置必须属于 root，且不能允许组或其他用户写入：$path"
        grep -Fxq -- "$MANAGED_HEADER" "$path" ||
            die "代理配置目录中存在非本工具管理的文件，拒绝自动导入：$path"
    done < <(
        find "$CONFIG_DIR" -maxdepth 1 -name '*.caddy' -print0 2>/dev/null
    )
}

begin_transaction() {
    local site_path="$1"

    TRANSACTION_SITE_PATH="$site_path"
    TRANSACTION_SITE_EXISTED=0
    TRANSACTION_CADDYFILE_BACKUP="$(mktemp "/tmp/crp-caddyfile.XXXXXX")" ||
        die "无法创建 Caddyfile 回滚文件"
    TEMPORARY_FILES+=("$TRANSACTION_CADDYFILE_BACKUP")
    cp -a -- "$CADDYFILE" "$TRANSACTION_CADDYFILE_BACKUP"

    if [[ -e "$site_path" || -L "$site_path" ]]; then
        TRANSACTION_SITE_EXISTED=1
        TRANSACTION_SITE_BACKUP="$(mktemp "/tmp/crp-site.XXXXXX")" ||
            die "无法创建代理配置回滚文件"
        TEMPORARY_FILES+=("$TRANSACTION_SITE_BACKUP")
        cp -a -- "$site_path" "$TRANSACTION_SITE_BACKUP"
    else
        TRANSACTION_SITE_BACKUP=""
    fi

    TRANSACTION_ACTIVE=1
}

rollback_transaction() {
    [[ -n "$TRANSACTION_CADDYFILE_BACKUP" ]] &&
        cp -a -- "$TRANSACTION_CADDYFILE_BACKUP" "$CADDYFILE"

    if [[ -n "$TRANSACTION_SITE_PATH" ]]; then
        if [[ "$TRANSACTION_SITE_EXISTED" -eq 1 ]]; then
            cp -a -- "$TRANSACTION_SITE_BACKUP" "$TRANSACTION_SITE_PATH"
        else
            rm -f -- "$TRANSACTION_SITE_PATH"
        fi
    fi
}

finish_transaction() {
    TRANSACTION_ACTIVE=0
}

write_site_config() {
    local path="$1"
    local host="$2"
    local upstream="$3"
    local mode="$4"
    local tls_mode="$5"
    local allow_name="$6"
    local deny_name="$7"
    local -n allowed_ranges="$allow_name"
    local -n denied_ranges="$deny_name"
    local temporary_file
    local allow_metadata="-"
    local deny_metadata="-"
    local ip

    if (( ${#allowed_ranges[@]} > 0 )); then
        allow_metadata="$(join_by_comma "${allowed_ranges[@]}")"
    fi
    if (( ${#denied_ranges[@]} > 0 )); then
        deny_metadata="$(join_by_comma "${denied_ranges[@]}")"
    fi

    temporary_file="$(mktemp "$CONFIG_DIR/.crp-site.XXXXXX")" ||
        die "无法创建临时代理配置"
    TEMPORARY_FILES+=("$temporary_file")

    {
        echo "$MANAGED_HEADER"
        echo "# crp-host: $host"
        echo "# crp-mode: $mode"
        echo "# crp-upstream: $upstream"
        echo "# crp-tls: $tls_mode"
        echo "# crp-allow: $allow_metadata"
        echo "# crp-deny: $deny_metadata"
        echo

        if [[ "$mode" == "https" ]]; then
            echo "http://$host {"
            echo '    redir https://{host}{uri} temporary'
            echo "}"
            echo
            echo "https://$host {"
        else
            echo "http://$host {"
        fi

        if [[ "$tls_mode" == "internal" ]]; then
            echo "    tls internal"
            echo
        fi

        if (( ${#denied_ranges[@]} > 0 )); then
            printf '    @crp_denied remote_ip'
            for ip in "${denied_ranges[@]}"; do
                printf ' %s' "$ip"
            done
            printf '\n'
            echo '    respond @crp_denied "Forbidden" 403'
            echo
        fi

        if (( ${#allowed_ranges[@]} > 0 )); then
            echo '    @crp_not_allowed {'
            printf '        not remote_ip'
            for ip in "${allowed_ranges[@]}"; do
                printf ' %s' "$ip"
            done
            printf '\n'
            echo '    }'
            echo '    respond @crp_not_allowed "Forbidden" 403'
            echo
        fi

        if [[ "$upstream" == https://* ]]; then
            echo "    reverse_proxy $upstream {"
            echo '        header_up Host {upstream_hostport}'
            echo "    }"
        else
            echo "    reverse_proxy $upstream"
        fi
        echo "}"
    } >"$temporary_file"

    chown root:root -- "$temporary_file"
    chmod 644 -- "$temporary_file"
    mv -f -- "$temporary_file" "$path"
}

validate_and_reload_or_rollback() {
    local validation_output
    local reload_output
    local reason

    if ! validation_output="$(
        caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1
    )"; then
        reason="新 Caddy 配置校验失败"
        rollback_transaction
        finish_transaction
        die "$reason，已恢复原配置：${validation_output:-未提供详细信息}"
    fi

    if ! reload_output="$(systemctl reload caddy 2>&1)"; then
        reason="Caddy 重新加载失败"
        rollback_transaction

        if caddy validate --config "$CADDYFILE" --adapter caddyfile \
                >/dev/null 2>&1; then
            systemctl reload caddy >/dev/null 2>&1 || true
        fi

        finish_transaction
        die "$reason，已恢复原配置：${reload_output:-未提供详细信息}"
    fi

    finish_transaction
}

command_add() {
    [[ $# -ge 2 ]] ||
        die "用法：crp add <域名或IP> <上游地址> [--http|--https] [选项]"

    local host="$1"
    local upstream="$2"
    local mode="http"
    local mode_option=""
    local tls_mode="none"
    local tls_option=""
    local site_path
    local option
    local value
    local -a allow_list=()
    local -a deny_list=()
    shift 2

    while (( $# > 0 )); do
        option="$1"
        case "$option" in
            --http|--https)
                value="${option#--}"
                if [[ -n "$mode_option" && "$mode_option" != "$value" ]]; then
                    die "--http 和 --https 不能同时使用"
                fi
                mode="$value"
                mode_option="$value"
                shift
                ;;
            --tls)
                [[ $# -ge 2 ]] ||
                    die "--tls 缺少参数，支持 internal 或 automatic"
                [[ "$2" == "internal" || "$2" == "automatic" ]] ||
                    die "--tls 只支持 internal 或 automatic：$2"
                tls_mode="$2"
                tls_option="$2"
                shift 2
                ;;
            --tls=internal|--tls=automatic)
                tls_mode="${option#--tls=}"
                tls_option="$tls_mode"
                shift
                ;;
            --tls=*)
                die "--tls 只支持 internal 或 automatic：${option#--tls=}"
                ;;
            --allow|--allow-ip)
                [[ $# -ge 2 ]] || die "$option 缺少 IP 或 CIDR 列表"
                append_ip_list "$2" allow_list
                shift 2
                ;;
            --allow=*|--allow-ip=*)
                append_ip_list "${option#*=}" allow_list
                shift
                ;;
            --deny|--deny-ip)
                [[ $# -ge 2 ]] || die "$option 缺少 IP 或 CIDR 列表"
                append_ip_list "$2" deny_list
                shift 2
                ;;
            --deny=*|--deny-ip=*)
                append_ip_list "${option#*=}" deny_list
                shift
                ;;
            *)
                die "未知 add 选项：$option。运行 crp help 查看完整帮助"
                ;;
        esac
    done

    if [[ "$mode_option" == "http" && -n "$tls_option" ]]; then
        die "--http 不能和 --tls $tls_option 一起使用"
    fi

    if [[ -z "$mode_option" && -n "$tls_option" ]]; then
        mode="https"
    fi

    if [[ "$mode" == "https" && -z "$tls_option" ]]; then
        tls_mode="internal"
    elif [[ "$mode" == "http" ]]; then
        tls_mode="none"
    fi

    host="$(normalize_frontend_host "$host")"
    upstream="$(normalize_upstream "$upstream")"
    site_path="$(site_config_path "$host")"

    ensure_config_environment

    if [[ -e "$site_path" || -L "$site_path" ]]; then
        validate_managed_site_file "$site_path" "$host"
    fi

    case "$(import_block_state)" in
        malformed)
            die "$CADDYFILE 中的 $PROGRAM_NAME import 标记不完整或已被修改，请先手动修复"
            ;;
    esac

    begin_transaction "$site_path"
    ensure_import_block
    write_site_config \
        "$site_path" "$host" "$upstream" "$mode" "$tls_mode" \
        allow_list deny_list
    validate_and_reload_or_rollback

    echo "反向代理已生效："
    echo "  站点：$mode://$host"
    echo "  上游：$upstream"
    if [[ "$mode" == "https" ]]; then
        echo "  TLS：$tls_mode"
    fi

    if (( ${#allow_list[@]} > 0 )); then
        echo "  允许：$(join_by_comma "${allow_list[@]}")"
    else
        echo "  允许：全部客户端"
    fi

    if (( ${#deny_list[@]} > 0 )); then
        echo "  拒绝：$(join_by_comma "${deny_list[@]}")"
    else
        echo "  拒绝：无"
    fi

    echo "  配置：$site_path"
}

command_remove() {
    [[ $# -eq 1 ]] || die "用法：crp remove <域名或IP>"

    local host
    local site_path
    host="$(normalize_frontend_host "$1")"
    site_path="$(site_config_path "$host")"

    ensure_config_environment

    [[ -e "$site_path" || -L "$site_path" ]] ||
        die "没有找到由 $PROGRAM_NAME 管理的代理：$host"
    validate_managed_site_file "$site_path" "$host"

    case "$(import_block_state)" in
        absent)
            die "$CADDYFILE 中缺少 $PROGRAM_NAME import 配置，拒绝删除"
            ;;
        malformed)
            die "$CADDYFILE 中的 $PROGRAM_NAME import 标记不完整或已被修改，请先手动修复"
            ;;
    esac

    begin_transaction "$site_path"
    rm -f -- "$site_path"
    validate_and_reload_or_rollback

    echo "已删除反向代理：$host"
    echo "已删除配置：$site_path"
}

show_file_status() {
    local path="$1"
    local expected_mode="${2:-}"
    local expected_owner="${3:-}"
    local mode
    local owner

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf "  [缺失] %s\n" "$path"
        return
    fi

    mode="$(stat -c '%a' "$path" 2>/dev/null || echo "?")"
    owner="$(stat -c '%U:%G' "$path" 2>/dev/null || echo "?")"

    if [[ -L "$path" ]]; then
        printf "  [警告] %s 是符号链接\n" "$path"
    elif [[ -n "$expected_mode" && "$mode" != "$expected_mode" ]] ||
        [[ -n "$expected_owner" && "$owner" != "$expected_owner" ]]; then
        printf "  [警告] %s，所有者 %s，权限 %s（建议 %s / %s）\n" \
            "$path" "$owner" "$mode" \
            "${expected_owner:-保持不变}" "${expected_mode:-保持不变}"
    else
        printf "  [正常] %s，所有者 %s，权限 %s\n" "$path" "$owner" "$mode"
    fi
}

metadata_value() {
    local path="$1"
    local key="$2"

    awk -v prefix="# crp-$key: " '
        index($0, prefix) == 1 {
            print substr($0, length(prefix) + 1)
            exit
        }
    ' "$path" 2>/dev/null
}

print_add_command() {
    local host="$1"
    local upstream="$2"
    local mode="$3"
    local tls_mode="$4"
    local allow_list="$5"
    local deny_list="$6"
    local quoted

    printf 'crp add'

    printf -v quoted '%q' "$host"
    printf ' %s' "$quoted"
    printf -v quoted '%q' "$upstream"
    printf ' %s' "$quoted"

    case "$mode" in
        http)
            printf ' --http'
            ;;
        https)
            printf ' --https'
            if [[ "$tls_mode" == "internal" ||
                "$tls_mode" == "automatic" ]]; then
                printf ' --tls %s' "$tls_mode"
            fi
            ;;
    esac

    if [[ -n "$allow_list" && "$allow_list" != "-" ]]; then
        printf -v quoted '%q' "$allow_list"
        printf ' --allow %s' "$quoted"
    fi

    if [[ -n "$deny_list" && "$deny_list" != "-" ]]; then
        printf -v quoted '%q' "$deny_list"
        printf ' --deny %s' "$quoted"
    fi

    printf '\n'
}

command_access_list() {
    local list_type="$1"
    shift

    [[ $# -eq 3 ]] ||
        die "用法：crp $list_type add|remove <域名或IP> <IP或CIDR列表>"

    local action="$1"
    local host="$2"
    local requested_list="$3"
    local site_path
    local configured_host
    local mode
    local upstream
    local tls_mode
    local allow_metadata
    local deny_metadata
    local before_value
    local after_value
    local current_range
    local requested_range
    local -a allow_ranges=()
    local -a deny_ranges=()
    local -a requested_ranges=()
    local -a retained_ranges=()

    case "$action" in
        add)
            ;;
        remove|delete|rm)
            action="remove"
            ;;
        *)
            die "未知 $list_type 操作：$action。支持 add 或 remove"
            ;;
    esac

    host="$(normalize_frontend_host "$host")"
    append_ip_list "$requested_list" requested_ranges
    site_path="$(site_config_path "$host")"

    ensure_config_environment

    [[ -e "$site_path" || -L "$site_path" ]] ||
        die "没有找到由 $PROGRAM_NAME 管理的代理：$host"
    validate_managed_site_file "$site_path" "$host"

    case "$(import_block_state)" in
        absent)
            die "$CADDYFILE 中缺少 $PROGRAM_NAME import 配置，拒绝修改"
            ;;
        malformed)
            die "$CADDYFILE 中的 $PROGRAM_NAME import 标记不完整或已被修改，请先手动修复"
            ;;
    esac

    configured_host="$(metadata_value "$site_path" host)"
    mode="$(metadata_value "$site_path" mode)"
    upstream="$(metadata_value "$site_path" upstream)"
    tls_mode="$(metadata_value "$site_path" tls)"
    allow_metadata="$(metadata_value "$site_path" allow)"
    deny_metadata="$(metadata_value "$site_path" deny)"

    [[ "$configured_host" == "$host" ]] ||
        die "代理配置中的域名元数据无效：$site_path"
    [[ "$mode" == "http" || "$mode" == "https" ]] ||
        die "代理配置中的前端协议元数据无效：$site_path"
    upstream="$(normalize_upstream "$upstream")"

    if [[ "$mode" == "http" ]]; then
        [[ "$tls_mode" == "none" ]] ||
            die "HTTP 代理的 TLS 元数据无效：$site_path"
    else
        [[ "$tls_mode" == "internal" || "$tls_mode" == "automatic" ]] ||
            die "HTTPS 代理的 TLS 元数据无效：$site_path"
    fi

    if [[ -n "$allow_metadata" && "$allow_metadata" != "-" ]]; then
        append_ip_list "$allow_metadata" allow_ranges
    elif [[ "$allow_metadata" != "-" ]]; then
        die "代理配置中的允许列表元数据无效：$site_path"
    fi

    if [[ -n "$deny_metadata" && "$deny_metadata" != "-" ]]; then
        append_ip_list "$deny_metadata" deny_ranges
    elif [[ "$deny_metadata" != "-" ]]; then
        die "代理配置中的拒绝列表元数据无效：$site_path"
    fi

    if [[ "$list_type" == "allow" ]]; then
        before_value="$(join_by_comma "${allow_ranges[@]:-}")"

        if [[ "$action" == "add" ]]; then
            for requested_range in "${requested_ranges[@]}"; do
                if ! array_contains "$requested_range" "${allow_ranges[@]:-}"; then
                    allow_ranges+=("$requested_range")
                fi
            done
        else
            for current_range in "${allow_ranges[@]}"; do
                if array_contains "$current_range" "${requested_ranges[@]}"; then
                    :
                else
                    retained_ranges+=("$current_range")
                fi
            done
            allow_ranges=("${retained_ranges[@]}")
        fi

        after_value="$(join_by_comma "${allow_ranges[@]:-}")"
    else
        before_value="$(join_by_comma "${deny_ranges[@]:-}")"

        if [[ "$action" == "add" ]]; then
            for requested_range in "${requested_ranges[@]}"; do
                if ! array_contains "$requested_range" "${deny_ranges[@]:-}"; then
                    deny_ranges+=("$requested_range")
                fi
            done
        else
            for current_range in "${deny_ranges[@]}"; do
                if array_contains "$current_range" "${requested_ranges[@]}"; then
                    :
                else
                    retained_ranges+=("$current_range")
                fi
            done
            deny_ranges=("${retained_ranges[@]}")
        fi

        after_value="$(join_by_comma "${deny_ranges[@]:-}")"
    fi

    if [[ "$before_value" == "$after_value" ]]; then
        echo "$list_type 列表没有变化：$host"
        echo "当前配置："
        printf '  '
        print_add_command \
            "$host" "$upstream" "$mode" "$tls_mode" \
            "$(join_by_comma "${allow_ranges[@]:-}")" \
            "$(join_by_comma "${deny_ranges[@]:-}")"
        return
    fi

    begin_transaction "$site_path"
    write_site_config \
        "$site_path" "$host" "$upstream" "$mode" "$tls_mode" \
        allow_ranges deny_ranges
    validate_and_reload_or_rollback

    echo "$list_type 列表已更新：$host"
    echo "当前配置："
    printf '  '
    print_add_command \
        "$host" "$upstream" "$mode" "$tls_mode" \
        "$(join_by_comma "${allow_ranges[@]:-}")" \
        "$(join_by_comma "${deny_ranges[@]:-}")"
}

show_managed_sites() {
    local found=0
    local path
    local host
    local mode
    local upstream
    local tls_mode
    local allow_list
    local deny_list

    if [[ ! -d "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        echo "  暂无配置"
        return
    fi

    while IFS= read -r -d '' path; do
        found=1

        if [[ -L "$path" || ! -f "$path" ]]; then
            echo "  [警告] 非普通配置文件：$path"
            continue
        fi

        if ! grep -Fxq -- "$MANAGED_HEADER" "$path" 2>/dev/null; then
            echo "  [跳过] 非本工具管理：$path"
            continue
        fi

        host="$(metadata_value "$path" host)"
        mode="$(metadata_value "$path" mode)"
        upstream="$(metadata_value "$path" upstream)"
        tls_mode="$(metadata_value "$path" tls)"
        allow_list="$(metadata_value "$path" allow)"
        deny_list="$(metadata_value "$path" deny)"

        echo "    目标：${mode:-未知}://${host:-未知}"
        echo "    上游：${upstream:-未知}"
        if [[ "$mode" == "https" ]]; then
            echo "    TLS：${tls_mode:-未知}"
        fi
        if [[ -n "$allow_list" && "$allow_list" != "-" ]]; then
            echo "    允许：$allow_list"
        else
            echo "    允许：全部客户端"
        fi
        if [[ -n "$deny_list" && "$deny_list" != "-" ]]; then
            echo "    拒绝：$deny_list"
        else
            echo "    拒绝：无"
        fi
        echo "    文件：$path"
        printf '    '
        print_add_command \
            "$host" "$upstream" "$mode" "$tls_mode" \
            "$allow_list" "$deny_list"
        echo
    done < <(
        find "$CONFIG_DIR" -maxdepth 1 -name '*.caddy' -print0 2>/dev/null |
            sort -z
    )

    if [[ $found -eq 0 ]]; then
        echo "  暂无配置"
    fi

    return 0
}

command_status() {
    local dependency
    local import_state="unavailable"
    local validation_output=""

    echo "$PROGRAM_NAME 状态"
    echo

    echo "脚本："
    if [[ -x "$INSTALL_PATH" ]]; then
        echo "  [正常] 已安装：$INSTALL_PATH"
    else
        echo "  [未安装] $INSTALL_PATH"
    fi

    if [[ -L "$ALIAS_PATH" &&
        "$(readlink -- "$ALIAS_PATH" 2>/dev/null)" == "$INSTALL_PATH" ]]; then
        echo "  [正常] 短命令：$ALIAS_PATH -> $INSTALL_PATH"
    elif [[ -e "$ALIAS_PATH" || -L "$ALIAS_PATH" ]]; then
        echo "  [警告] 短命令路径已被占用：$ALIAS_PATH"
    else
        echo "  [未安装] $ALIAS_PATH"
    fi

    echo
    echo "依赖："
    for dependency in caddy systemctl flock; do
        if command_is_available "$dependency"; then
            echo "  [正常] $dependency 已安装"
        else
            echo "  [缺失] $dependency"
        fi
    done

    echo
    echo "Caddy 服务："
    if ! command_is_available systemctl; then
        echo "  [跳过] 未安装 systemctl"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        echo "  [正常] caddy.service 正在运行"
    else
        echo "  [停止] caddy.service 未运行"
    fi

    if command_is_available systemctl; then
        if systemctl is-enabled --quiet caddy 2>/dev/null; then
            echo "  [正常] caddy.service 已启用开机启动"
        else
            echo "  [警告] caddy.service 未启用开机启动"
        fi
    fi

    echo
    echo "配置："
    show_file_status "$CADDYFILE" "644" "root:root"

    if [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]]; then
        show_file_status "$CONFIG_DIR" "755" "root:root"
    elif [[ -L "$CONFIG_DIR" ]]; then
        echo "  [警告] $CONFIG_DIR 是符号链接"
    else
        echo "  [缺失] $CONFIG_DIR"
    fi

    if [[ -f "$CADDYFILE" && ! -L "$CADDYFILE" ]]; then
        import_state="$(import_block_state)"
        case "$import_state" in
            present)
                echo "  [正常] 已导入：$IMPORT_LINE"
                ;;
            absent)
                echo "  [未配置] 尚未加入反向代理 import"
                ;;
            malformed)
                echo "  [警告] import 标记不完整或内容已被修改"
                ;;
        esac
    fi

    if ! command_is_available caddy; then
        echo "  [跳过] 未安装 caddy，无法校验配置"
    elif [[ ! -f "$CADDYFILE" || -L "$CADDYFILE" ]]; then
        echo "  [跳过] Caddyfile 不存在或是符号链接"
    elif validation_output="$(
        caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1
    )"; then
        echo "  [正常] Caddy 配置校验通过"
    else
        validation_output="${validation_output//$'\n'/ }"
        echo "  [失败] Caddy 配置校验失败：$validation_output"
    fi

    echo
    echo "当前托管代理："
    show_managed_sites
}

main() {
    local command="${1:-}"

    case "$command" in
        "")
            show_short_help
            ;;

        -h|--help)
            show_short_help
            ;;

        help)
            [[ $# -eq 1 ]] || die "help 不接受参数"
            show_help
            ;;

        install)
            [[ $# -eq 1 ]] || die "install 不接受参数"
            require_root "$@"
            command_install
            ;;

        add|set)
            require_root "$@"
            acquire_lock
            shift
            command_add "$@"
            ;;

        allow|deny)
            require_root "$@"
            acquire_lock
            local list_type="$command"
            shift
            command_access_list "$list_type" "$@"
            ;;

        remove|delete|rm)
            require_root "$@"
            acquire_lock
            shift
            command_remove "$@"
            ;;

        status|show)
            [[ $# -eq 1 ]] || die "$command 不接受参数"
            command_status
            ;;

        *)
            die "未知命令：$command。运行 crp help 查看完整帮助"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
