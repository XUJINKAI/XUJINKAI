#!/usr/bin/env bash
# nas-mount - 管理 Debian/PVE VM 中的 NAS SMB 挂载

set -euo pipefail

INSTALL_PATH="/usr/local/bin/nas-mount"
CONFIG_DIR="/etc/nas-mount"
CONFIG_FILE="$CONFIG_DIR/config"
CREDENTIALS_FILE="$CONFIG_DIR/credentials"
FSTAB_FILE="/etc/fstab"
LOCK_FILE="/run/lock/nas-mount.lock"

DEFAULT_NAS_HOST=""
DEFAULT_NAS_BASE="/mnt/nas"
DEFAULT_SMB_VERSION="3.0"

FSTAB_BEGIN="# BEGIN nas-mount:"
FSTAB_END="# END nas-mount:"
FSTAB_TEMPORARY_FILE=""

cleanup() {
    if [[ -n "${FSTAB_TEMPORARY_FILE:-}" ]]; then
        rm -f -- "$FSTAB_TEMPORARY_FILE" || true
    fi
}

trap cleanup EXIT

show_short_help() {
    cat <<'EOF'
nas-mount - NAS SMB 挂载管理工具

常用命令：
  nas-mount install
  nas-mount config init
  nas-mount mount <remote> [<local-folder-name>]
  nas-mount unmount <local-folder-name>
  nas-mount status

运行 nas-mount help 查看完整帮助。
EOF
}

show_help() {
    cat <<'EOF'
nas-mount - 管理 PVE VM 中的 NAS SMB 挂载

用法：
  nas-mount install
  nas-mount config init
  nas-mount mount <remote> [<local-folder-name>]
  nas-mount unmount <local-folder-name>
  nas-mount status
  nas-mount help

命令：

  install
      将当前脚本安装到：

        /usr/local/bin/nas-mount

      安装后可以直接运行：

        nas-mount status


  config init
      初始化配置文件、凭据文件和默认挂载目录。

      创建：

        /etc/nas-mount/config
        /etc/nas-mount/credentials
        /mnt/nas/

      初始化完成后，需要手动修改：

        /etc/nas-mount/config
        /etc/nas-mount/credentials


  mount <remote> [<local-folder-name>]
      挂载 NAS SMB 共享，并写入 /etc/fstab。

      remote：
        NAS 上的共享名称或共享内的子目录路径。
        路径的第一段是 SMB 共享名，后续部分是共享内的子目录。
        可以带或不带开头的斜杠，例如：

          backup/share
          /backup/share

      local-folder-name：
        本地挂载目录名称，实际位置为：

          /mnt/nas/<local-folder-name>

        未指定时，默认使用 remote 路径的最后一段作为本地目录名称。

      示例：

        nas-mount mount backup
        nas-mount mount backup/share
        nas-mount mount /backup/share

      对应挂载：

        //192.0.2.10/backup       -> /mnt/nas/backup
        //192.0.2.10/backup/share -> /mnt/nas/share


  unmount <local-folder-name>
      卸载指定目录，并删除对应的 /etc/fstab 配置。

      示例：

        nas-mount unmount backup
        nas-mount unmount media

      此命令不会删除 NAS 中的任何文件。


  status
      显示：

        - nas-mount 是否已安装
        - 配置文件是否存在
        - 凭据文件是否存在
        - 凭据文件权限
        - mount.cifs 是否已安装
        - NAS 地址是否可访问
        - NAS SMB 445 端口是否可访问
        - /mnt/nas 下的本地目录
        - 当前已经挂载的 NAS 共享
        - /etc/fstab 中由 nas-mount 管理的配置


  help
      显示本完整帮助。


文件：

  /usr/local/bin/nas-mount
      安装后的脚本。

  /etc/nas-mount/config
      普通配置文件。

  /etc/nas-mount/credentials
      SMB 用户名和密码，仅允许 root 读取。

  /mnt/nas/
      默认挂载根目录。

  /mnt/nas/<local-folder-name>
      各共享的本地挂载目录。

  /etc/fstab
      开机自动挂载配置。
      nas-mount 写入的项目带有 BEGIN/END 注释标记。


配置文件示例：

  /etc/nas-mount/config

    NAS_HOST="192.0.2.10"
    NAS_BASE="/mnt/nas"
    SMB_VERSION="3.0"

  /etc/nas-mount/credentials

    username=<NAS用户名>
    password=<NAS密码>


权限：

  以下命令需要 root 权限：

    nas-mount install
    nas-mount config init
    nas-mount mount ...
    nas-mount unmount ...

  普通用户运行时，脚本会自动调用 sudo。

  以下命令不需要 root 权限：

    nas-mount
    nas-mount -h
    nas-mount --help
    nas-mount help
    nas-mount status


说明：

  - mount 会自动创建本地挂载目录。
  - mount 会立即挂载并配置开机自动挂载。
  - 重复执行相同命令不会重复写入 /etc/fstab。
  - unmount 会卸载并删除对应的自动挂载配置。
  - credentials 文件权限自动设置为 600。
  - 默认使用 nofail、_netdev 和 x-systemd.automount。
  - NAS 离线时不会阻塞 VM 正常启动。
EOF
}

