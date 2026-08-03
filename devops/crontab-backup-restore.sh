#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="crontab-backup-restore.sh"
readonly DEFAULT_BACKUP_DIR="/coins"
readonly FORMAT_HEADER="# HOTCOIN CRONTAB BACKUP v1"
readonly CONTENT_MARKER="# --- BEGIN CRONTAB ---"
readonly MAX_BACKUP_BYTES=$((10 * 1024 * 1024))

ACTION=""
TARGET=""
CURRENT_USER=""
CURRENT_UID=""
LOCK_DIR=""
WORK_DIR=""
TEMP_BACKUP=""
CAPTURE_HAD_CRONTAB=false
OLD_HAD_CRONTAB=false
CHANGED=false
MUTATED=false
COMMITTED=false

log() {
    local level=$1
    shift
    printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "${level}" "${SCRIPT_NAME}" "$*" >&2
}

fatal() {
    log ERROR "$*"
    exit 1
}

usage() {
    cat <<'EOF'
备份或恢复当前用户的 crontab。

用法：
  crontab-backup-restore.sh backup [BACKUP_DIR]
  crontab-backup-restore.sh restore BACKUP_FILE
  crontab-backup-restore.sh help

参数：
  BACKUP_DIR   备份目录，默认 /coins
  BACKUP_FILE  backup 生成的备份文件

示例：
  ./crontab-backup-restore.sh backup
  ./crontab-backup-restore.sh backup /data/backups
  ./crontab-backup-restore.sh restore /coins/crontab-root.backup

说明：
  - 脚本始终操作执行它的当前用户；使用 sudo 执行时操作的是 root crontab。
  - 备份文件名固定为 crontab-用户名.backup，重复备份会原子更新该文件。
  - 恢复前会保存当前 crontab，失败时自动回滚。
EOF
}

parse_args() {
    ACTION=${1:-}
    case "${ACTION}" in
        backup)
            TARGET=${2:-${DEFAULT_BACKUP_DIR}}
            (( $# <= 2 )) || fatal "backup 参数过多（使用 help 查看用法）"
            ;;
        restore)
            TARGET=${2:-}
            [[ -n ${TARGET} ]] || fatal "restore 缺少 BACKUP_FILE"
            (( $# == 2 )) || fatal "restore 参数数量错误（使用 help 查看用法）"
            ;;
        help|-h|--help|'')
            usage
            [[ -n ${ACTION} ]] && exit 0
            exit 1
            ;;
        *) fatal "未知操作：${ACTION}（使用 help 查看用法）" ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少命令：$1"
}

