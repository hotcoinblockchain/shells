#!/usr/bin/env bash

set -Eeuo pipefail

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
BACKUP_DIR="${BACKUP_DIR:-/etc/ssh/backup}"

BEGIN_MARKER="# BEGIN HOTCOIN SSH HARDENING"
END_MARKER="# END HOTCOIN SSH HARDENING"

LOCK_ROOT_PASSWORD=0
DRY_RUN=0
NO_RELOAD=0
RESET_MODE=0

SSH_SERVICE=""
BACKUP_FILE=""
TEMP_FILE=""
RESET_SOURCE=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_FILE:-}" && -f "$TEMP_FILE" ]]; then
        rm -f "$TEMP_FILE"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage:
  harden_sshd.sh [options]

Options:
  --reset               恢复默认 SSH 配置，不执行加固
  --lock-root-password  SSH 配置成功生效后，锁定 root 本地密码
  --no-reload           只修改并校验配置，不 reload SSH 服务
  --dry-run             只生成、校验并显示差异，不修改系统
  -h, --help            显示帮助

Examples:
  ./harden_sshd.sh --dry-run
  ./harden_sshd.sh
  ./harden_sshd.sh --reset
  ./harden_sshd.sh --lock-root-password
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --reset)
                RESET_MODE=1
                ;;
            --lock-root-password)
                LOCK_ROOT_PASSWORD=1
                ;;
            --no-reload)
                NO_RELOAD=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac

        shift
    done

    if ((RESET_MODE && LOCK_ROOT_PASSWORD)); then
        die "--reset 模式下不能同时使用 --lock-root-password"
    fi
}

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 执行"
}

check_commands() {
    local command_name

    for command_name in sshd systemctl awk grep cmp mktemp flock stat install; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "缺少命令: $command_name"
    done
}

detect_service_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    else
        die "未找到 ssh.service 或 sshd.service"
    fi
}

detect_reset_source() {
    local candidate
    local candidates=(
        "/etc/ssh/sshd_config.dpkg-dist"
        "/etc/ssh/sshd_config.dpkg-old"
        "/etc/ssh/sshd_config.ucf-dist"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            RESET_SOURCE="$candidate"
            return 0
        fi
    done

    die "未找到可恢复的默认 SSH 配置，已检查: ${candidates[*]}"
}

build_config() {
    local source_file="$1"
    local output_file="$2"

    awk \
        -v begin="$BEGIN_MARKER" \
        -v end="$END_MARKER" '
        BEGIN {
            in_managed = 0
            in_match = 0
            inserted = 0
        }

        function is_managed_key(line) {
            return line ~ /^[[:space:]]*(PermitEmptyPasswords|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|PubkeyAuthentication|UsePAM|MaxAuthTries|LoginGraceTime)[[:space:]]+/
        }

        function is_old_disabled_line(line) {
            return line ~ /^[[:space:]]*#[[:space:]]*disabled by HOTCOIN SSH hardening:[[:space:]]*/
        }

        function print_managed_block() {
            print begin
            print "PermitEmptyPasswords no"
            print "PasswordAuthentication no"
            print "KbdInteractiveAuthentication no"
            print "ChallengeResponseAuthentication no"
            print "PermitRootLogin prohibit-password"
            print "PubkeyAuthentication yes"
            print "UsePAM yes"
            print "MaxAuthTries 3"
            print "LoginGraceTime 30"
            print end
            print ""

            inserted = 1
        }

        # 删除旧的托管配置块。
        $0 == begin {
            in_managed = 1
            next
        }

        $0 == end {
            in_managed = 0
            next
        }

        in_managed {
            next
        }

        {
            # 在第一个 Match 块前插入统一配置。
            if (!inserted && $0 ~ /^[[:space:]]*Match[[:space:]]+/) {
                print_managed_block()
            }

            if (!in_match && $0 ~ /^[[:space:]]*Match[[:space:]]+/) {
                in_match = 1
            }

            # 只清理全局区域。
            if (!in_match) {
                # 删除以前脚本产生的 disabled 历史行。
                if (is_old_disabled_line($0)) {
                    next
                }

                # 删除所有已启用的目标配置，包含重复项。
                if (is_managed_key($0)) {
                    next
                }
            }

            print
        }

        END {
            if (!inserted) {
                print ""
                print_managed_block()
            }
        }
    ' "$source_file" > "$output_file"
}

validate_config() {
    local file="$1"

    install -d \
        -o root \
        -g root \
        -m 0755 \
        /run/sshd

    sshd -t -f "$file"
}

show_effective_config() {
    sshd -T -f "$SSHD_CONFIG" 2>/dev/null |
        awk '
            $1 ~ /^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|pubkeyauthentication|maxauthtries|logingracetime|usepam)$/ {
                print
            }
        '
}

lock_root_password() {
    local status

    status="$(
        passwd -S root 2>/dev/null |
            awk '{print $2}' ||
            true
    )"

    case "$status" in
        L|LK)
            log "root 密码已经锁定，跳过"
            ;;
        *)
            passwd -l root
            log "root 密码已锁定"
            ;;
    esac
}