die() {
    echo "错误：$*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

command_is_available() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        [[ -x "/usr/sbin/$command_name" ]] ||
        [[ -x "/sbin/$command_name" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 ||
            die "当前命令需要 root 权限，但系统中未安装 sudo"

        local script_path
        script_path="$(readlink -f -- "$0")" ||
            die "无法确定当前脚本路径：$0"

        exec sudo -- /bin/bash "$script_path" "$@"
    fi
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 ||
        die "缺少 flock 命令，请安装 util-linux"

    mkdir -p -- "$(dirname -- "$LOCK_FILE")"
    exec 9>>"$LOCK_FILE"
    flock -x 9
}

validate_name() {
    local value="$1"
    local label="$2"

    [[ -n "$value" ]] || die "$label 不能为空"

    if [[ "$value" =~ [[:space:][:cntrl:]/\\] ]]; then
        die "$label 不能包含空白字符、控制字符、斜杠或反斜杠：$value"
    fi

    if [[ "$value" == "." || "$value" == ".." ]]; then
        die "$label 无效：$value"
    fi
}

normalize_remote_path() {
    local remote_path="$1"

    while [[ "$remote_path" == /* ]]; do
        remote_path="${remote_path#/}"
    done

    printf '%s' "$remote_path"
}

validate_remote_path() {
    local remote_path="$1"

    [[ -n "$remote_path" ]] || die "远程路径不能为空"

    if [[ "$remote_path" =~ [[:space:][:cntrl:]\\,] ]]; then
        die "远程路径不能包含空白字符、控制字符、反斜杠或逗号：$remote_path"
    fi

    if [[ "$remote_path" == */ || "$remote_path" == *"//"* ]]; then
        die "远程路径不能以斜杠结尾或包含空路径段：$remote_path"
    fi

    local segment
    local -a segments
    IFS='/' read -r -a segments <<<"$remote_path"

    for segment in "${segments[@]}"; do
        if [[ -z "$segment" || "$segment" == "." || "$segment" == ".." ]]; then
            die "远程路径包含无效路径段：$remote_path"
        fi
    done
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

config_file_is_safe() {
    [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] &&
        path_is_root_owned_and_not_writable "$CONFIG_FILE"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] ||
        die "配置文件不存在，请先运行：nas-mount config init"

    config_file_is_safe ||
        die "配置文件必须是 root 所有的普通文件，且不能允许组或其他用户写入：$CONFIG_FILE"

    NAS_HOST=""
    NAS_BASE=""
    SMB_VERSION=""

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

normalize_and_validate_nas_base() {
    while [[ "$NAS_BASE" == */ && "$NAS_BASE" != "/" ]]; do
        NAS_BASE="${NAS_BASE%/}"
    done

    [[ "$NAS_BASE" == /* && "$NAS_BASE" != "/" ]] ||
        die "NAS_BASE 必须是非根目录的绝对路径：$NAS_BASE"

    if [[ "$NAS_BASE" =~ [[:space:][:cntrl:]\\] ]]; then
        die "NAS_BASE 不能包含空白字符、控制字符或反斜杠：$NAS_BASE"
    fi

    if [[ "$NAS_BASE" == *"/../"* || "$NAS_BASE" == */.. ||
        "$NAS_BASE" == *"/./"* || "$NAS_BASE" == */. ]]; then
        die "NAS_BASE 不能包含 . 或 .. 路径段：$NAS_BASE"
    fi
}

validate_mount_config() {
    [[ -n "$NAS_HOST" ]] || die "配置文件中缺少 NAS_HOST"
    [[ -n "$NAS_BASE" ]] || die "配置文件中缺少 NAS_BASE"
    [[ -n "$SMB_VERSION" ]] || die "配置文件中缺少 SMB_VERSION"

    [[ "$NAS_HOST" =~ ^[A-Za-z0-9._-]+$ && "$NAS_HOST" != -* ]] ||
        die "NAS_HOST 只能包含字母、数字、点、下划线和连字符：$NAS_HOST"

    normalize_and_validate_nas_base

    [[ "$SMB_VERSION" =~ ^(default|[0-9]+(\.[0-9]+){0,2})$ ]] ||
        die "SMB_VERSION 格式无效：$SMB_VERSION"

    [[ -f "$CREDENTIALS_FILE" && ! -L "$CREDENTIALS_FILE" ]] ||
        die "凭据文件不存在：$CREDENTIALS_FILE"

    [[ "$(stat -c '%u' "$CREDENTIALS_FILE" 2>/dev/null)" == "0" ]] ||
        die "凭据文件必须属于 root：$CREDENTIALS_FILE"

    chmod 600 -- "$CREDENTIALS_FILE"

    grep -q '^username=.' "$CREDENTIALS_FILE" ||
        die "凭据文件中的 username 不能为空：$CREDENTIALS_FILE"
    grep -q '^password=.' "$CREDENTIALS_FILE" ||
        die "凭据文件中的 password 不能为空：$CREDENTIALS_FILE"
}

command_install() {
    local source_path
    source_path="$(readlink -f "$0")"

    if [[ "$source_path" == "$INSTALL_PATH" ]]; then
        chmod 755 "$INSTALL_PATH"
        echo "nas-mount 已经安装在：$INSTALL_PATH"
        return
    fi

    install -m 755 "$source_path" "$INSTALL_PATH"

    echo "安装完成：$INSTALL_PATH"
    echo
    echo "下一步运行："
    echo "  nas-mount config init"
}

command_config_init() {
    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] ||
            die "配置目录必须是普通目录且不能是符号链接：$CONFIG_DIR"
        path_is_root_owned_and_not_writable "$CONFIG_DIR" ||
            die "现有配置目录必须属于 root，且不能允许组或其他用户写入：$CONFIG_DIR"
    fi

    install -d -m 755 -o root -g root -- "$CONFIG_DIR"

    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        config_file_is_safe ||
            die "现有配置文件必须属于 root、不可被其他用户写入，且不能是符号链接：$CONFIG_FILE"
    fi

    if [[ -e "$CREDENTIALS_FILE" || -L "$CREDENTIALS_FILE" ]]; then
        [[ -f "$CREDENTIALS_FILE" && ! -L "$CREDENTIALS_FILE" ]] ||
            die "凭据文件必须是普通文件且不能是符号链接：$CREDENTIALS_FILE"
        [[ "$(stat -c '%u' "$CREDENTIALS_FILE" 2>/dev/null)" == "0" ]] ||
            die "现有凭据文件必须属于 root：$CREDENTIALS_FILE"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat >"$CONFIG_FILE" <<EOF
# NAS 地址或主机名
NAS_HOST="$DEFAULT_NAS_HOST"

# 本地挂载根目录
NAS_BASE="$DEFAULT_NAS_BASE"

# SMB 协议版本
SMB_VERSION="$DEFAULT_SMB_VERSION"
EOF
        info "已创建 $CONFIG_FILE"
    else
        info "$CONFIG_FILE 已存在，跳过"
    fi
    chown root:root -- "$CONFIG_FILE"
    chmod 644 -- "$CONFIG_FILE"

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        cat >"$CREDENTIALS_FILE" <<'EOF'
username=
password=
EOF
        info "已创建 $CREDENTIALS_FILE"
    else
        info "$CREDENTIALS_FILE 已存在，跳过"
    fi
    chown root:root -- "$CREDENTIALS_FILE"
    chmod 600 -- "$CREDENTIALS_FILE"

    load_config
    [[ -n "$NAS_BASE" ]] || die "配置文件中缺少 NAS_BASE"
    normalize_and_validate_nas_base

    mkdir -p -- "$NAS_BASE"

    echo
    echo "初始化完成。"
    echo
    echo "请修改："
    echo "  sudo nano $CONFIG_FILE"
    echo "  sudo nano $CREDENTIALS_FILE"
}

fstab_block_exists() {
    local local_name="$1"

    grep -Fxq -- "$FSTAB_BEGIN$local_name" "$FSTAB_FILE" 2>/dev/null ||
        grep -Fxq -- "$FSTAB_END$local_name" "$FSTAB_FILE" 2>/dev/null
}

validate_fstab_block() {
    local local_name="$1"

    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] ||
        die "$FSTAB_FILE 必须是普通文件且不能是符号链接"

    awk \
        -v begin="$FSTAB_BEGIN$local_name" \
        -v end="$FSTAB_END$local_name" '
        $0 == begin {
            if (opened) {
                invalid = 1
            }
            opened = 1
            next
        }

        $0 == end {
            if (!opened) {
                invalid = 1
            }
            opened = 0
        }

        END {
            if (opened || invalid) {
                exit 1
            }
        }
    ' "$FSTAB_FILE" ||
        die "$FSTAB_FILE 中 $local_name 的 BEGIN/END 标记不完整"
}

rewrite_fstab_block() {
    local local_name="$1"
    local new_entry="${2:-}"

    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] ||
        die "$FSTAB_FILE 必须是普通文件且不能是符号链接"

    FSTAB_TEMPORARY_FILE="$(mktemp "$FSTAB_FILE.nas-mount.XXXXXX")" ||
        die "无法在 /etc 中创建临时文件"

    if ! awk \
        -v begin="$FSTAB_BEGIN$local_name" \
        -v end="$FSTAB_END$local_name" '
        $0 == begin {
            if (skipping) {
                invalid = 1
            }
            skipping = 1
            next
        }

        $0 == end {
            if (!skipping) {
                invalid = 1
            }
            skipping = 0
            next
        }

        !skipping {
            print
        }

        END {
            if (skipping || invalid) {
                exit 42
            }
        }
    ' "$FSTAB_FILE" >"$FSTAB_TEMPORARY_FILE"; then
        die "$FSTAB_FILE 中 $local_name 的 BEGIN/END 标记不完整，已停止修改"
    fi

    if [[ -n "$new_entry" ]]; then
        printf '\n%s%s\n%s\n%s%s\n' \
            "$FSTAB_BEGIN" "$local_name" \
            "$new_entry" \
            "$FSTAB_END" "$local_name" \
            >>"$FSTAB_TEMPORARY_FILE"
    fi

    chown --reference="$FSTAB_FILE" -- "$FSTAB_TEMPORARY_FILE"
    chmod --reference="$FSTAB_FILE" -- "$FSTAB_TEMPORARY_FILE"
    mv -f -- "$FSTAB_TEMPORARY_FILE" "$FSTAB_FILE"
    FSTAB_TEMPORARY_FILE=""
}

