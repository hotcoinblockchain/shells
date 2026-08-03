#!/usr/bin/env bash

set -Eeuo pipefail

LIMITS_FILE="${LIMITS_FILE:-/etc/security/limits.d/99-blockchain.conf}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-blockchain.conf}"

log() {
    printf '[ulimit_settings.sh] %s\n' "$*"
}

die() {
    printf '[ulimit_settings.sh] ERROR: %s\n' "$*" >&2
    exit 1
}

run_as_root() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "缺少 sudo，请使用 root 执行"
        sudo "$@"
    fi
}

atomic_install() {
    local source_file=$1
    local target_file=$2
    local target_tmp

    run_as_root install -d -m 0755 "$(dirname "${target_file}")"
    if run_as_root test -f "${target_file}" && run_as_root cmp -s "${source_file}" "${target_file}"; then
        log "配置未变化，跳过：${target_file}"
        return
    fi

    target_tmp=$(run_as_root mktemp "${target_file}.tmp.XXXXXX")
    if ! run_as_root install -m 0644 "${source_file}" "${target_tmp}"; then
        run_as_root rm -f -- "${target_tmp}"
        die "无法生成临时配置：${target_file}"
    fi
    run_as_root mv -f -- "${target_tmp}" "${target_file}"
    log "配置已更新：${target_file}"
}

main() {
    local limits_tmp sysctl_tmp

    limits_tmp=$(mktemp)
    sysctl_tmp=$(mktemp)
    trap 'rm -f -- "${limits_tmp:-}" "${sysctl_tmp:-}"' EXIT

    cat > "${limits_tmp}" <<'EOF'
# Managed by hotcoinblockchain/shells devops/ulimit_settings.sh
# <domain>      <type>  <item>         <value>
*               soft    nofile         1048576
*               hard    nofile         1048576
root            soft    nofile         1048576
root            hard    nofile         1048576
EOF

    cat > "${sysctl_tmp}" <<'EOF'
# Managed by hotcoinblockchain/shells devops/ulimit_settings.sh
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF

    atomic_install "${limits_tmp}" "${LIMITS_FILE}"
    atomic_install "${sysctl_tmp}" "${SYSCTL_FILE}"

    log "应用 sysctl 配置..."
    run_as_root sysctl -e -p "${SYSCTL_FILE}"

    if ! ulimit -n 1048576 2>/dev/null; then
        log "当前 shell 无法临时提升到 1048576；永久配置将在重新登录后生效"
    fi

    log "当前 shell nofile：$(ulimit -n)"
    run_as_root cat "${SYSCTL_FILE}"
    run_as_root cat "${LIMITS_FILE}"
}

main "$@"
