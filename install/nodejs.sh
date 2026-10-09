#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_NVM_VERSION="v0.40.8"
readonly DEFAULT_NVM_INSTALL_SHA256="48a0eee9a60e07422dce0eb5774754c83889570ca1ee2566c516acbe8af03a9e"
readonly NVM_RELEASE="${NVM_RELEASE:-${DEFAULT_NVM_VERSION}}"
if [[ -n ${NVM_INSTALL_SHA256:-} ]]; then
    nvm_install_sha256=${NVM_INSTALL_SHA256}
elif [[ ${NVM_RELEASE} == "${DEFAULT_NVM_VERSION}" ]]; then
    nvm_install_sha256=${DEFAULT_NVM_INSTALL_SHA256}
else
    nvm_install_sha256=""
fi
readonly NVM_INSTALL_SHA256="${nvm_install_sha256}"
unset nvm_install_sha256
readonly NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_RELEASE}/install.sh"
readonly BEGIN_MARKER="# BEGIN MANAGED BLOCK: hotcoin-nodejs-nvm"
readonly END_MARKER="# END MANAGED BLOCK: hotcoin-nodejs-nvm"

ACTION=""
NODE_SELECTOR=""
NVM_DIR="${NVM_DIR:-}"
PROFILE_PATH=""
TEMP_DIR=""
PROFILE_TEMP=""
PROFILE_BACKUP=""
PROFILE_CHANGED=false
PROFILE_CREATED=false
COMMITTED=false

log() {
    local level=$1
    shift
    printf '[%s] [%s] %s\n' "${SCRIPT_NAME}" "${level}" "$*" >&2
}

die() {
    trap - ERR
    log ERROR "$*"
    exit 1
}

usage() {
    cat <<'EOF'
使用 NVM 安装和管理 Node.js。无参数时只显示本帮助，不执行安装。

用法：
  nodejs.sh install VERSION   安装指定版本或版本线，例如 20、22.12、20.18.1
  nodejs.sh latest            安装最新 Node.js 版本
  nodejs.sh lts               安装最新 LTS 版本
  nodejs.sh help              显示帮助

示例：
  ./nodejs.sh install 20
  ./nodejs.sh install 20.18.1
  ./nodejs.sh latest
  ./nodejs.sh lts

通过 GitHub 下载、检查后执行：
  curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh \
    -o /tmp/nodejs.sh
  bash /tmp/nodejs.sh install 20
  bash /tmp/nodejs.sh latest

环境变量：
  NVM_RELEASE      要安装的 NVM 版本，默认 v0.40.8
  NVM_INSTALL_SHA256
                   NVM 安装脚本的 SHA-256；更改 NVM_RELEASE 时必须同时提供
  NVM_DIR          NVM 安装目录，默认 ~/.nvm（设置 XDG_CONFIG_HOME 时为其 nvm 子目录）
  NODEJS_PROFILE   写入 NVM 加载配置的 shell profile；设为 /dev/null 可跳过

安装完成后，脚本会把所安装的 Node.js 版本设置为 NVM 默认版本。
NVM 是按用户安装的；请使用最终需要运行 Node.js 的用户执行本脚本。
EOF
}

cleanup() {
    local exit_code=$?

    if (( exit_code != 0 )) && [[ ${COMMITTED} != true ]]; then
        if [[ ${PROFILE_CHANGED} == true && -n ${PROFILE_BACKUP} && -f ${PROFILE_BACKUP} ]]; then
            mv -f -- "${PROFILE_BACKUP}" "${PROFILE_PATH}" || true
            log WARN "操作失败，已恢复原 shell profile"
        elif [[ ${PROFILE_CREATED} == true && -f ${PROFILE_PATH} ]]; then
            rm -f -- "${PROFILE_PATH}" || true
            log WARN "操作失败，已删除本次创建的 shell profile"
        fi
    fi
    [[ -z ${PROFILE_TEMP} || ! -f ${PROFILE_TEMP} ]] || rm -f -- "${PROFILE_TEMP}"
    [[ -z ${TEMP_DIR} || ! -d ${TEMP_DIR} ]] || rm -rf -- "${TEMP_DIR}"
    return "${exit_code}"
}

on_error() {
    local exit_code=$1
    local line=$2

    log ERROR "第 ${line} 行执行失败，退出码 ${exit_code}"
    exit "${exit_code}"
}

on_signal() {
    local signal_name=$1

    log WARN "收到信号 ${signal_name}，已停止"
    exit 128
}