is_mounted_exactly() {
    findmnt --mountpoint "$1" --noheadings >/dev/null 2>&1
}

stop_systemd_mount_units() {
    local mount_point="$1"

    command -v systemctl >/dev/null 2>&1 || return 0
    command -v systemd-escape >/dev/null 2>&1 || return 0

    local mount_unit
    local automount_unit
    mount_unit="$(systemd-escape --path --suffix=mount "$mount_point")" ||
        return 0
    automount_unit="$(systemd-escape --path --suffix=automount "$mount_point")" ||
        return 0

    systemctl stop "$automount_unit" 2>/dev/null || true
    systemctl stop "$mount_unit" 2>/dev/null || true
}

fstab_target_has_unmanaged_entry() {
    local mount_point="$1"
    local local_name="$2"

    awk \
        -v target="$mount_point" \
        -v begin="$FSTAB_BEGIN$local_name" \
        -v end="$FSTAB_END$local_name" '
        $0 == begin {
            managed = 1
            next
        }

        $0 == end {
            managed = 0
            next
        }

        !managed && $0 !~ /^[[:space:]]*#/ &&
            NF >= 2 && $2 == target {
            found = 1
        }

        END {
            exit found ? 0 : 1
        }
    ' "$FSTAB_FILE" 2>/dev/null
}

