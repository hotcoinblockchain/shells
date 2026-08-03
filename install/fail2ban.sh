#!/usr/bin/env bash

set -Eeuo pipefail

CONF_FILE="${CONF_FILE:-/etc/fail2ban/jail.d/99-hotcoin-sshd.local}"
TEMP_FILE=""
BACKUP_FILE=""
HAD_CONFIG=false
CONFIG_CHANGED=false

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

install_package() {
    if dpkg-query -W -f='${db:Status-Abbrev}' fail2ban 2>/dev/null | grep -q '^ii'; then
        log "fail2ban 已安装，跳过 apt 安装"
        return
    fi

    log "安装 fail2ban..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y fail2ban
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
    install_package

    install -d -o root -g root -m 0755 "$(dirname "${CONF_FILE}")"
    exec 9>"${CONF_FILE}.lock"
    flock -n 9 || die "已有另一个 fail2ban 配置进程正在运行"

    build_config
    install_config
    apply_config
    log "fail2ban SSH 防护配置完成"
}

main "$@"
