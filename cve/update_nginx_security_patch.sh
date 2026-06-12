#!/usr/bin/env bash

# Update installed nginx packages to the latest patched version available for
# the current OS release. Supports Ubuntu/Debian and CentOS/RHEL/Rocky/Alma.
#
# Usage:
#   bash cve/update_nginx_security_patch.sh
#   bash cve/update_nginx_security_patch.sh --dry-run
#   curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/cve/update_nginx_security_patch.sh | bash -s

set -euo pipefail

DRY_RUN=0
SKIP_RELOAD=0

log() {
    echo "[nginx-cve-update] $*"
}

die() {
    echo "[nginx-cve-update] ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: update_nginx_security_patch.sh [--dry-run] [--skip-reload] [-h|--help]

Update currently installed nginx packages to the latest security patched package
available from the system's configured repositories.

Options:
  --dry-run      Show available package updates without installing them.
  --skip-reload  Do not reload/restart nginx after package update.
  -h, --help     Show this help.

Notes:
  - This script does not add or switch nginx repositories.
  - Run as root, or with a user that can sudo.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --skip-reload)
            SKIP_RELOAD=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "root privileges are required and sudo is not installed"
    SUDO="sudo"
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    [ -r /etc/os-release ] || die "/etc/os-release not found; unsupported system"
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"

    case "$OS_ID $OS_LIKE" in
        *ubuntu*|*debian*)
            OS_FAMILY="debian"
            ;;
        *centos*|*rhel*|*fedora*|*rocky*|*almalinux*)
            OS_FAMILY="rhel"
            ;;
        *)
            die "unsupported OS: ${PRETTY_NAME:-unknown}"
            ;;
    esac

    log "detected system: ${PRETTY_NAME:-$OS_ID}"
}

nginx_installed() {
    if command_exists nginx; then
        return 0
    fi

    case "$OS_FAMILY" in
        debian)
            dpkg-query -W -f='${Status}\n' 'nginx*' 2>/dev/null | grep -q '^install ok installed'
            ;;
        rhel)
            rpm -qa 'nginx*' 2>/dev/null | grep -q '^nginx'
            ;;
        *)
            return 1
            ;;
    esac
}

print_current_version() {
    if command_exists nginx; then
        nginx -v 2>&1 | sed 's/^/[nginx-cve-update] current /'
    fi
}

backup_nginx_config() {
    [ -d /etc/nginx ] || return 0

    backup_dir="/var/backups/nginx-cve-update"
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup_file="${backup_dir}/nginx-config-${timestamp}.tgz"

    $SUDO mkdir -p "$backup_dir"
    $SUDO tar -czf "$backup_file" -C /etc nginx
    log "configuration backup saved: $backup_file"
}

test_nginx_config() {
    if command_exists nginx; then
        log "testing nginx configuration"
        $SUDO nginx -t
    fi
}

reload_nginx() {
    [ "$SKIP_RELOAD" -eq 0 ] || {
        log "skip reload requested"
        return 0
    }

    test_nginx_config

    if command_exists systemctl && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
        log "reloading nginx service"
        $SUDO systemctl reload nginx || $SUDO systemctl restart nginx
    else
        log "reloading nginx with nginx -s reload"
        $SUDO nginx -s reload
    fi
}

debian_installed_nginx_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nginx*' 'libnginx-mod-*' 2>/dev/null \
        | awk '$1 ~ /^ii/ {print $2}' \
        | sort -u
}

update_debian_nginx() {
    command_exists apt-get || die "apt-get not found"

    packages="$(debian_installed_nginx_packages || true)"
    [ -n "$packages" ] || die "no installed nginx packages found"

    log "installed nginx packages:"
    echo "$packages" | sed 's/^/  - /'

    log "refreshing apt package metadata"
    $SUDO apt-get update

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run upgrade preview"
        # shellcheck disable=SC2086
        $SUDO apt-get install --only-upgrade --simulate $packages
        return 0
    fi

    log "upgrading nginx packages from configured apt repositories"
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y $packages
}

rhel_package_manager() {
    if command_exists dnf; then
        echo dnf
    elif command_exists yum; then
        echo yum
    else
        die "dnf/yum not found"
    fi
}

rhel_installed_nginx_packages() {
    rpm -qa --qf '%{NAME}\n' 'nginx*' 2>/dev/null | sort -u
}

update_rhel_nginx() {
    pm="$(rhel_package_manager)"
    packages="$(rhel_installed_nginx_packages || true)"
    [ -n "$packages" ] || die "no installed nginx packages found"

    log "installed nginx packages:"
    echo "$packages" | sed 's/^/  - /'

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run upgrade preview"
        # shellcheck disable=SC2086
        $SUDO "$pm" check-update $packages || rc=$?
        rc="${rc:-0}"
        [ "$rc" -eq 0 ] || [ "$rc" -eq 100 ] || return "$rc"
        return 0
    fi

    log "upgrading nginx packages from configured ${pm} repositories"
    # shellcheck disable=SC2086
    $SUDO "$pm" update -y $packages
}

main() {
    detect_os
    nginx_installed || die "nginx is not installed; refusing to install a new service"

    print_current_version
    test_nginx_config
    [ "$DRY_RUN" -eq 1 ] || backup_nginx_config

    case "$OS_FAMILY" in
        debian)
            update_debian_nginx
            ;;
        rhel)
            update_rhel_nginx
            ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run complete; no packages were changed"
        exit 0
    fi

    print_current_version
    reload_nginx
    log "nginx security patch update complete"
}

main "$@"