managed_source_for_target() {
    local mount_point="$1"

    [[ -r "$FSTAB_FILE" ]] || return 0

    awk -v target="$mount_point" '
        /^# BEGIN nas-mount:/ {
            managed = 1
            next
        }

        /^# END nas-mount:/ {
            managed = 0
            next
        }

        managed && NF >= 3 && $2 == target && $3 == "cifs" {
            print $1
            exit
        }
    ' "$FSTAB_FILE" 2>/dev/null || true
}

command_mount() {
    local remote="${1:-}"
    local local_name="${2:-}"

    [[ -n "$remote" ]] ||
        die "用法：nas-mount mount <remote> [<local-folder-name>]"

    [[ $# -le 2 ]] ||
        die "mount 参数过多"

    remote="$(normalize_remote_path "$remote")"
    validate_remote_path "$remote"

    if [[ -z "$local_name" ]]; then
        local_name="${remote##*/}"
    fi

    validate_name "$local_name" "本地目录名"

    load_config
    validate_mount_config

    command_is_available mount.cifs ||
        die "未安装 mount.cifs，请运行：sudo apt install -y cifs-utils"

    local remote_path="//$NAS_HOST/$remote"
    local mount_point="$NAS_BASE/$local_name"
    local mount_options
    local fstab_entry
    local has_managed_block=0

    mount_options="credentials=$CREDENTIALS_FILE"
    mount_options+=",vers=$SMB_VERSION"
    mount_options+=",iocharset=utf8"
    mount_options+=",rw"
    mount_options+=",nofail"
    mount_options+=",_netdev"
    mount_options+=",x-systemd.automount"
    mount_options+=",x-systemd.idle-timeout=60"
    mount_options+=",x-systemd.device-timeout=10s"

    fstab_entry="$remote_path $mount_point cifs $mount_options 0 0"

    [[ ! -L "$mount_point" ]] ||
        die "挂载点不能是符号链接：$mount_point"
    mkdir -p -- "$mount_point"

    if fstab_block_exists "$local_name"; then
        has_managed_block=1
        validate_fstab_block "$local_name"
    fi

    if fstab_target_has_unmanaged_entry "$mount_point" "$local_name"; then
        die "$FSTAB_FILE 中已有其他配置使用该挂载点：$mount_point"
    fi

    if is_mounted_exactly "$mount_point"; then
        if [[ $has_managed_block -eq 0 ]]; then
            die "挂载点已被非 nas-mount 挂载占用，拒绝自动卸载：$mount_point"
        fi

        info "正在卸载现有挂载：$mount_point"
        stop_systemd_mount_units "$mount_point"

        if is_mounted_exactly "$mount_point"; then
            umount -- "$mount_point" ||
                die "卸载现有挂载失败，目录可能正在使用：$mount_point"
        fi

        if is_mounted_exactly "$mount_point"; then
            die "挂载点卸载后仍被占用：$mount_point"
        fi
    fi

    if [[ $has_managed_block -eq 1 ]]; then
        info "正在更新现有配置：$local_name"
    fi

    rewrite_fstab_block "$local_name" "$fstab_entry"

    systemctl daemon-reload 2>/dev/null || true

    if mount -- "$mount_point"; then
        echo "挂载完成：$remote_path -> $mount_point"
    else
        die "挂载失败，配置已保留在 $FSTAB_FILE"
    fi
}

command_unmount() {
    local local_name="${1:-}"

    [[ -n "$local_name" ]] ||
        die "用法：nas-mount unmount <local-folder-name>"

    [[ $# -eq 1 ]] ||
        die "unmount 只能指定一个本地目录名"

    validate_name "$local_name" "本地目录名"
    load_config
    [[ -n "$NAS_BASE" ]] || die "配置文件中缺少 NAS_BASE"
    normalize_and_validate_nas_base

    local mount_point="$NAS_BASE/$local_name"
    local has_managed_block=0

    if fstab_block_exists "$local_name"; then
        has_managed_block=1
        validate_fstab_block "$local_name"
    fi

    [[ ! -L "$mount_point" ]] ||
        die "挂载点不能是符号链接：$mount_point"

    if is_mounted_exactly "$mount_point"; then
        if [[ $has_managed_block -eq 0 ]]; then
            die "挂载点不属于 nas-mount 管理，拒绝自动卸载：$mount_point"
        fi

        info "正在卸载：$mount_point"
        stop_systemd_mount_units "$mount_point"

        if is_mounted_exactly "$mount_point"; then
            umount -- "$mount_point" ||
                die "卸载失败，目录可能正在使用：$mount_point"
        fi

        if is_mounted_exactly "$mount_point"; then
            die "卸载后挂载点仍被占用：$mount_point"
        fi
    else
        info "当前未挂载：$mount_point"
    fi

    if [[ $has_managed_block -eq 1 ]]; then
        rewrite_fstab_block "$local_name"
        info "已删除 $FSTAB_FILE 配置"
    else
        info "$FSTAB_FILE 中没有对应配置"
    fi

    systemctl daemon-reload 2>/dev/null || true

    if [[ -d "$mount_point" && ! -L "$mount_point" ]]; then
        if rmdir -- "$mount_point" 2>/dev/null; then
            info "已删除空目录：$mount_point"
        else
            info "本地目录非空，保留：$mount_point"
        fi
    fi
}

show_file_status() {
    local file="$1"
    local expected_mode="${2:-}"
    local expected_owner="${3:-}"

    if [[ ! -e "$file" && ! -L "$file" ]]; then
        printf "  [缺失] %s\n" "$file"
        return
    fi

    local mode
    local owner
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo "?")"
    owner="$(stat -c '%U:%G' "$file" 2>/dev/null || echo "?")"

    if [[ -L "$file" ]]; then
        printf "  [警告] %s 是符号链接\n" "$file"
    elif [[ -n "$expected_mode" && "$mode" != "$expected_mode" ]] ||
        [[ -n "$expected_owner" && "$owner" != "$expected_owner" ]]; then
        printf "  [警告] %s，所有者 %s，权限 %s（建议 %s / %s）\n" \
            "$file" "$owner" "$mode" \
            "${expected_owner:-保持不变}" "${expected_mode:-保持不变}"
    else
        printf "  [正常] %s，所有者 %s，权限 %s\n" "$file" "$owner" "$mode"
    fi
}

command_status() {
    local nas_host="$DEFAULT_NAS_HOST"
    local nas_base="$DEFAULT_NAS_BASE"
    local smb_version="$DEFAULT_SMB_VERSION"
    local config_warning=""

    if [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
        if ! config_file_is_safe; then
            config_warning="配置文件所有者或权限不安全，未加载"
        else
            NAS_HOST=""
            NAS_BASE=""
            SMB_VERSION=""

            # shellcheck disable=SC1090
            source "$CONFIG_FILE"

            nas_host="${NAS_HOST:-$nas_host}"
            nas_base="${NAS_BASE:-$nas_base}"
            smb_version="${SMB_VERSION:-$smb_version}"
        fi
    elif [[ -L "$CONFIG_FILE" ]]; then
        config_warning="配置文件是符号链接，未加载"
    fi

    while [[ "$nas_base" == */ && "$nas_base" != "/" ]]; do
        nas_base="${nas_base%/}"
    done

    if [[ -n "$nas_host" &&
        ( ! "$nas_host" =~ ^[A-Za-z0-9._-]+$ || "$nas_host" == -* ) ]]; then
        config_warning="${config_warning:+$config_warning；}NAS_HOST 格式无效"
        nas_host=""
    fi

    if [[ "$nas_base" != /* || "$nas_base" == "/" ||
        "$nas_base" =~ [[:space:][:cntrl:]\\] ||
        "$nas_base" == *"/../"* || "$nas_base" == */.. ||
        "$nas_base" == *"/./"* || "$nas_base" == */. ]]; then
        config_warning="${config_warning:+$config_warning；}NAS_BASE 格式无效，状态检查使用默认目录"
        nas_base="$DEFAULT_NAS_BASE"
    fi

    if [[ ! "$smb_version" =~ ^(default|[0-9]+(\.[0-9]+){0,2})$ ]]; then
        config_warning="${config_warning:+$config_warning；}SMB_VERSION 格式无效"
    fi

    echo "nas-mount 状态"
    echo

    echo "脚本："
    if [[ -x "$INSTALL_PATH" ]]; then
        echo "  [正常] 已安装：$INSTALL_PATH"
    else
        echo "  [未安装] $INSTALL_PATH"
    fi

    echo
    echo "配置文件："
    show_file_status "$CONFIG_FILE" "644" "root:root"
    show_file_status "$CREDENTIALS_FILE" "600" "root:root"
    if [[ -n "$config_warning" ]]; then
        echo "  [警告] $config_warning"
    fi

    echo
    echo "当前配置："
    echo "  NAS_HOST=$nas_host"
    echo "  NAS_BASE=$nas_base"
    echo "  SMB_VERSION=$smb_version"

    echo
    echo "依赖："
    local dependency
    for dependency in mount.cifs findmnt flock systemctl systemd-escape; do
        if command_is_available "$dependency"; then
            echo "  [正常] $dependency 已安装"
        else
            echo "  [缺失] $dependency"
        fi
    done

    echo
    echo "网络："
    if [[ -z "$nas_host" ]]; then
        echo "  [跳过] 尚未配置 NAS_HOST"
    elif ! command -v ping >/dev/null 2>&1; then
        echo "  [跳过] 未安装 ping"
    elif ping -c 1 -W 1 "$nas_host" >/dev/null 2>&1; then
        echo "  [正常] NAS 可以 Ping 通：$nas_host"
    else
        echo "  [警告] NAS 无法 Ping 通：$nas_host"
    fi

    if [[ -z "$nas_host" ]]; then
        echo "  [跳过] 尚未检查 SMB 端口"
    elif ! command -v timeout >/dev/null 2>&1; then
        echo "  [跳过] 未安装 timeout，无法检查 SMB 端口"
    elif timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/445' _ "$nas_host" \
            >/dev/null 2>&1; then
        echo "  [正常] SMB 端口 445 可以访问"
    else
        echo "  [失败] SMB 端口 445 无法访问"
    fi

    echo
    echo "本地目录："
    if [[ -d "$nas_base" ]]; then
        echo "  $nas_base"

        local found_directory=0

        while IFS= read -r directory; do
            found_directory=1
            echo "    - $(basename "$directory")"
        done < <(
            find "$nas_base" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                -print 2>/dev/null |
                sort
        )

        if [[ $found_directory -eq 0 ]]; then
            echo "    暂无子目录"
        fi
    else
        echo "  [缺失] $nas_base"
    fi

    echo
    echo "当前挂载："
    local mounted=0
    local source
    local target
    local options
    local configured_source

    while read -r source target options; do
        [[ "$target" == "$nas_base/"* ]] || continue

        mounted=1
        configured_source="$(managed_source_for_target "$target")"

        if [[ -n "$configured_source" && "$configured_source" != "$source" ]]; then
            printf "  %s %s %s [内核报告源：%s]\n" \
                "$configured_source" "$target" "$options" "$source"
        else
            printf "  %s %s %s\n" "$source" "$target" "$options"
        fi
    done < <(
        findmnt \
            --types cifs \
            --output SOURCE,TARGET,OPTIONS \
            --raw \
            --noheadings 2>/dev/null
    )

    if [[ $mounted -eq 0 ]]; then
        echo "  暂无 NAS SMB 挂载"
    fi

    echo
    echo "$FSTAB_FILE 中的 nas-mount 配置："

    if grep -q '^# BEGIN nas-mount:' "$FSTAB_FILE" 2>/dev/null; then
        awk '
            /^# BEGIN nas-mount:/ {
                showing = 1
            }

            showing {
                print "  " $0
            }

            /^# END nas-mount:/ {
                showing = 0
                print ""
            }
        ' "$FSTAB_FILE"
    else
        echo "  暂无配置"
    fi
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

        config)
            case "${2:-}" in
                init)
                    [[ $# -eq 2 ]] || die "config init 不接受额外参数"
                    require_root "$@"
                    acquire_lock
                    command_config_init
                    ;;
                "")
                    die "缺少 config 子命令"
                    ;;
                *)
                    die "未知 config 子命令：${2}"
                    ;;
            esac
            ;;

        mount)
            require_root "$@"
            acquire_lock
            shift
            command_mount "$@"
            ;;

        unmount|umount)
            require_root "$@"
            acquire_lock
            shift
            command_unmount "$@"
            ;;

        status)
            [[ $# -eq 1 ]] || die "status 不接受参数"
            command_status
            ;;

        *)
            die "未知命令：$command。运行 nas-mount help 查看完整帮助。"
            ;;
    esac
}

main "$@"
