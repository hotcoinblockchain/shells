#!/usr/bin/env bash

###
# Usage:
#   # Install latest stable Go
#   curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s
#
#   # Install exact version
#   curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24.3
#
#   # Install latest patch version in a minor release line
#   curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24
#
#   source /etc/profile

set -euo pipefail

GO_DL_API="https://go.dev/dl/?mode=json&include=all"
INSTALL_DIR="/usr/local"
GO_ROOT="${INSTALL_DIR}/go"
PROFILE_FILE="/etc/profile"
REQUESTED_VERSION="${1:-}"

log() {
    echo "[INFO] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64)
            echo "amd64"
            ;;
        aarch64 | arm64)
            echo "arm64"
            ;;
        armv6l | armv7l)
            echo "armv6l"
            ;;
        i386 | i686)
            echo "386"
            ;;
        *)
            die "Unsupported architecture: $(uname -m)"
            ;;
    esac
}

fetch_go_releases() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$GO_DL_API"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$GO_DL_API"
    else
        die "Missing curl or wget."
    fi
}

normalize_version() {
    local version="$1"
    version="${version#go}"
    echo "$version"
}

resolve_go_version() {
    local requested
    local releases

    requested="$(normalize_version "$1")"
    releases="$2"

    if [ -z "$requested" ]; then
        printf '%s\n' "$releases" | awk '
            /"version"[[:space:]]*:/ {
                line = $0
                sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*$/, "", line)
                if (line ~ /^go[0-9]+\.[0-9]+(\.[0-9]+)?$/) {
                    print line
                    exit
                }
            }
        '
        return
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local exact="go${requested}"
        if printf '%s\n' "$releases" | grep -q "\"version\"[[:space:]]*:[[:space:]]*\"${exact}\""; then
            echo "$exact"
            return
        fi
        die "Go version not found: ${requested}"
    fi

    if [[ "$requested" =~ ^[0-9]+\.[0-9]+$ ]]; then
        local minor_regex
        minor_regex="$(printf '%s' "$requested" | sed 's/\./\\./g')"
        local matched
        matched="$(printf '%s\n' "$releases" | awk -v pattern="^go${minor_regex}\\.[0-9]+$" '
            /"version"[[:space:]]*:/ {
                line = $0
                sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*$/, "", line)
                if (line ~ pattern) {
                    print line
                    exit
                }
            }
        ')"
        [ -n "$matched" ] || die "No stable patch release found for Go ${requested}."
        echo "$matched"
        return
    fi

    die "Invalid version format: ${1}. Use empty, 1.24, 1.24.3, or go1.24.3."
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$output"
    else
        wget -O "$output" "$url"
    fi
}

ensure_profile() {
    if ! grep -q "export GOROOT=${GO_ROOT}" "$PROFILE_FILE"; then
        cp -a "$PROFILE_FILE" "${PROFILE_FILE}.$(date +%Y%m%d%H%M).bak"
        cat >> "$PROFILE_FILE" <<EOF

###### go environment #######
export GOROOT=${GO_ROOT}
export GOPATH=\$HOME/go
export GOBIN=\$GOPATH/bin
export PATH=\$GOBIN:\$GOROOT/bin:\$PATH
EOF
        log "Go environment added to ${PROFILE_FILE}."
    else
        log "Go environment already exists in ${PROFILE_FILE}."
    fi
}

main() {
    need_root
    need_command tar
    need_command awk
    need_command grep
    need_command sed

    local goos="linux"
    local goarch
    local releases
    local version
    local filename
    local download_url
    local tmp_dir
    local archive

    goarch="$(detect_arch)"
    log "Fetching Go release list from official API..."
    releases="$(fetch_go_releases)"

    version="$(resolve_go_version "$REQUESTED_VERSION" "$releases")"
    [ -n "$version" ] || die "Cannot resolve Go version."

    filename="${version}.${goos}-${goarch}.tar.gz"
    if ! printf '%s\n' "$releases" | grep -q "\"filename\"[[:space:]]*:[[:space:]]*\"${filename}\""; then
        die "Release archive not found for ${version} ${goos}/${goarch}."
    fi

    download_url="https://go.dev/dl/${filename}"
    tmp_dir="$(mktemp -d)"
    archive="${tmp_dir}/${filename}"

    log "Installing ${version} for ${goos}/${goarch}..."
    log "Downloading ${download_url}"
    download_file "$download_url" "$archive"

    rm -rf "$GO_ROOT"
    tar -C "$INSTALL_DIR" -xzf "$archive"
    mkdir -p "$HOME/go/bin"
    ensure_profile

    rm -rf "$tmp_dir"

    log "Installed: $("${GO_ROOT}/bin/go" version)"
    log "Run 'source /etc/profile' or open a new shell before using go from PATH."
}

main "$@"
