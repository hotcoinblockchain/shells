#!/usr/bin/env bash

set -Eeuo pipefail

readonly FSTAB="${FSTAB:-/etc/fstab}"

DEVICE="${1:-}"
MOUNT_POINT="${2:-}"
UUID=""
FS_TYPE=""
DEVICE_MAJ_MIN=""
FSTAB_CHANGED=false
MOUNTED_BY_SCRIPT=false
ROLLBACK_FILE=""
TEMP_FILE=""
CREATED_MOUNT_DIRS=()

log() {
    printf '[mount-by-uuid.sh] %s\n' "$*"
}

die() {
    printf '[mount-by-uuid.sh] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  mount-by-uuid.sh <device> <mount_point>

示例：
  sudo ./mount-by-uuid.sh /dev/vdb1 /coins
  curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/mount-by-uuid.sh \
    | sudo bash -s -- /dev/vdb1 /coins

脚本不会格式化设备。设备必须已经包含可识别的文件系统和 UUID。
EOF
}

cleanup() {
    [[ -z ${TEMP_FILE} || ! -f ${TEMP_FILE} ]] || rm -f -- "${TEMP_FILE}"
    [[ -z ${ROLLBACK_FILE} || ! -f ${ROLLBACK_FILE} ]] || rm -f -- "${ROLLBACK_FILE}"
}

on_exit() {
    local exit_code=$?

    trap - EXIT
    if (( exit_code != 0 )); then
        rollback || true
    fi
    cleanup
    exit "${exit_code}"
}

trap on_exit EXIT

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 执行"
}

