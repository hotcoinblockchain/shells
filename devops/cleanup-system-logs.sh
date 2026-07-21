#!/usr/bin/env bash

set -Eeuo pipefail

readonly LOG_DIR="/var/log"
DEFAULT_DAYS=30
DEFAULT_MAX_SIZE="5G"

DAYS=${DEFAULT_DAYS}
MAX_SIZE=${DEFAULT_MAX_SIZE}
DRY_RUN=false

log() {
    printf '[cleanup-system-logs] %s\n' "$*"
}

warn() {
    printf '[cleanup-system-logs] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[cleanup-system-logs] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
清理并轮转系统日志。默认保留 30 天，/var/log 总大小不超过 5GB。

用法：
  cleanup-system-logs.sh [选项]

选项：
  -d, --days DAYS       日志保留天数，默认 30
  -s, --max-size SIZE   /var/log 大小上限，默认 5G
  -n, --dry-run         只显示将执行的操作，不修改文件
  -h, --help            显示帮助

SIZE 支持纯字节数，或 K、M、G、T 单位（也接受 KB、MiB、GB 等写法）。

示例：
  sudo ./cleanup-system-logs.sh
  sudo ./cleanup-system-logs.sh --days 7 --max-size 2G
  sudo ./cleanup-system-logs.sh --dry-run --days 14 --max-size 512M

处理范围：
  - systemd journal：先轮转，再按时间和大小执行 vacuum
  - 普通日志：调用 logrotate，并清理过期或超出总量限制的轮转归档
  - 不会直接删除或截断正在写入的活跃日志
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -d|--days)
                (( $# >= 2 )) || die "$1 缺少参数"
                DAYS=$2
                shift 2
                ;;
            --days=*)
                DAYS=${1#*=}
                shift
                ;;
            -s|--max-size)
                (( $# >= 2 )) || die "$1 缺少参数"
                MAX_SIZE=$2
                shift 2
                ;;
            --max-size=*)
                MAX_SIZE=${1#*=}
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (( $# == 0 )) || die "不支持位置参数：$*"
                ;;
            *)
                die "未知参数：$1（使用 --help 查看帮助）"
                ;;
        esac
    done
}

validate_args() {
    [[ ${DAYS} =~ ^[1-9][0-9]*$ ]] || die "DAYS 必须是正整数：${DAYS}"
    (( DAYS <= 36500 )) || die "DAYS 数值过大：${DAYS}"
    [[ ${MAX_SIZE} =~ ^[0-9]+([KkMmGgTt]([Ii]?[Bb])?)?$ ]] || \
        die "SIZE 格式无效：${MAX_SIZE}"
}

size_to_bytes() {
    local value

    value=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    value=${value%IB}
    value=${value%B}
    command -v numfmt >/dev/null 2>&1 || die "缺少 numfmt，请安装 coreutils"
    numfmt --from=iec "${value}"
}

human_size() {
    numfmt --to=iec-i --suffix=B "$1"
}

require_environment() {
    [[ ${EUID} -eq 0 || ${DRY_RUN} == true ]] || \
        die "请使用 root 运行，例如：sudo $0 $*"
    [[ -d ${LOG_DIR} ]] || die "日志目录不存在：${LOG_DIR}"
    command -v find >/dev/null 2>&1 || die "缺少 find 命令"
    command -v sort >/dev/null 2>&1 || die "缺少 sort 命令"
    command -v du >/dev/null 2>&1 || die "缺少 du 命令"
}

is_rotated_log() {
    local file=$1
    local name=${file##*/}

    [[ ${name} == *.gz || ${name} == *.xz || ${name} == *.zst || \
       ${name} == *.bz2 || ${name} == *.old || ${name} == *.journal~ || \
       ${name} =~ \.[0-9]+(\.(gz|xz|zst|bz2))?$ ]]
}

rotate_logs() {
    local force_rotation=$1
    local -a command=(logrotate /etc/logrotate.conf)

    if [[ ${force_rotation} == true ]]; then
        command=(logrotate -f /etc/logrotate.conf)
    fi

    if command -v logrotate >/dev/null 2>&1 && [[ -f /etc/logrotate.conf ]]; then
        if [[ ${DRY_RUN} == true ]]; then
            log "[dry-run] 将执行：${command[*]}"
        else
            log "执行系统 logrotate..."
            if ! "${command[@]}"; then
                warn "logrotate 返回错误，将继续清理已有轮转日志"
            fi
        fi
    else
        warn "未找到 logrotate 或 /etc/logrotate.conf，跳过普通日志轮转"
    fi
}

vacuum_journal() {
    command -v journalctl >/dev/null 2>&1 || {
        warn "未找到 journalctl，跳过 systemd journal 清理"
        return
    }

    if [[ ${DRY_RUN} == true ]]; then
        log "[dry-run] 将执行：journalctl --rotate"
        log "[dry-run] 将执行：journalctl --vacuum-time=${DAYS}d"
        log "[dry-run] 将执行：journalctl --vacuum-size=${MAX_SIZE}"
        return
    fi

    log "轮转并清理 systemd journal..."
    journalctl --rotate
    journalctl --vacuum-time="${DAYS}d"
    journalctl --vacuum-size="${MAX_SIZE}"
}

remove_file() {
    local file=$1
    local reason=$2

    if [[ ${DRY_RUN} == true ]]; then
        log "[dry-run] ${reason}：${file}"
    else
        rm -f -- "${file}"
        log "${reason}：${file}"
    fi
}

remove_expired_archives() {
    local file
    local removed=0

    log "查找超过 ${DAYS} 天的轮转日志..."
    while IFS= read -r -d '' file; do
        is_rotated_log "${file}" || continue
        remove_file "${file}" "删除过期轮转日志"
        (( removed += 1 ))
    done < <(find "${LOG_DIR}" -xdev -type f -mmin "+$((DAYS * 1440))" -print0)

    log "过期轮转日志处理数量：${removed}"
}

directory_size() {
    du -sb "${LOG_DIR}" | awk '{print $1}'
}

enforce_size_limit() {
    local max_bytes=$1
    local current_bytes record metadata file file_bytes
    local removed=0

    current_bytes=$(directory_size)
    log "${LOG_DIR} 当前大小：$(human_size "${current_bytes}")，上限：$(human_size "${max_bytes}")"
    (( current_bytes > max_bytes )) || return

    while IFS= read -r -d '' record; do
        (( current_bytes > max_bytes )) || break

        metadata=${record#* }
        file_bytes=${metadata%% *}
        file=${metadata#* }
        [[ -f ${file} ]] || continue
        is_rotated_log "${file}" || continue

        remove_file "${file}" "按容量删除最旧轮转日志"
        (( current_bytes = current_bytes > file_bytes ? current_bytes - file_bytes : 0 ))
        (( removed += 1 ))
    done < <(find "${LOG_DIR}" -xdev -type f -printf '%T@ %s %p\0' | sort -z -n)

    if [[ ${DRY_RUN} == false ]]; then
        current_bytes=$(directory_size)
    fi
    if (( current_bytes > max_bytes )); then
        warn "轮转归档清理后仍有 $(human_size "${current_bytes}")；活跃日志不会被强制截断"
        return 2
    fi

    log "容量限制处理数量：${removed}，预计/当前大小：$(human_size "${current_bytes}")"
}

main() {
    local max_bytes
    local before_bytes after_bytes
    local force_rotation=false

    parse_args "$@"
    validate_args
    require_environment "$@"
    max_bytes=$(size_to_bytes "${MAX_SIZE}")
    (( max_bytes > 0 )) || die "SIZE 必须大于 0"

    before_bytes=$(directory_size)
    log "开始清理：保留 ${DAYS} 天，总量上限 ${MAX_SIZE}，当前 $(human_size "${before_bytes}")"
    if (( before_bytes > max_bytes )); then
        force_rotation=true
        log "日志总量已超过上限，将强制轮转后按最旧优先清理"
    fi

    rotate_logs "${force_rotation}"
    vacuum_journal
    remove_expired_archives
    enforce_size_limit "${max_bytes}"

    after_bytes=$(directory_size)
    if [[ ${DRY_RUN} == true ]]; then
        log "dry-run 完成，未修改文件"
    else
        log "清理完成：$(human_size "${before_bytes}") -> $(human_size "${after_bytes}")"
    fi
}

main "$@"
