#!/usr/bin/env bash
# Paste this entire file into Alibaba Cloud Cloud Assistant (Bash).
set +x
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Configuration: do not commit real credentials to the public repository.
COMMIT='a01a291c2545540cbcfa53006c7db576cda8d322'
LARK_WEBHOOK=''  # Fill in the console script, not in the public repository.
LARK_SECRET=''   # Optional robot signing secret.
MODE='--disable-mptcp' # --check-only or --disable-mptcp
ALERT_MODE='risk'      # risk, always, none
ALERT_UNKNOWN=true
DRY_RUN=false
OUTPUT='' # Use the auditor's private journal; optional extra output requires a trusted parent.

TASK_DIR=''
CHILD_PID=''
log() { printf '%s [bootstrap] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "$*"; exit 2; }
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $TASK_DIR && $TASK_DIR == /tmp/kernel-tcp-uaf-bootstrap.* && -d $TASK_DIR && ! -L $TASK_DIR ]]; then
        rm -rf -- "$TASK_DIR" || log 'Temporary directory cleanup failed.'
    fi
    exit "$status"
}
interrupted() {
    local status=$1
    trap '' INT TERM
    if [[ -n $CHILD_PID ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'log "Bootstrap failed at line $LINENO"; exit 2' ERR

[[ $(uname -s) == Linux ]] || die 'Linux is required.'
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'COMMIT must contain exactly 40 hexadecimal characters.'
[[ $MODE == --disable-mptcp || $MODE == --check-only ]] || die 'Invalid MODE.'
[[ $ALERT_MODE == risk || $ALERT_MODE == always || $ALERT_MODE == none ]] || die 'Invalid ALERT_MODE.'
[[ $ALERT_UNKNOWN == true || $ALERT_UNKNOWN == false ]] || die 'Invalid ALERT_UNKNOWN.'
[[ $DRY_RUN == true || $DRY_RUN == false ]] || die 'Invalid DRY_RUN.'
for command in curl sha256sum python3 mktemp bash; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
done
python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)' || die 'Python 3.6+ is required.'
if [[ $MODE == --disable-mptcp && $DRY_RUN == false && $EUID -ne 0 ]]; then
    die 'Run the Cloud Assistant command as root for mitigation.'
fi
if [[ $ALERT_MODE != none && -z $LARK_WEBHOOK ]]; then
    die 'Fill in LARK_WEBHOOK, or explicitly set ALERT_MODE=none.'
fi
TASK_DIR=$(mktemp -d /tmp/kernel-tcp-uaf-bootstrap.XXXXXXXX)
mkdir -m 700 -- "$TASK_DIR/lib" "$TASK_DIR/rules"

# These hashes are bound to COMMIT. Update all three when changing COMMIT.
cat > "$TASK_DIR/SHA256SUMS" <<'HASHES'
acd7db78fc66bda2e37d03077afe9cceeebfa29ad28d908142114fcccb0707cd  linux-kernel-tcp-uaf-audit.sh
a532b101c54c493bdd6d8242ea2ef72983ec71017048f81a2512e9dc8bd9ba22  lib/kernel_tcp_uaf_audit.py
764029ffe6a149c315c6b27754469b2331ca8d25f4c5491faf73d410cec6720a  rules/kernel-tcp-uaf.json
HASHES
for file in linux-kernel-tcp-uaf-audit.sh lib/kernel_tcp_uaf_audit.py rules/kernel-tcp-uaf.json; do
    log "Downloading $file"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
        --connect-timeout 5 --max-time 60 --retry 2 --retry-max-time 150 \
        --output "$TASK_DIR/$file" \
        "https://raw.githubusercontent.com/hotcoinblockchain/shells/$COMMIT/cve/$file"
done
(cd -- "$TASK_DIR" && sha256sum --check --strict SHA256SUMS)
bash -n "$TASK_DIR/linux-kernel-tcp-uaf-audit.sh"
args=("$MODE" --alert-mode "$ALERT_MODE")
[[ $ALERT_UNKNOWN == false ]] || args+=(--alert-unknown)
[[ $DRY_RUN == false ]] || args+=(--dry-run)
[[ -z $OUTPUT ]] || args+=(--output "$OUTPUT")
if [[ $ALERT_MODE != none ]]; then
    printf '%s' "$LARK_WEBHOOK" > "$TASK_DIR/webhook"
    args+=(--lark-webhook-file "$TASK_DIR/webhook")
    if [[ -n $LARK_SECRET ]]; then
        printf '%s' "$LARK_SECRET" > "$TASK_DIR/secret"
        args+=(--lark-secret-file "$TASK_DIR/secret")
    fi
fi
unset LARK_WEBHOOK LARK_SECRET
log 'Verified bundle; starting audit. Persistent audit reports are retained.'
bash "$TASK_DIR/linux-kernel-tcp-uaf-audit.sh" "${args[@]}" &
CHILD_PID=$!
status=0
wait "$CHILD_PID" || status=$?
CHILD_PID=''
log "Audit exit code: $status (0=clear, 1=risk, 2=error, 3=unknown, 4=mitigation failed)"
exit "$status"
