#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOCK_FILE="/run/lock/hotcoin-firewalld-backup.lock"
readonly FIREWALLD_CONFIG_DIR="${FIREWALLD_CONFIG_DIR:-/etc/firewalld}"
readonly BACKUP_FORMAT_VERSION="1"
readonly MAX_ARCHIVE_BYTES=$((100 * 1024 * 1024))

ACTION=""
TARGET=""
SAVE_RUNTIME=false
WORK_DIR=""
TX_DIR=""
TEMP_ARCHIVE=""
ROLLBACK_DIR=""
CONFIG_SWITCHED=false
HAD_CONFIG=false
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
SERVICE_STARTED_BY_SCRIPT=false
SERVICE_ENABLED_BY_SCRIPT=false
CHANGED=false
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
导出或导入 firewalld 永久配置。

用法：
  export_firewalld_rules.sh export OUTPUT_DIR [--runtime-to-permanent]
  export_firewalld_rules.sh import BACKUP_FILE
  export_firewalld_rules.sh help

示例：
  sudo ./export_firewalld_rules.sh export /coins/firewalld-backups
  sudo ./export_firewalld_rules.sh export /coins/firewalld-backups --runtime-to-permanent
  sudo ./export_firewalld_rules.sh import /coins/firewalld-backups/firewalld-backup-HOST-TIME.tar.gz

说明：
  export 默认备份 /etc/firewalld 中的永久配置。
  --runtime-to-permanent 会先把当前 runtime 配置写入 permanent，再导出。
  import 会校验归档、备份当前配置、原子切换，并在失败时回滚。
EOF
}

parse_args() {
    ACTION=${1:-}
    case "${ACTION}" in
        help|-h|--help|'')
            usage
            [[ -n ${ACTION} ]] && exit 0
            exit 1
            ;;
        export|import) ;;
        *) fatal "未知操作：${ACTION}（使用 help 查看用法）" ;;
    esac

    TARGET=${2:-}
    [[ -n ${TARGET} ]] || fatal "${ACTION} 缺少路径参数"
    shift 2

    while (( $# > 0 )); do
        case "$1" in
            --runtime-to-permanent)
                [[ ${ACTION} == export ]] || fatal "--runtime-to-permanent 仅适用于 export"
                SAVE_RUNTIME=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) fatal "未知参数：$1" ;;
        esac
        shift
    done
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "请使用 root 执行"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少命令：$1"
}