parse_args() {
    ACTION=${1:-}

    case "${ACTION}" in
        help|-h|--help|'')
            usage
            exit 0
            ;;
        latest)
            [[ $# -eq 1 ]] || die "latest 不接受额外参数"
            NODE_SELECTOR="node"
            ;;
        lts)
            [[ $# -eq 1 ]] || die "lts 不接受额外参数"
            NODE_SELECTOR="lts/*"
            ;;
        install)
            [[ $# -eq 2 ]] || die "install 需要且只接受一个 VERSION 参数"
            NODE_SELECTOR=$2
            [[ ${NODE_SELECTOR} =~ ^v?[0-9]+([.][0-9]+){0,2}$ ]] || \
                die "VERSION 格式无效：${NODE_SELECTOR}（示例：20、22.12、20.18.1）"
            ;;
        *)
            die "未知操作：${ACTION}（使用 help 查看用法）"
            ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

check_dependencies() {
    local command_name

    for command_name in awk bash chmod chown cmp cp curl date dirname flock mktemp mv rm sha256sum stat; do
        require_command "${command_name}"
    done
}

resolve_paths() {
    [[ ${NVM_RELEASE} =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || \
        die "NVM_RELEASE 格式无效：${NVM_RELEASE}（示例：v0.40.8）"
    [[ ${NVM_INSTALL_SHA256} =~ ^[0-9a-f]{64}$ ]] || \
        die "缺少或无效的 NVM_INSTALL_SHA256；更改 NVM_RELEASE 时必须提供对应校验值"
    [[ -n ${HOME:-} && ${HOME} == /* && -d ${HOME} ]] || \
        die "HOME 必须是已存在的绝对目录"

    if [[ -z ${NVM_DIR:-} ]]; then
        if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
            NVM_DIR="${XDG_CONFIG_HOME%/}/nvm"
        else
            NVM_DIR="${HOME%/}/.nvm"
        fi
    fi
    NVM_DIR=${NVM_DIR%/}
    [[ ${NVM_DIR} == /* && ${NVM_DIR} != / ]] || die "NVM_DIR 必须是非根绝对路径"
    [[ ${NVM_DIR} != *$'\n'* && ${NVM_DIR} != *$'\r'* ]] || die "NVM_DIR 包含非法换行符"
    [[ ${NVM_DIR} =~ ^[-A-Za-z0-9_./\ ]+$ ]] || \
        die "NVM_DIR 包含不支持的特殊字符：${NVM_DIR}"
    [[ ! -L ${NVM_DIR} ]] || die "拒绝使用符号链接 NVM_DIR：${NVM_DIR}"

    if [[ -n ${NODEJS_PROFILE:-} ]]; then
        PROFILE_PATH=${NODEJS_PROFILE}
    elif [[ ${SHELL:-} == */zsh ]]; then
        PROFILE_PATH="${HOME%/}/.zshrc"
    elif [[ ${SHELL:-} == */bash ]]; then
        PROFILE_PATH="${HOME%/}/.bashrc"
    else
        PROFILE_PATH="${HOME%/}/.profile"
    fi

    if [[ ${PROFILE_PATH} != /dev/null ]]; then
        [[ ${PROFILE_PATH} == /* ]] || die "NODEJS_PROFILE 必须是绝对路径或 /dev/null"
        [[ ${PROFILE_PATH} != *$'\n'* && ${PROFILE_PATH} != *$'\r'* ]] || \
            die "NODEJS_PROFILE 包含非法换行符"
        [[ ! -L ${PROFILE_PATH} ]] || die "为保证原子更新，拒绝修改符号链接 profile：${PROFILE_PATH}"
        [[ ! -e ${PROFILE_PATH} || -f ${PROFILE_PATH} ]] || die "profile 不是普通文件：${PROFILE_PATH}"
        [[ -d $(dirname -- "${PROFILE_PATH}") ]] || die "profile 上级目录不存在：${PROFILE_PATH}"
    fi
}

acquire_lock() {
    local lock_root lock_file

    lock_root=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
    [[ -d ${lock_root} ]] || die "锁目录不存在：${lock_root}"
    lock_file="${lock_root%/}/hotcoin-nodejs-${UID}.lock"
    exec 9>"${lock_file}"
    flock -n 9 || die "当前用户已有另一个 Node.js/NVM 安装任务正在运行"
}

download_and_install_nvm() {
    local installer expected_version actual_version actual_checksum

    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hotcoin-nodejs.XXXXXX")
    chmod 0700 "${TEMP_DIR}"
    installer="${TEMP_DIR}/nvm-install.sh"

    log INFO "下载 NVM ${NVM_RELEASE} 官方安装脚本"
    curl --fail --silent --show-error --location \
        --retry 3 --connect-timeout 15 --max-time 120 \
        "${NVM_INSTALL_URL}" --output "${installer}"
    chmod 0700 "${installer}"
    actual_checksum=$(sha256sum "${installer}" | awk '{ print $1 }')
    [[ ${actual_checksum} == "${NVM_INSTALL_SHA256}" ]] || \
        die "NVM 安装脚本 SHA-256 校验失败"
    bash -n "${installer}" || die "下载的 NVM 安装脚本语法校验失败"

    log INFO "安装或更新 NVM ${NVM_RELEASE} 到 ${NVM_DIR}"
    PROFILE=/dev/null METHOD=script NVM_DIR="${NVM_DIR}" bash "${installer}"
    [[ -s ${NVM_DIR}/nvm.sh ]] || die "NVM 安装后未找到：${NVM_DIR}/nvm.sh"

    # shellcheck source=/dev/null
    . "${NVM_DIR}/nvm.sh"
    expected_version=${NVM_RELEASE#v}
    actual_version=$(nvm --version)
    [[ ${actual_version} == "${expected_version}" ]] || \
        die "NVM 版本校验失败：期望 ${expected_version}，实际 ${actual_version}"
    log INFO "NVM ${actual_version} 已就绪"
}

render_profile() {
    local original_mode original_owner profile_source

    [[ ${PROFILE_PATH} != /dev/null ]] || {
        log INFO "NODEJS_PROFILE=/dev/null，跳过 shell profile 配置"
        return
    }

    if [[ -f ${PROFILE_PATH} ]]; then
        if ! awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
            BEGIN { in_block = 0; begin_count = 0; end_count = 0; invalid = 0 }
            $0 == begin {
                begin_count++
                if (in_block || begin_count > 1) invalid = 1
                in_block = 1
                next
            }
            $0 == end {
                end_count++
                if (!in_block || end_count > 1) invalid = 1
                in_block = 0
            }
            END {
                if (in_block || begin_count != end_count) invalid = 1
                exit invalid
            }
        ' "${PROFILE_PATH}"; then
            die "profile 中的 NVM 托管块重复、嵌套或不完整：${PROFILE_PATH}"
        fi
        profile_source=${PROFILE_PATH}
    else
        profile_source=/dev/null
        PROFILE_CREATED=true
    fi

    PROFILE_TEMP=$(mktemp "${PROFILE_PATH}.tmp.XXXXXX")
    awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" -v nvm_dir="${NVM_DIR}" '
        function print_desired() {
            print begin
            print "export NVM_DIR=\"" nvm_dir "\""
            print "[ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\""
            print end
        }
        BEGIN { in_block = 0; replaced = 0 }
        $0 == begin {
            if (!replaced) print_desired()
            in_block = 1
            replaced = 1
            next
        }
        $0 == end && in_block { in_block = 0; next }
        !in_block { print }
        END {
            if (!replaced) {
                if (NR > 0) print ""
                print_desired()
            }
        }
    ' "${profile_source}" > "${PROFILE_TEMP}"

    if [[ -f ${PROFILE_PATH} ]]; then
        original_mode=$(stat -c '%a' "${PROFILE_PATH}" 2>/dev/null || stat -f '%Lp' "${PROFILE_PATH}")
        original_owner=$(stat -c '%u:%g' "${PROFILE_PATH}" 2>/dev/null || stat -f '%u:%g' "${PROFILE_PATH}")
        chmod "${original_mode}" "${PROFILE_TEMP}"
        chown "${original_owner}" "${PROFILE_TEMP}"
    else
        chmod 0644 "${PROFILE_TEMP}"
    fi

    if [[ -f ${PROFILE_PATH} ]] && cmp -s "${PROFILE_PATH}" "${PROFILE_TEMP}"; then
        rm -f -- "${PROFILE_TEMP}"
        PROFILE_TEMP=""
        log INFO "shell profile 已符合要求：${PROFILE_PATH}"
        return
    fi

    if [[ -f ${PROFILE_PATH} ]]; then
        PROFILE_BACKUP="${PROFILE_PATH}.bak.$(date +%Y%m%d%H%M%S).$$"
        cp -a -- "${PROFILE_PATH}" "${PROFILE_BACKUP}"
    fi
    mv -f -- "${PROFILE_TEMP}" "${PROFILE_PATH}"
    PROFILE_TEMP=""
    PROFILE_CHANGED=true
    log INFO "已更新 shell profile：${PROFILE_PATH}"
    [[ -z ${PROFILE_BACKUP} ]] || log INFO "原文件备份：${PROFILE_BACKUP}"
}

install_node() {
    local resolved_version node_version npm_version

    # shellcheck source=/dev/null
    . "${NVM_DIR}/nvm.sh"

    log INFO "通过 NVM 安装 Node.js：${NODE_SELECTOR}"
    nvm install "${NODE_SELECTOR}"
    resolved_version=$(nvm version "${NODE_SELECTOR}")
    [[ ${resolved_version} != N/A ]] || die "无法解析已安装的 Node.js 版本：${NODE_SELECTOR}"

    nvm alias default "${resolved_version}" >/dev/null
    nvm use --silent default

    node_version=$(node --version)
    npm_version=$(npm --version)
    [[ ${node_version} == "${resolved_version}" ]] || \
        die "Node.js 版本校验失败：期望 ${resolved_version}，实际 ${node_version}"

    log INFO "安装完成：Node.js ${node_version}，npm ${npm_version}"
    log INFO "默认版本：$(nvm version default)"
    if [[ ${PROFILE_PATH} != /dev/null ]]; then
        log INFO "新终端将自动加载 NVM；当前终端可执行：source \"${PROFILE_PATH}\""
    fi
}

main() {
    parse_args "$@"
    check_dependencies
    resolve_paths
    acquire_lock
    download_and_install_nvm
    render_profile
    install_node

    if [[ ${PROFILE_CHANGED} == true && -n ${PROFILE_BACKUP} ]]; then
        log INFO "shell profile 已安全更新；如需回退可使用备份 ${PROFILE_BACKUP}"
    fi
    COMMITTED=true
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

main "$@"
