#!/usr/bin/env bash

###
# Usage:
#   curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
#
# After installation:
#   source ~/.bashrc
#
# pyenvs cron example:
#   0 8 * * * /root/.pyenv/bin/pyenvs 3.10.12 /root/apps/autosign/aliyun-auto-signin/app.py

set -euo pipefail

PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
BASHRC="${HOME}/.bashrc"
PYENV_REPO="https://github.com/pyenv/pyenv.git"
PYENV_VIRTUALENV_REPO="https://github.com/yyuu/pyenv-virtualenv.git"
PYENVS_BIN="${PYENV_ROOT}/bin/pyenvs"
BEGIN_MARKER="# BEGIN HOTCOIN PYENV SETTINGS"
END_MARKER="# END HOTCOIN PYENV SETTINGS"

log() {
    echo "[INFO] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_ubuntu() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        [ "${ID:-}" = "ubuntu" ] || log "Current system is ${PRETTY_NAME:-unknown}; this script is mainly tested on Ubuntu."
    else
        log "Cannot detect OS; this script is mainly tested on Ubuntu."
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        need_command sudo
        sudo "$@"
    fi
}

install_python_build_deps() {
    log "Installing Python build dependencies..."
    run_as_root apt-get update
    run_as_root apt-get install -y \
        build-essential \
        ca-certificates \
        curl \
        git \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libncursesw5-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        libxmlsec1-dev \
        llvm \
        make \
        tk-dev \
        wget \
        xz-utils \
        zlib1g-dev
}

clone_or_update_repo() {
    local repo="$1"
    local target="$2"

    if [ -d "${target}/.git" ]; then
        log "${target} already exists, updating..."
        git -C "$target" pull --ff-only
    elif [ -e "$target" ]; then
        die "Target exists but is not a Git repository: ${target}"
    else
        log "Cloning ${repo} to ${target}..."
        git clone "$repo" "$target"
    fi
}

setup_shell_env() {
    local temp_file trimmed_file original_mode

    log "Configuring pyenv environment in ${BASHRC}..."
    touch "$BASHRC"
    temp_file=$(mktemp "${BASHRC}.tmp.XXXXXX")
    trimmed_file="${temp_file}.trimmed"

    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        BEGIN { in_managed = 0 }
        $0 == begin { in_managed = 1; next }
        $0 == end { in_managed = 0; next }
        in_managed { next }
        # 清理旧版本脚本逐行追加的配置。
        $0 == "export PYENV_ROOT=\"$HOME/.pyenv\"" { next }
        $0 == "export PATH=\"$PYENV_ROOT/bin:$PATH\"" { next }
        $0 == "export PATH=\"$PYENV_ROOT/shims:$PATH\"" { next }
        $0 == "eval \"$(pyenv init -)\"" { next }
        $0 == "eval \"$(pyenv virtualenv-init -)\"" { next }
        { print }
    ' "$BASHRC" > "$temp_file"

    awk 'NF { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }' \
        "$temp_file" > "$trimmed_file"
    mv -f "$trimmed_file" "$temp_file"

    if [ -s "$temp_file" ]; then
        printf '\n' >> "$temp_file"
    fi
    cat >> "$temp_file" <<EOF
${BEGIN_MARKER}
export PYENV_ROOT="\$HOME/.pyenv"
case ":\$PATH:" in
    *":\$PYENV_ROOT/bin:"*) ;;
    *) export PATH="\$PYENV_ROOT/bin:\$PATH" ;;
esac
case ":\$PATH:" in
    *":\$PYENV_ROOT/shims:"*) ;;
    *) export PATH="\$PYENV_ROOT/shims:\$PATH" ;;
esac
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
${END_MARKER}
EOF

    if cmp -s "$BASHRC" "$temp_file"; then
        rm -f "$temp_file"
        log "Shell configuration already up to date: ${BASHRC}"
        return
    fi

    original_mode=$(stat -c '%a' "$BASHRC" 2>/dev/null || stat -f '%Lp' "$BASHRC")
    chmod "$original_mode" "$temp_file"
    mv -f "$temp_file" "$BASHRC"
    log "Shell configuration updated atomically: ${BASHRC}"
}

write_pyenvs_helper() {
    local temp_file

    log "Writing helper: ${PYENVS_BIN}"
    mkdir -p "$(dirname "$PYENVS_BIN")"
    temp_file=$(mktemp "${PYENVS_BIN}.tmp.XXXXXX")

    cat > "$temp_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"

eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
#. /home/$USER/.bashrc

if [ $# -lt 2 ]; then
    echo "Usage: pyenvs <python_version> <script_path> <script_arguments>"
    exit 1
fi

python_version="$1"
script_path="$2"
shift 2

if [ ! -f "$script_path" ]; then
    echo "Error: script path does not exist: $script_path"
    exit 1
fi

# Check if the specified Python version exists
if ! pyenv versions --bare | grep -Fxq "$python_version"; then
    echo "Error: Python version '$python_version' does not exist."
    echo "Available versions:"
    pyenv versions
    exit 1
fi

pyenv shell "$python_version"
cd "$(dirname "$script_path")"

if [ $# -eq 0 ]; then
    python "$(basename "$script_path")"
else
    python "$(basename "$script_path")" "$@"
fi

# usage in crontab
# 0 8 * * * pyenvs <python_version> <script_path> <script_arguments>
# 0 8 * * * /root/.pyenv/bin/pyenvs 3.10.12 /root/apps/autosign/aliyun-auto-signin/app.py
EOF

    chmod 0755 "$temp_file"
    if [ -f "$PYENVS_BIN" ] && cmp -s "$PYENVS_BIN" "$temp_file"; then
        rm -f "$temp_file"
        log "Helper already up to date: ${PYENVS_BIN}"
    else
        mv -f "$temp_file" "$PYENVS_BIN"
        log "Helper updated atomically: ${PYENVS_BIN}"
    fi
}

main() {
    need_ubuntu
    need_command grep

    install_python_build_deps
    clone_or_update_repo "$PYENV_REPO" "$PYENV_ROOT"
    clone_or_update_repo "$PYENV_VIRTUALENV_REPO" "${PYENV_ROOT}/plugins/pyenv-virtualenv"
    setup_shell_env
    write_pyenvs_helper

    # Load pyenv in the current non-interactive shell for final verification.
    export PYENV_ROOT
    export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)"

    log "Installed: $(pyenv --version)"
    log "Run 'source ~/.bashrc' or open a new shell before using pyenv from PATH."
    log "Helper installed: ${PYENVS_BIN}"
}

main "$@"
