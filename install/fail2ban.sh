#!/usr/bin/env bash

set -Eeuo pipefail

CONF_FILE="${CONF_FILE:-/etc/fail2ban/jail.d/99-hotcoin-sshd.local}"
TEMP_FILE=""
BACKUP_FILE=""
HAD_CONFIG=false
CONFIG_CHANGED=false
OS_FAMILY=""
PACKAGE_MANAGER=""

log() {
    printf '[fail2ban.sh] %s\n' "$*"
}

die() {
    printf '[fail2ban.sh] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [[ -z ${TEMP_FILE} || ! -f ${TEMP_FILE} ]] || rm -f -- "${TEMP_FILE}"
    [[ -z ${BACKUP_FILE} || ! -f ${BACKUP_FILE} ]] || rm -f -- "${BACKUP_FILE}"
}

trap cleanup EXIT

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 执行"
}

# Use ID_LIKE as well as ID: Alibaba Cloud Linux commonly uses ID=alinux.
detect_system() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，无法识别系统"
    local ID="" ID_LIKE="" PRETTY_NAME="" VERSION_ID=""
    # shellcheck source=/dev/null
    . /etc/os-release
    case " ${ID} ${ID_LIKE} " in
        *" debian "*|*" ubuntu "*)
            OS_FAMILY=debian
            PACKAGE_MANAGER=apt-get
            command -v dpkg-query >/dev/null 2>&1 || die "缺少 dpkg-query 命令"
            ;;
        *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*|*" alinux "*|*" aliyun "*)
            OS_FAMILY=rhel
            if command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER=dnf
            elif command -v yum >/dev/null 2>&1; then
                PACKAGE_MANAGER=yum
            else
                die "Red Hat 系统缺少 dnf 或 yum"
            fi
            command -v rpm >/dev/null 2>&1 || die "缺少 rpm 命令"
            ;;
        *) die "暂不支持此系统：${PRETTY_NAME:-${ID:-unknown}}" ;;
    esac
    command -v "${PACKAGE_MANAGER}" >/dev/null 2>&1 || die "缺少 ${PACKAGE_MANAGER} 命令"
    command -v systemctl >/dev/null 2>&1 || die "需要 systemd（systemctl）"
    log "检测到系统：${PRETTY_NAME:-${ID}} ${VERSION_ID}，使用 ${PACKAGE_MANAGER}"
}

install_package() {
    if [[ ${OS_FAMILY} == debian ]]; then
        if dpkg-query -W -f='${db:Status-Abbrev}' fail2ban 2>/dev/null | grep -q '^ii'; then
            log "fail2ban 已安装，跳过 apt 安装"
            return
        fi
        log "安装 fail2ban..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y fail2ban
    else
        if rpm -q fail2ban fail2ban-systemd >/dev/null 2>&1; then
            log "fail2ban 及 systemd 后端已安装，跳过 RPM 安装"
            return
        fi
        # Prefer configured vendor repositories, including Alibaba Cloud mirrors.
        # Never infer an EPEL release from Alibaba Cloud Linux's VERSION_ID.
        if ! "${PACKAGE_MANAGER}" -y install fail2ban fail2ban-systemd; then
            log "当前仓库安装失败，尝试安装系统提供的 epel-release 后重试"
            "${PACKAGE_MANAGER}" -y install epel-release ||
                die "无法安装 epel-release，请先配置适用于本系统的 EPEL/扩展仓库（RHEL 可能还需启用 CodeReady Builder）"
            "${PACKAGE_MANAGER}" -y install fail2ban fail2ban-systemd ||
                die "安装 fail2ban 失败，请检查系统仓库、扩展仓库依赖及网络；CentOS 旧版可能需要有效的归档源"
        fi
    fi
}

build_config() {
    mkdir -p "$(dirname "${CONF_FILE}")"
    TEMP_FILE=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
    cat > "${TEMP_FILE}" <<'EOF'
# Managed by hotcoinblockchain/shells install/fail2ban.sh
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
EOF
    if [[ ${OS_FAMILY} == rhel ]]; then
        # Read sshd journal entries even when rsyslog does not create /var/log/secure.
        printf 'backend = systemd\n' >> "${TEMP_FILE}"
    fi
    chmod 0644 "${TEMP_FILE}"
}

install_config() {
    if [[ -f ${CONF_FILE} ]] && cmp -s "${CONF_FILE}" "${TEMP_FILE}"; then
        log "配置已经符合要求，无需修改：${CONF_FILE}"
        return
    fi

    if [[ -f ${CONF_FILE} ]]; then
        BACKUP_FILE=$(mktemp "${CONF_FILE}.backup.XXXXXX")
        cp -a "${CONF_FILE}" "${BACKUP_FILE}"
        HAD_CONFIG=true
    fi

    mv -f -- "${TEMP_FILE}" "${CONF_FILE}"
    TEMP_FILE=""
    CONFIG_CHANGED=true
    log "配置已原子更新：${CONF_FILE}"
}

rollback_config() {
    [[ ${CONFIG_CHANGED} == true ]] || return

    if [[ ${HAD_CONFIG} == true ]]; then
        mv -f -- "${BACKUP_FILE}" "${CONF_FILE}"
        BACKUP_FILE=""
    else
        rm -f -- "${CONF_FILE}"
    fi
    log "已恢复原 fail2ban 配置"
}

apply_config() {
    if [[ ${CONFIG_CHANGED} == true ]]; then
        if ! fail2ban-client -t; then
            rollback_config
            die "fail2ban 配置校验失败，已经回滚"
        fi

        if ! systemctl restart fail2ban.service; then
            rollback_config
            systemctl restart fail2ban.service || true
            die "fail2ban 重启失败，已经回滚配置"
        fi
        log "fail2ban 配置校验及重启成功"
    else
        systemctl start fail2ban.service
    fi

    systemctl enable fail2ban.service
    systemctl is-active --quiet fail2ban.service || die "fail2ban 服务未正常运行"
}

main() {
    require_root
    command -v flock >/dev/null 2>&1 || die "缺少 flock 命令"
    detect_system

    install -d -o root -g root -m 0755 "$(dirname "${CONF_FILE}")"
    exec 9>"${CONF_FILE}.lock"
    flock -n 9 || die "已有另一个 fail2ban 配置进程正在运行"

    install_package
    build_config
    install_config
    apply_config
    log "fail2ban SSH 防护配置完成"
}

main "$@"