rollback() {
    if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
        return 0
    fi

    log "SSH 服务操作失败，正在恢复配置: $BACKUP_FILE"

    cp -a "$BACKUP_FILE" "$SSHD_CONFIG"

    if ! validate_config "$SSHD_CONFIG"; then
        die "回滚后的 SSH 配置校验失败，请立即人工检查"
    fi

    if ! systemctl restart "$SSH_SERVICE"; then
        die "配置已回滚，但 SSH 服务恢复失败，请立即人工检查"
    fi

    log "原配置已恢复"
}

install_config() {
    local owner
    local group
    local mode

    owner="$(stat -c '%u' "$SSHD_CONFIG")"
    group="$(stat -c '%g' "$SSHD_CONFIG")"
    mode="$(stat -c '%a' "$SSHD_CONFIG")"

    install \
        -o "$owner" \
        -g "$group" \
        -m "$mode" \
        "$TEMP_FILE" \
        "$SSHD_CONFIG"
}

backup_current_config() {
    mkdir -p "$BACKUP_DIR"

    BACKUP_FILE="$BACKUP_DIR/sshd_config.$(
        date '+%F_%H%M%S'
    ).bak"

    cp -a "$SSHD_CONFIG" "$BACKUP_FILE"

    log "原配置已备份到: $BACKUP_FILE"
}

restore_default_config() {
    detect_reset_source

    log "检测到默认 SSH 配置来源: $RESET_SOURCE"

    if cmp -s "$SSHD_CONFIG" "$RESET_SOURCE"; then
        log "当前配置已经与默认配置一致，无需恢复"
        return 0
    fi

    if command -v diff >/dev/null 2>&1; then
        log "配置差异："
        diff -u "$SSHD_CONFIG" "$RESET_SOURCE" || true
    fi

    if ((DRY_RUN)); then
        log "dry-run 完成，未修改任何系统配置"
        return 0
    fi

    backup_current_config
    cp -a "$RESET_SOURCE" "$SSHD_CONFIG"

    log "默认配置已恢复到: $SSHD_CONFIG"
}

prepare_sshd_runtime() {
    local privilege_dir="/run/sshd"

    if [[ ! -d "$privilege_dir" ]]; then
        log "创建 SSH privilege separation 目录: $privilege_dir"
    fi

    install -d \
        -o root \
        -g root \
        -m 0755 \
        "$privilege_dir"
}

main() {
    parse_args "$@"
    need_root
    check_commands

    [[ -f "$SSHD_CONFIG" ]] ||
        die "未找到 SSH 配置文件: $SSHD_CONFIG"

    # 防止多个脚本实例同时修改配置。
    exec 9>"${SSHD_CONFIG}.harden.lock"

    flock -n 9 ||
        die "已有另一个 SSH 加固进程正在运行"

    detect_service_name

    log "SSH 服务名称: $SSH_SERVICE"
    log "SSH 配置文件: $SSHD_CONFIG"

    prepare_sshd_runtime

    if ((RESET_MODE)); then
        restore_default_config
        validate_config "$SSHD_CONFIG"
        log "默认 SSH 配置校验通过"
    else
        TEMP_FILE="$(mktemp "${SSHD_CONFIG}.tmp.XXXXXX")"

        chmod --reference="$SSHD_CONFIG" "$TEMP_FILE"
        chown --reference="$SSHD_CONFIG" "$TEMP_FILE"

        build_config "$SSHD_CONFIG" "$TEMP_FILE"

        log "校验新配置"

        validate_config "$TEMP_FILE"

        log "新配置语法校验通过"

        if cmp -s "$SSHD_CONFIG" "$TEMP_FILE"; then
            log "当前配置已经符合要求，无需修改"
        else
            if command -v diff >/dev/null 2>&1; then
                log "配置差异："
                diff -u "$SSHD_CONFIG" "$TEMP_FILE" || true
            fi

            if ((DRY_RUN)); then
                log "dry-run 完成，未修改任何系统配置"
                return 0
            fi

            backup_current_config
            install_config

            log "新配置已写入: $SSHD_CONFIG"
        fi

        validate_config "$SSHD_CONFIG"
    fi

    if ((!NO_RELOAD && !DRY_RUN)); then
        log "重新加载 SSH 服务"

        if ! systemctl reload "$SSH_SERVICE"; then
            rollback
            die "SSH reload 失败，已经尝试恢复原配置"
        fi

        if ! systemctl is-active --quiet "$SSH_SERVICE"; then
            rollback
            die "SSH 服务状态异常，已经尝试恢复原配置"
        fi

        log "SSH 服务 reload 成功"
    fi

    # 必须在 SSH 配置成功应用之后才允许锁 root 密码。
    if ((LOCK_ROOT_PASSWORD && !DRY_RUN)); then
        lock_root_password
    fi

    log "当前生效的关键 SSH 配置："

    show_effective_config

    if ((RESET_MODE)); then
        log "SSH 默认配置恢复完成"
    else
        log "SSH 加固完成"
    fi
}

main "$@"