validate_absolute_path() {
    local path=$1
    local label=$2

    [[ ${path} == /* ]] || fatal "${label} 必须是绝对路径：${path}"
    [[ ${path} != / && ${path} != /. && ${path} != /.. ]] || \
        fatal "拒绝使用危险的 ${label}：${path}"
    [[ ${path} != *'*'* && ${path} != *'?'* && ${path} != *'['* ]] || \
        fatal "${label} 不能包含通配符：${path}"
}

acquire_lock() {
    require_command flock
    install -d -o root -g root -m 0755 "$(dirname "${LOCK_FILE}")"
    exec 9>"${LOCK_FILE}"
    flock -n 9 || fatal "已有另一个 firewalld 导入/导出进程正在运行"
}

safe_remove_work_dir() {
    local path=${1:-}
    local base

    [[ -n ${path} && -d ${path} ]] || return 0
    base=$(basename "${path}")
    case "${base}" in
        "${SCRIPT_NAME}."*|.firewalld-transaction.*) rm -rf -- "${path}" ;;
        *) log ERROR "拒绝清理非预期临时目录：${path}" ;;
    esac
}

rollback_import() {
    [[ ${ACTION} == import ]] || return 0
    log WARN "回滚本次导入产生的变更"

    if [[ ${CONFIG_SWITCHED} == true || ( -n ${ROLLBACK_DIR} && -d ${ROLLBACK_DIR} ) ]]; then
        if [[ -d ${FIREWALLD_CONFIG_DIR} ]]; then
            mv -f -- "${FIREWALLD_CONFIG_DIR}" "${TX_DIR}/failed-import" || true
        fi
        if [[ ${HAD_CONFIG} == true && -d ${ROLLBACK_DIR} ]]; then
            mv -f -- "${ROLLBACK_DIR}" "${FIREWALLD_CONFIG_DIR}" || true
            ROLLBACK_DIR=""
        fi
        CONFIG_SWITCHED=false
        command -v restorecon >/dev/null 2>&1 && \
            restorecon -RF "${FIREWALLD_CONFIG_DIR}" >/dev/null 2>&1 || true
    fi

    if [[ ${SERVICE_WAS_ACTIVE} == true ]]; then
        firewall-cmd --reload >/dev/null 2>&1 || systemctl restart firewalld.service || true
    elif [[ ${SERVICE_STARTED_BY_SCRIPT} == true ]]; then
        systemctl stop firewalld.service || true
        SERVICE_STARTED_BY_SCRIPT=false
    fi

    if [[ ${SERVICE_WAS_ENABLED} == false && ${SERVICE_ENABLED_BY_SCRIPT} == true ]]; then
        systemctl disable firewalld.service >/dev/null 2>&1 || true
        SERVICE_ENABLED_BY_SCRIPT=false
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )) && [[ ${COMMITTED} != true ]]; then
        rollback_import || log ERROR "回滚过程中出现错误"
    fi
    [[ -z ${TEMP_ARCHIVE} || ! -f ${TEMP_ARCHIVE} ]] || rm -f -- "${TEMP_ARCHIVE}"
    safe_remove_work_dir "${WORK_DIR}"
    safe_remove_work_dir "${TX_DIR}"
    exit "${rc}"
}

on_error() {
    local rc=$1
    local line=$2
    log ERROR "第 ${line} 行命令失败，退出码 ${rc}"
    exit "${rc}"
}

on_signal() {
    local signal=$1
    log WARN "收到 ${signal} 信号"
    exit 128
}

detect_os() {
    [[ -r /etc/os-release ]] || fatal "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
}

ensure_firewalld_installed() {
    if command -v firewall-offline-cmd >/dev/null 2>&1 && \
        command -v firewall-cmd >/dev/null 2>&1; then
        return
    fi

    [[ ${ACTION} == import ]] || fatal "firewalld 未安装，无法导出"
    detect_os
    log INFO "firewalld 未安装，开始安装软件包"
    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y firewalld
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y firewalld
    elif command -v yum >/dev/null 2>&1; then
        yum install -y firewalld
    else
        fatal "不支持当前系统的软件包管理器"
    fi

    require_command firewall-offline-cmd
    require_command firewall-cmd
}

check_common_commands() {
    local command_name

    for command_name in awk basename chmod chown cp cut date dirname find grep \
        hostname install mktemp mv python3 realpath rm sha256sum sort stat systemctl tar tr; do
        require_command "${command_name}"
    done
}

make_work_dir() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")
    chmod 0700 "${WORK_DIR}"
}

validate_live_config() {
    [[ -d ${FIREWALLD_CONFIG_DIR} ]] || fatal "配置目录不存在：${FIREWALLD_CONFIG_DIR}"
    [[ ! -L ${FIREWALLD_CONFIG_DIR} ]] || fatal "拒绝处理符号链接配置目录：${FIREWALLD_CONFIG_DIR}"
    if find "${FIREWALLD_CONFIG_DIR}" -type l -print -quit | grep -q .; then
        fatal "配置目录包含符号链接，拒绝导出"
    fi
    if find "${FIREWALLD_CONFIG_DIR}" ! -type d ! -type f -print -quit | grep -q .; then
        fatal "配置目录包含非常规文件，拒绝导出"
    fi
    firewall-offline-cmd --system-config="${FIREWALLD_CONFIG_DIR}" --check-config
}

export_config() {
    local output_dir archive_name archive_path timestamp safe_host version os_name

    validate_absolute_path "${TARGET}" "输出目录"
    [[ ! -L ${TARGET} ]] || fatal "输出目录不能是符号链接：${TARGET}"
    install -d -o root -g root -m 0750 "${TARGET}"
    [[ -d ${TARGET} && ! -L ${TARGET} ]] || fatal "输出目录无效或为符号链接：${TARGET}"
    output_dir=$(realpath "${TARGET}")
    [[ ${output_dir} != / ]] || fatal "拒绝直接输出到根目录"

    if [[ ${SAVE_RUNTIME} == true ]]; then
        firewall-cmd --state >/dev/null 2>&1 || \
            fatal "--runtime-to-permanent 要求 firewalld 正在运行"
        log INFO "将当前 runtime 配置保存为 permanent 配置"
        firewall-cmd --runtime-to-permanent
    fi

    validate_live_config
    make_work_dir
    cp -a -- "${FIREWALLD_CONFIG_DIR}" "${WORK_DIR}/firewalld"
    firewall-offline-cmd --system-config="${WORK_DIR}/firewalld" --check-config

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    safe_host=$(hostname | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
    [[ -n ${safe_host} ]] || safe_host="unknown-host"
    version=$(firewall-offline-cmd --version | tr '\n' ' ' | cut -c1-120)
    os_name="unknown"
    if [[ -r /etc/os-release ]]; then
        os_name=$(awk -F= '$1 == "PRETTY_NAME" { value=$2; gsub(/^"|"$/, "", value); print value }' \
            /etc/os-release | tr '\n' ' ' | cut -c1-160)
    fi

    cat > "${WORK_DIR}/manifest.env" <<EOF
format_version=${BACKUP_FORMAT_VERSION}
created_at_utc=${timestamp}
source_hostname=${safe_host}
source_os=${os_name}
firewalld_version=${version}
config_source=${FIREWALLD_CONFIG_DIR}
EOF

    (
        cd "${WORK_DIR}"
        : > SHA256SUMS
        while IFS= read -r -d '' file; do
            sha256sum "${file}" >> SHA256SUMS
        done < <(find firewalld -type f -print0 | LC_ALL=C sort -z)
        sha256sum manifest.env >> SHA256SUMS
    )

    archive_name="firewalld-backup-${safe_host}-${timestamp}-$$.tar.gz"
    archive_path="${output_dir}/${archive_name}"
    [[ ! -e ${archive_path} ]] || fatal "备份文件已存在：${archive_path}"
    TEMP_ARCHIVE=$(mktemp "${output_dir}/.firewalld-backup.tmp.XXXXXX")
    COPYFILE_DISABLE=1 tar -czf "${TEMP_ARCHIVE}" -C "${WORK_DIR}" \
        manifest.env SHA256SUMS firewalld
    chmod 0600 "${TEMP_ARCHIVE}"
    mv -f -- "${TEMP_ARCHIVE}" "${archive_path}"
    TEMP_ARCHIVE=""
    CHANGED=true
    COMMITTED=true

    log INFO "导出完成：${archive_path}"
    printf '%s\n' "${archive_path}"
}

secure_extract_archive() {
    local archive=$1
    local destination=$2

    python3 - "${archive}" "${destination}" "${MAX_ARCHIVE_BYTES}" <<'PY'
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile

archive, destination, max_bytes = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3])
seen = set()
total_size = 0
member_count = 0

with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    for member in members:
        member_count += 1
        if member_count > 10000:
            raise SystemExit("归档文件数量超过限制")
        path = PurePosixPath(member.name)
        parts = path.parts
        if path.is_absolute() or ".." in parts or not parts:
            raise SystemExit(f"归档包含不安全路径: {member.name}")
        if member.name in seen:
            raise SystemExit(f"归档包含重复路径: {member.name}")
        seen.add(member.name)
        if not (member.name in {"manifest.env", "SHA256SUMS", "firewalld"}
                or member.name.startswith("firewalld/")):
            raise SystemExit(f"归档包含非预期路径: {member.name}")
        if not (member.isdir() or member.isfile()):
            raise SystemExit(f"归档包含不支持的文件类型: {member.name}")
        total_size += member.size
        if total_size > max_bytes:
            raise SystemExit("归档解压后大小超过限制")

    for member in members:
        target = destination.joinpath(*PurePosixPath(member.name).parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            target.chmod(member.mode & 0o777)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        stream = source.extractfile(member)
        if stream is None:
            raise SystemExit(f"无法读取归档成员: {member.name}")
        with target.open("xb") as output:
            shutil.copyfileobj(stream, output)
        target.chmod(member.mode & 0o666)

manifest = destination / "manifest.env"
checksums = destination / "SHA256SUMS"
config_dir = destination / "firewalld"
if not manifest.is_file() or not checksums.is_file() or not config_dir.is_dir():
    raise SystemExit("归档缺少 manifest.env、SHA256SUMS 或 firewalld 目录")

expected = {}
for line in checksums.read_text(encoding="utf-8").splitlines():
    fields = line.split(maxsplit=1)
    if len(fields) != 2 or len(fields[0]) != 64:
        raise SystemExit("SHA256SUMS 格式无效")
    relative = fields[1].lstrip("* ")
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"校验文件包含不安全路径: {relative}")
    if relative in expected:
        raise SystemExit(f"校验文件包含重复路径: {relative}")
    expected[relative] = fields[0].lower()

actual = {"manifest.env"}
for root, dirs, files in os.walk(config_dir):
    for name in files:
        actual.add((Path(root) / name).relative_to(destination).as_posix())
if set(expected) != actual:
    missing = sorted(actual - set(expected))
    extra = sorted(set(expected) - actual)
    raise SystemExit(f"校验清单与归档内容不一致; missing={missing}, extra={extra}")

for relative, digest in expected.items():
    hasher = hashlib.sha256()
    with (destination / relative).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            hasher.update(chunk)
    if hasher.hexdigest() != digest:
        raise SystemExit(f"SHA-256 校验失败: {relative}")
PY
}

validate_archive() {
    local archive_size

    validate_absolute_path "${TARGET}" "备份文件"
    [[ -f ${TARGET} && ! -L ${TARGET} ]] || fatal "备份文件不存在或为符号链接：${TARGET}"
    archive_size=$(stat -c '%s' "${TARGET}")
    (( archive_size > 0 && archive_size <= MAX_ARCHIVE_BYTES )) || \
        fatal "备份文件大小异常：${archive_size} bytes"

    make_work_dir
    install -d -m 0700 "${WORK_DIR}/extract"
    secure_extract_archive "${TARGET}" "${WORK_DIR}/extract"
    grep -qx "format_version=${BACKUP_FORMAT_VERSION}" "${WORK_DIR}/extract/manifest.env" || \
        fatal "不支持的备份格式版本"
    firewall-offline-cmd --system-config="${WORK_DIR}/extract/firewalld" --check-config
    log INFO "备份归档、SHA-256 和 firewalld 配置校验通过"
}

record_service_state() {
    systemctl is-active --quiet firewalld.service && SERVICE_WAS_ACTIVE=true || true
    systemctl is-enabled --quiet firewalld.service && SERVICE_WAS_ENABLED=true || true
}

configs_are_equal() {
    [[ -d ${FIREWALLD_CONFIG_DIR} && ! -L ${FIREWALLD_CONFIG_DIR} ]] || return 1
    python3 - "${FIREWALLD_CONFIG_DIR}" "${WORK_DIR}/extract/firewalld" <<'PY'
import filecmp
import os
from pathlib import Path
import stat
import sys

left, right = map(Path, sys.argv[1:])

def inventory(root):
    result = {}
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            kind = "dir" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "other"
            result[relative] = (kind, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
    return result

left_items = inventory(left)
right_items = inventory(right)
if left_items != right_items:
    raise SystemExit(1)
for relative, metadata in left_items.items():
    if metadata[0] == "file" and not filecmp.cmp(left / relative, right / relative, shallow=False):
        raise SystemExit(1)
    if metadata[0] == "other":
        raise SystemExit(1)
PY
}

create_durable_preimport_backup() {
    local backup_dir="/var/backups/firewalld"
    local backup_file
    local temp_backup

    [[ ! -L ${backup_dir} ]] || fatal "备份目录不能是符号链接：${backup_dir}"
    install -d -o root -g root -m 0700 "${backup_dir}"
    backup_file="${backup_dir}/firewalld-before-import-$(date -u '+%Y%m%dT%H%M%SZ').$$.tar.gz"
    temp_backup=$(mktemp "${backup_dir}/.firewalld-before-import.tmp.XXXXXX")
    if ! COPYFILE_DISABLE=1 tar -czf "${temp_backup}" -C "$(dirname "${FIREWALLD_CONFIG_DIR}")" \
        "$(basename "${FIREWALLD_CONFIG_DIR}")"; then
        rm -f -- "${temp_backup}"
        fatal "无法备份当前 firewalld 配置"
    fi
    chmod 0600 "${temp_backup}"
    mv -f -- "${temp_backup}" "${backup_file}"
    log INFO "当前配置已备份：${backup_file}"
}

stage_and_switch_config() {
    local candidate

    TX_DIR=$(mktemp -d "/etc/.firewalld-transaction.XXXXXX")
    chmod 0700 "${TX_DIR}"
    candidate="${TX_DIR}/candidate"
    cp -a -- "${WORK_DIR}/extract/firewalld" "${candidate}"
    find "${candidate}" -exec chown root:root {} +
    firewall-offline-cmd --system-config="${candidate}" --check-config

    if [[ -d ${FIREWALLD_CONFIG_DIR} ]]; then
        [[ ! -L ${FIREWALLD_CONFIG_DIR} ]] || fatal "拒绝替换符号链接配置目录"
        HAD_CONFIG=true
        create_durable_preimport_backup
        ROLLBACK_DIR="${TX_DIR}/original"
        mv -- "${FIREWALLD_CONFIG_DIR}" "${ROLLBACK_DIR}"
        CONFIG_SWITCHED=true
    else
        # 若候选目录换入成功但进程随即中断，退出钩子仍会清理它。
        CONFIG_SWITCHED=true
    fi

    mv -- "${candidate}" "${FIREWALLD_CONFIG_DIR}"
    CONFIG_SWITCHED=true
    CHANGED=true
    command -v restorecon >/dev/null 2>&1 && restorecon -RF "${FIREWALLD_CONFIG_DIR}" || true
    log INFO "firewalld 配置目录已切换"
}

enable_and_apply_service() {
    if [[ ${SERVICE_WAS_ENABLED} == false ]]; then
        systemctl enable firewalld.service
        SERVICE_ENABLED_BY_SCRIPT=true
        CHANGED=true
    fi

    if [[ ${SERVICE_WAS_ACTIVE} == true ]]; then
        if [[ ${CONFIG_SWITCHED} == true ]]; then
            firewall-cmd --reload
        fi
    else
        systemctl start firewalld.service
        SERVICE_STARTED_BY_SCRIPT=true
        CHANGED=true
    fi

    systemctl is-active --quiet firewalld.service || fatal "firewalld 服务未运行"
    firewall-cmd --state | grep -qx running || fatal "firewall-cmd 状态检查失败"
    firewall-offline-cmd --system-config="${FIREWALLD_CONFIG_DIR}" --check-config
    firewall-cmd --get-default-zone >/dev/null
}

import_config() {
    ensure_firewalld_installed
    validate_archive
    record_service_state

    if configs_are_equal; then
        log INFO "当前 firewalld 配置与备份一致，跳过配置替换"
    else
        log WARN "即将替换完整 firewalld 配置；请确认备份允许当前 SSH/管理端口"
        stage_and_switch_config
    fi

    enable_and_apply_service
    COMMITTED=true
    if [[ ${CHANGED} == true ]]; then
        log INFO "导入完成，系统状态已更新"
    else
        log INFO "导入完成，系统已经符合目标状态"
    fi
}

main() {
    parse_args "$@"
    require_root
    acquire_lock
    ensure_firewalld_installed
    check_common_commands

    case "${ACTION}" in
        export) export_config ;;
        import) import_config ;;
    esac
}

trap 'on_error "$?" "$LINENO"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap cleanup EXIT

main "$@"
