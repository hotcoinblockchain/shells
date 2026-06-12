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
    else
        log "Cloning ${repo} to ${target}..."
        git clone "$repo" "$target"
    fi
}

append_bashrc_line() {
    local line="$1"

    touch "$BASHRC"
    if grep -Fxq "$line" "$BASHRC"; then
        log "Already exists in ${BASHRC}: ${line}"
    else
        echo "$line" >> "$BASHRC"
        log "Added to ${BASHRC}: ${line}"
    fi
}

setup_shell_env() {
    log "Configuring pyenv environment in ${BASHRC}..."
    append_bashrc_line 'export PYENV_ROOT="$HOME/.pyenv"'
    append_bashrc_line 'export PATH="$PYENV_ROOT/bin:$PATH"'
    append_bashrc_line 'export PATH="$PYENV_ROOT/shims:$PATH"'
    append_bashrc_line 'eval "$(pyenv init -)"'
    append_bashrc_line 'eval "$(pyenv virtualenv-init -)"'
}

write_pyenvs_helper() {
    log "Writing helper: ${PYENVS_BIN}"
    mkdir -p "$(dirname "$PYENVS_BIN")"

    cat > "$PYENVS_BIN" <<'EOF'
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

    chmod +x "$PYENVS_BIN"
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
