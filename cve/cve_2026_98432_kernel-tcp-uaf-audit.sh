#!/usr/bin/env bash
# Requires the adjacent lib/ and rules/ directories; see kernel-tcp-uaf-README.md.
# The default mode temporarily disables MPTCP after saving the original report.
set +x
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

main() {
    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' 'ERROR: python3 >= 3.6 is required; no packages are installed automatically.' >&2
        exit 2
    fi
    if [[ ! -r "$script_dir/lib/kernel_tcp_uaf_audit.py" ]]; then
        printf '%s\n' 'ERROR: missing lib/kernel_tcp_uaf_audit.py; download and verify the complete bundle.' >&2
        exit 2
    fi
    # exec gives Python direct signal ownership. Its handlers preserve the journal.
    exec python3 -I -B "$script_dir/lib/kernel_tcp_uaf_audit.py" "$@"
}

trap 'printf "ERROR: launcher failed at line %s\n" "$LINENO" >&2; exit 2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