check_arguments() {
    if [[ ${DEVICE} == -h || ${DEVICE} == --help ]]; then
        usage
        exit 0
    fi
    [[ -n ${DEVICE} && -n ${MOUNT_POINT} ]] || {
        usage >&2
        die "缺少设备或挂载点参数"
    }
    [[ $# -eq 2 ]] || die "只接受 device 和 mount_point 两个参数"
    [[ -b ${DEVICE} ]] || die "块设备不存在：${DEVICE}"
    [[ ${MOUNT_POINT} == /* ]] || die "挂载点必须是绝对路径：${MOUNT_POINT}"
    [[ ${MOUNT_POINT} != / ]] || die "拒绝把设备挂载到根目录 /"
    [[ ${MOUNT_POINT} != *[[:space:]]* ]] || die "挂载点暂不支持空白字符"
    [[ ! -L ${MOUNT_POINT} ]] || die "挂载点不能是符号链接：${MOUNT_POINT}"
    [[ -f ${FSTAB} ]] || die "fstab 文件不存在：${FSTAB}"
    [[ ! -L ${FSTAB} ]] || die "为保证原子替换，拒绝处理符号链接 fstab：${FSTAB}"
}

check_commands() {
    local command_name

    for command_name in blkid findmnt lsblk mount umount mountpoint awk cmp mktemp flock stat \
        find install cp mv chmod chown rmdir; do
        command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令：${command_name}"
    done
}

prepare_mount_point() {
    local path parent

    if [[ -e ${MOUNT_POINT} ]]; then
        [[ -d ${MOUNT_POINT} ]] || die "挂载点已存在但不是目录：${MOUNT_POINT}"
        return
    fi

    path=${MOUNT_POINT}
    while [[ ! -e ${path} ]]; do
        CREATED_MOUNT_DIRS+=("${path}")
        parent=${path%/*}
        [[ -n ${parent} ]] || parent=/
        path=${parent}
    done
    [[ -d ${path} ]] || die "挂载点的上级路径不是目录：${path}"

    install -d -o root -g root -m 0755 "${MOUNT_POINT}"
    log "已创建挂载点：${MOUNT_POINT}"
}

read_device_info() {
    UUID=$(blkid -s UUID -o value "${DEVICE}" || true)
    FS_TYPE=$(blkid -s TYPE -o value "${DEVICE}" || true)
    DEVICE_MAJ_MIN=$(lsblk -dn -o MAJ:MIN "${DEVICE}" | awk 'NR == 1 { print $1 }')

    [[ -n ${UUID} ]] || die "设备没有 UUID：${DEVICE}"
    [[ -n ${FS_TYPE} ]] || die "无法识别文件系统类型：${DEVICE}"
    [[ -n ${DEVICE_MAJ_MIN} ]] || die "无法识别设备号：${DEVICE}"

    log "设备：${DEVICE}"
    log "UUID：${UUID}"
    log "文件系统：${FS_TYPE}"
    log "挂载点：${MOUNT_POINT}"
}

check_fstab_conflicts() {
    local desired_spec="UUID=${UUID}"
    local conflicts

    conflicts=$(awk -v spec="${desired_spec}" -v target="${MOUNT_POINT}" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF < 2 { next }
        $1 == spec && $2 != target {
            print "同一 UUID 已配置到其他挂载点: " $0
        }
        $2 == target && $1 != spec {
            print "挂载点已配置给其他设备: " $0
        }
    ' "${FSTAB}")

    if [[ -n ${conflicts} ]]; then
        printf '[mount-by-uuid.sh] ERROR: 检测到 fstab 冲突：\n%s\n' "${conflicts}" >&2
        exit 1
    fi
}

build_fstab() {
    local desired_spec="UUID=${UUID}"
    local fsck_pass=0
    local desired_line
    local original_mode original_owner

    case "${FS_TYPE}" in
        ext2|ext3|ext4) fsck_pass=2 ;;
    esac
    desired_line="${desired_spec}  ${MOUNT_POINT}  ${FS_TYPE}  defaults,nofail  0  ${fsck_pass}"
    TEMP_FILE=$(mktemp "${FSTAB}.tmp.XXXXXX")

    awk -v spec="${desired_spec}" -v target="${MOUNT_POINT}" -v desired="${desired_line}" '
        BEGIN { inserted = 0 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        $1 == spec && $2 == target {
            if (!inserted) {
                print desired
                inserted = 1
            }
            next
        }
        { print }
        END {
            if (!inserted) {
                print desired
            }
        }
    ' "${FSTAB}" > "${TEMP_FILE}"

    original_mode=$(stat -c '%a' "${FSTAB}" 2>/dev/null || stat -f '%Lp' "${FSTAB}")
    original_owner=$(stat -c '%u:%g' "${FSTAB}" 2>/dev/null || stat -f '%u:%g' "${FSTAB}")
    chmod "${original_mode}" "${TEMP_FILE}"
    chown "${original_owner}" "${TEMP_FILE}"
}

validate_fstab() {
    local verify_output

    if ! verify_output=$(findmnt --verify --verbose --tab-file "${TEMP_FILE}" 2>&1); then
        printf '[mount-by-uuid.sh] findmnt 校验详情：\n%s\n' "${verify_output}" >&2
        die "生成的 fstab 未通过 findmnt 校验，未修改系统配置"
    fi
}

install_fstab() {
    if cmp -s "${FSTAB}" "${TEMP_FILE}"; then
        rm -f -- "${TEMP_FILE}"
        TEMP_FILE=""
        log "fstab 已符合要求，无需修改"
        return
    fi

    ROLLBACK_FILE=$(mktemp "${FSTAB}.rollback.XXXXXX")
    cp -a "${FSTAB}" "${ROLLBACK_FILE}"
    cp -a "${FSTAB}" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S).$$"
    mv -f -- "${TEMP_FILE}" "${FSTAB}"
    TEMP_FILE=""
    FSTAB_CHANGED=true
    log "fstab 已原子更新，并保留备份"
}

rollback() {
    if [[ ${MOUNTED_BY_SCRIPT} == true ]] && mountpoint -q "${MOUNT_POINT}"; then
        umount "${MOUNT_POINT}" || true
        MOUNTED_BY_SCRIPT=false
    fi
    if [[ ${FSTAB_CHANGED} == true && -f ${ROLLBACK_FILE} ]]; then
        mv -f -- "${ROLLBACK_FILE}" "${FSTAB}"
        ROLLBACK_FILE=""
        FSTAB_CHANGED=false
        log "操作失败，已恢复原 fstab"
    fi
    if (( ${#CREATED_MOUNT_DIRS[@]} > 0 )); then
        local directory

        for directory in "${CREATED_MOUNT_DIRS[@]}"; do
            rmdir -- "${directory}" 2>/dev/null || true
        done
        CREATED_MOUNT_DIRS=()
    fi
}

mounted_device_matches() {
    local mounted_maj_min

    mountpoint -q "${MOUNT_POINT}" || return 1
    mounted_maj_min=$(findmnt -n -o MAJ:MIN --mountpoint "${MOUNT_POINT}" | awk 'NR == 1 { print $1 }')
    [[ -n ${mounted_maj_min} && ${mounted_maj_min} == "${DEVICE_MAJ_MIN}" ]]
}

check_runtime_conflicts() {
    local mounted_source mounted_targets

    if mountpoint -q "${MOUNT_POINT}"; then
        if mounted_device_matches; then
            log "目标设备已经正确挂载"
            return
        fi
        mounted_source=$(findmnt -n -o SOURCE --mountpoint "${MOUNT_POINT}" | awk 'NR == 1 { print $1 }')
        die "挂载点已被其他设备占用：${mounted_source:-unknown} -> ${MOUNT_POINT}"
    fi

    mounted_targets=$(findmnt -rn -S "UUID=${UUID}" -o TARGET 2>/dev/null || true)
    [[ -z ${mounted_targets} ]] || die "设备已经挂载到其他位置：${mounted_targets}"

    if [[ -d ${MOUNT_POINT} && -n $(find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        die "未挂载的目标目录不是空目录，为避免隐藏已有文件已停止：${MOUNT_POINT}"
    fi
}

mount_and_verify() {
    local actual_fs

    if mounted_device_matches; then
        return
    fi

    log "挂载 ${MOUNT_POINT}..."
    if ! mount "${MOUNT_POINT}"; then
        rollback
        die "挂载失败"
    fi
    MOUNTED_BY_SCRIPT=true

    if ! mounted_device_matches; then
        rollback
        die "挂载后的实际设备与 ${DEVICE} 不一致"
    fi

    actual_fs=$(findmnt -n -o FSTYPE --mountpoint "${MOUNT_POINT}" | awk 'NR == 1 { print $1 }')
    if [[ ${actual_fs} != "${FS_TYPE}" ]]; then
        rollback
        die "挂载后的文件系统类型不一致：期望 ${FS_TYPE}，实际 ${actual_fs:-unknown}"
    fi
}

main() {
    check_arguments "$@"
    require_root
    check_commands

    exec 9>"${FSTAB}.hotcoin.lock"
    flock -n 9 || die "已有另一个 fstab 配置进程正在运行"

    read_device_info
    check_fstab_conflicts
    check_runtime_conflicts
    build_fstab
    prepare_mount_point
    validate_fstab
    install_fstab
    mount_and_verify

    rm -f -- "${ROLLBACK_FILE}"
    ROLLBACK_FILE=""
    FSTAB_CHANGED=false
    log "挂载完成；重复执行不会产生额外配置"
}

main "$@"