validate_path() {
    local path=$1
    local label=$2

    [[ -n ${path} && ${path} != / && ${path} != . && ${path} != .. ]] || \
        fatal "拒绝使用危险的${label}：${path:-<empty>}"
    [[ ${path} == /* ]] || fatal "${label}必须使用绝对路径：${path}"
    [[ ${path} != *'*'* && ${path} != *'?'* && ${path} != *'['* ]] || \
        fatal "${label}不能包含通配符：${path}"
}

make_work_dir() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hotcoin-crontab.XXXXXX")
    chmod 0700 "${WORK_DIR}"
}

safe_remove_work_dir() {
    local expected_prefix="${TMPDIR:-/tmp}/hotcoin-crontab."

    [[ -z ${WORK_DIR} ]] && return 0
    if [[ -d ${WORK_DIR} && ! -L ${WORK_DIR} && ${WORK_DIR} == "${expected_prefix}"* ]]; then
        rm -rf -- "${WORK_DIR}"
    else
        log ERROR "拒绝清理非预期临时目录：${WORK_DIR}"
    fi
    WORK_DIR=""
}

rollback() {
    [[ ${MUTATED} == true && -n ${WORK_DIR} ]] || return 0
    log WARN "恢复失败，正在回滚当前用户的 crontab"
    if [[ ${OLD_HAD_CRONTAB} == true ]]; then
        crontab "${WORK_DIR}/old.crontab"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    MUTATED=false
}

cleanup() {
    local rc=$?

    if (( rc != 0 )) && [[ ${COMMITTED} != true ]]; then
        rollback || log ERROR "crontab 回滚失败，请检查当前 crontab"
    fi
    if [[ -n ${TEMP_BACKUP} && -f ${TEMP_BACKUP} ]]; then
        rm -f -- "${TEMP_BACKUP}"
    fi
    safe_remove_work_dir
}

on_error() {
    local rc=$1
    local line=$2
    log ERROR "第 ${line} 行命令失败，退出码 ${rc}"
    exit "${rc}"
}

on_signal() {
    local signal=$1
    log WARN "收到 ${signal} 信号，正在安全退出"
    exit 128
}

acquire_lock() {
    local runtime_base=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
    local owner_uid

    LOCK_DIR="${runtime_base}/hotcoin-crontab-${CURRENT_UID}"
    if [[ -e ${LOCK_DIR} ]]; then
        [[ -d ${LOCK_DIR} && ! -L ${LOCK_DIR} ]] || fatal "锁目录不安全：${LOCK_DIR}"
        owner_uid=$(stat -c '%u' "${LOCK_DIR}")
        [[ ${owner_uid} == "${CURRENT_UID}" ]] || fatal "锁目录不属于当前用户：${LOCK_DIR}"
        chmod 0700 "${LOCK_DIR}"
    else
        mkdir -m 0700 -- "${LOCK_DIR}"
    fi

    exec 9>"${LOCK_DIR}/lock"
    flock -n 9 || fatal "当前用户已有另一个 crontab 备份/恢复进程正在运行"
}

capture_current_crontab() {
    local output_file=$1
    local error_file=$2

    if LC_ALL=C crontab -l >"${output_file}" 2>"${error_file}"; then
        CAPTURE_HAD_CRONTAB=true
        return 0
    fi
    if grep -qi 'no crontab for' "${error_file}"; then
        CAPTURE_HAD_CRONTAB=false
        : >"${output_file}"
        return 0
    fi
    fatal "无法读取 ${CURRENT_USER} 的 crontab：$(tr '\n' ' ' <"${error_file}")"
}

preflight() {
    local command_name

    for command_name in awk chmod cmp crontab date dirname flock grep id mkdir mktemp \
        mv rm sed stat tr wc; do
        require_command "${command_name}"
    done
    CURRENT_USER=$(id -un)
    CURRENT_UID=$(id -u)
    [[ ${CURRENT_USER} =~ ^[A-Za-z0-9._-]+$ ]] || fatal "当前用户名包含不支持的字符"
    acquire_lock
    make_work_dir
}

write_backup() {
    local backup_dir=$1
    local backup_file

    validate_path "${backup_dir}" "备份目录"
    if [[ -e ${backup_dir} ]]; then
        [[ -d ${backup_dir} && ! -L ${backup_dir} ]] || fatal "备份目录无效或为符号链接：${backup_dir}"
    else
        mkdir -p -- "${backup_dir}"
    fi
    [[ -w ${backup_dir} ]] || fatal "当前用户无权写入备份目录：${backup_dir}"

    capture_current_crontab "${WORK_DIR}/current.crontab" "${WORK_DIR}/capture.err"
    backup_file="${backup_dir%/}/crontab-${CURRENT_USER}.backup"
    [[ ! -L ${backup_file} ]] || fatal "拒绝覆盖符号链接备份文件：${backup_file}"
    TEMP_BACKUP=$(mktemp "${backup_dir%/}/.crontab-backup.tmp.XXXXXX")

    {
        printf '%s\n' "${FORMAT_HEADER}"
        printf '# user=%s\n' "${CURRENT_USER}"
        printf '# uid=%s\n' "${CURRENT_UID}"
        printf '# had_crontab=%s\n' "${CAPTURE_HAD_CRONTAB}"
        printf '%s\n' "${CONTENT_MARKER}"
        if [[ ${CAPTURE_HAD_CRONTAB} == true ]]; then
            awk '{ print }' "${WORK_DIR}/current.crontab"
        fi
    } >"${TEMP_BACKUP}"
    chmod 0600 "${TEMP_BACKUP}"

    if [[ -f ${backup_file} ]] && cmp -s "${TEMP_BACKUP}" "${backup_file}"; then
        rm -f -- "${TEMP_BACKUP}"
        TEMP_BACKUP=""
        log INFO "备份内容未变化：${backup_file}"
        return 0
    fi

    mv -f -- "${TEMP_BACKUP}" "${backup_file}"
    TEMP_BACKUP=""
    CHANGED=true
    log INFO "crontab 已备份：${backup_file}"
}

parse_backup() {
    local backup_file=$1
    local size
    local backup_user
    local had_crontab

    validate_path "${backup_file}" "备份文件"
    [[ -f ${backup_file} && ! -L ${backup_file} ]] || fatal "备份文件不存在或为符号链接：${backup_file}"
    size=$(stat -c '%s' "${backup_file}")
    (( size > 0 && size <= MAX_BACKUP_BYTES )) || fatal "备份文件大小异常：${size} bytes"
    [[ $(sed -n '1p' "${backup_file}") == "${FORMAT_HEADER}" ]] || \
        fatal "不支持的 crontab 备份格式"
    [[ $(sed -n '5p' "${backup_file}") == "${CONTENT_MARKER}" ]] || \
        fatal "备份文件内容分隔符无效"

    backup_user=$(sed -n '2s/^# user=//p' "${backup_file}")
    [[ -n ${backup_user} ]] || fatal "备份文件缺少 user 元数据"
    [[ ${backup_user} == "${CURRENT_USER}" ]] || \
        fatal "备份属于用户 ${backup_user}，当前用户是 ${CURRENT_USER}"
    [[ $(sed -n '3p' "${backup_file}") =~ ^#[[:space:]]uid=[0-9]+$ ]] || \
        fatal "备份文件中的 uid 元数据无效"
    had_crontab=$(sed -n '4s/^# had_crontab=//p' "${backup_file}")
    [[ ${had_crontab} == true || ${had_crontab} == false ]] || fatal "had_crontab 元数据无效"

    awk 'NR > 5 { print }' "${backup_file}" >"${WORK_DIR}/desired.crontab"

    if [[ ${had_crontab} == false && -s ${WORK_DIR}/desired.crontab ]]; then
        fatal "无 crontab 备份不应包含任务内容"
    fi
    printf '%s\n' "${had_crontab}" >"${WORK_DIR}/desired.state"
}

verify_restored_state() {
    local desired_state

    desired_state=$(<"${WORK_DIR}/desired.state")
    capture_current_crontab "${WORK_DIR}/verified.crontab" "${WORK_DIR}/verify.err"
    [[ ${CAPTURE_HAD_CRONTAB} == "${desired_state}" ]] || fatal "恢复后的 crontab 存在状态不符合备份"
    if [[ ${desired_state} == true ]]; then
        cmp -s "${WORK_DIR}/desired.crontab" "${WORK_DIR}/verified.crontab" || \
            fatal "恢复后的 crontab 内容校验失败"
    fi
}

restore_backup() {
    local backup_file=$1
    local desired_state

    parse_backup "${backup_file}"
    capture_current_crontab "${WORK_DIR}/old.crontab" "${WORK_DIR}/old.err"
    OLD_HAD_CRONTAB=${CAPTURE_HAD_CRONTAB}
    desired_state=$(<"${WORK_DIR}/desired.state")

    if [[ ${OLD_HAD_CRONTAB} == "${desired_state}" ]]; then
        if [[ ${desired_state} == false ]] || cmp -s "${WORK_DIR}/old.crontab" "${WORK_DIR}/desired.crontab"; then
            log INFO "当前 crontab 已与备份一致，无需恢复"
            verify_restored_state
            return 0
        fi
    fi

    MUTATED=true
    if [[ ${desired_state} == true ]]; then
        crontab "${WORK_DIR}/desired.crontab"
    else
        crontab -r
    fi
    verify_restored_state
    CHANGED=true
    log INFO "${CURRENT_USER} 的 crontab 已恢复并验证"
}

main() {
    parse_args "$@"
    preflight

    case "${ACTION}" in
        backup) write_backup "${TARGET}" ;;
        restore) restore_backup "${TARGET}" ;;
    esac

    COMMITTED=true
    MUTATED=false
    if [[ ${CHANGED} == true ]]; then
        log INFO "操作完成，状态已更新"
    else
        log INFO "操作完成，状态无需改变"
    fi
}

trap 'on_error "$?" "$LINENO"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap cleanup EXIT

main "$@"
