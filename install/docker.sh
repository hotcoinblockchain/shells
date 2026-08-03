#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_DOCKER_ROOT="${DEFAULT_DOCKER_ROOT:-/var/lib/docker}"
readonly DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-/etc/docker/daemon.json}"
CONFIG_CHANGED=false

log() {
    printf '[docker.sh] %s\n' "$*"
}

die() {
    printf '[docker.sh] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Docker 安装、配置和数据迁移工具（仅支持 Debian/Ubuntu）

用法：
  docker.sh install [DATA_DIR]    安装 Docker；可选迁移数据到 DATA_DIR
  docker.sh stop                  停止所有容器及 Docker 服务
  docker.sh start                 启动并设置 Docker 开机自启
  docker.sh configure             写入推荐的日志与 live-restore 配置
  docker.sh migrate DATA_DIR      迁移 Docker 数据到指定的绝对路径并启动
  docker.sh setup DATA_DIR        一键安装、自动配置、迁移并启动
  docker.sh status                显示服务状态和 Docker 数据目录
  docker.sh help                  显示本帮助

示例：
  sudo ./docker.sh install
  sudo ./docker.sh setup /data/docker
  sudo ./docker.sh migrate /mnt/docker-data
  curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh \
    | sudo bash -s -- setup /data/docker

说明：
  - 不传参数时只显示本帮助，不执行任何修改。
  - migrate/setup 要求目标目录为空；迁移成功后不会删除原数据。
EOF
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 运行，例如：sudo $0 $*"
}

require_supported_os() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "当前仅支持 Debian/Ubuntu，检测到：${ID:-unknown}" ;;
    esac
}

validate_data_dir() {
    local data_dir=${1:-}

    [[ -n ${data_dir} ]] || die "缺少 DATA_DIR"
    [[ ${data_dir} == /* ]] || die "DATA_DIR 必须是绝对路径：${data_dir}"
    [[ ${data_dir} != / ]] || die "DATA_DIR 不能是根目录 /"
    [[ ${data_dir} != "${DEFAULT_DOCKER_ROOT}" ]] || die "目标已经是默认 Docker 数据目录"
    [[ ${data_dir}/ != "${DEFAULT_DOCKER_ROOT}/"* ]] || \
        die "DATA_DIR 不能位于 ${DEFAULT_DOCKER_ROOT} 内部"
}

install_docker() {
    local package
    local -a conflicting_packages=()
    local -a required_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    local installation_complete=true

    require_supported_os

    for package in "${required_packages[@]}"; do
        if ! dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null | grep -q '^ii'; then
            installation_complete=false
            break
        fi
    done
    if [[ ${installation_complete} == true ]] && command -v docker >/dev/null 2>&1; then
        log "Docker 已安装：$(docker --version)"
        return
    fi

    log "安装 Docker Engine 和 Compose 插件..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl

    for package in docker.io docker-compose docker-compose-v2 docker-doc \
        podman-docker containerd runc; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null | grep -q '^ii'; then
            conflicting_packages+=("${package}")
        fi
    done
    if (( ${#conflicting_packages[@]} > 0 )); then
        log "移除与 Docker CE 冲突的软件包：${conflicting_packages[*]}"
        apt-get remove -y "${conflicting_packages[@]}"
    fi

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    local arch codename
    arch=$(dpkg --print-architecture)
    codename=${VERSION_CODENAME:-}
    [[ -n ${codename} ]] || die "无法获取系统版本代号 VERSION_CODENAME"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "${arch}" "${ID}" "${codename}" > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y "${required_packages[@]}"
    log "Docker 安装完成：$(docker --version)"
}

write_daemon_config() {
    local data_root=${1:-}
    local tmp_file

    command -v python3 >/dev/null 2>&1 || die "写入配置需要 python3"
    install -d -m 0755 "$(dirname "${DOCKER_CONFIG_FILE}")"
    tmp_file=$(mktemp "${DOCKER_CONFIG_FILE}.tmp.XXXXXX")

    python3 - "${DOCKER_CONFIG_FILE}" "${data_root}" > "${tmp_file}" <<'PY'
import json
import os
import sys

config_path, data_root = sys.argv[1:]
config = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as file:
            config = json.load(file)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"无法解析 {config_path}: {exc}")
    if not isinstance(config, dict):
        raise SystemExit(f"{config_path} 的顶层必须是 JSON 对象")

config["log-driver"] = "json-file"
log_options = config.setdefault("log-opts", {})
if not isinstance(log_options, dict):
    log_options = config["log-opts"] = {}
log_options.setdefault("max-size", "100m")
log_options.setdefault("max-file", "3")
config["live-restore"] = True
if data_root:
    config["data-root"] = data_root

print(json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True))
PY

    chmod 0644 "${tmp_file}"
    if command -v dockerd >/dev/null 2>&1 && \
        ! dockerd --validate --config-file="${tmp_file}" >/dev/null; then
        rm -f "${tmp_file}"
        die "生成的 Docker 配置校验失败，未修改 ${DOCKER_CONFIG_FILE}"
    fi
    if [[ -f ${DOCKER_CONFIG_FILE} ]] && cmp -s "${DOCKER_CONFIG_FILE}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        CONFIG_CHANGED=false
        log "${DOCKER_CONFIG_FILE} 已符合要求，无需修改"
        return
    fi
    if [[ -f ${DOCKER_CONFIG_FILE} ]]; then
        cp -a "${DOCKER_CONFIG_FILE}" "${DOCKER_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    mv -f "${tmp_file}" "${DOCKER_CONFIG_FILE}"
    CONFIG_CHANGED=true
    log "已原子更新 ${DOCKER_CONFIG_FILE}"
}

stop_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local containers
        containers=$(docker ps -q)
        if [[ -n ${containers} ]]; then
            log "停止所有运行中的容器..."
            # shellcheck disable=SC2086
            docker stop ${containers}
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        local unit
        log "停止 Docker 服务..."
        for unit in docker.service docker.socket containerd.service; do
            systemctl stop "${unit}" 2>/dev/null || true
            if systemctl is-active --quiet "${unit}"; then
                die "无法停止 ${unit}；为保护数据，已取消后续操作"
            fi
        done
    else
        die "当前系统不支持 systemctl"
    fi
}

start_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker 未安装，请先运行 install"
    log "启动 Docker 并设置开机自启..."
    systemctl enable containerd.service docker.service || return 1
    systemctl start containerd.service docker.service || return 1
    docker info >/dev/null || return 1
    log "Docker 已启动，数据目录：$(docker info --format '{{.DockerRootDir}}')"
}

restart_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker 未安装，请先运行 install"
    log "重启 Docker 以应用配置..."
    systemctl enable containerd.service docker.service || return 1
    systemctl restart containerd.service docker.service || return 1
    docker info >/dev/null || return 1
    log "Docker 配置已生效，数据目录：$(docker info --format '{{.DockerRootDir}}')"
}

apply_or_start_docker() {
    if [[ ${CONFIG_CHANGED} == true ]] && systemctl is-active --quiet docker.service; then
        restart_docker
    else
        start_docker
    fi
}

current_docker_root() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker info --format '{{.DockerRootDir}}'
        return
    fi

    python3 - "${DOCKER_CONFIG_FILE}" "${DEFAULT_DOCKER_ROOT}" <<'PY'
import json
import os
import sys

path, default = sys.argv[1:]
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as file:
            print(json.load(file).get("data-root", default))
    except (OSError, json.JSONDecodeError, AttributeError):
        print(default)
else:
    print(default)
PY
}

migrate_data() {
    local target_dir=$1
    local source_dir
    local config_backup
    local had_config=false

    validate_data_dir "${target_dir}"
    command -v docker >/dev/null 2>&1 || die "Docker 未安装，请先运行 install"
    command -v rsync >/dev/null 2>&1 || {
        log "安装迁移所需的 rsync..."
        apt-get update
        apt-get install -y rsync
    }

    source_dir=$(current_docker_root)
    source_dir=${source_dir%/}
    target_dir=${target_dir%/}

    if [[ ${source_dir} == "${target_dir}" ]]; then
        log "Docker 已使用目标目录，无需迁移"
        write_daemon_config "${target_dir}"
        apply_or_start_docker
        return
    fi
    [[ -d ${source_dir} ]] || die "源数据目录不存在：${source_dir}"
    [[ ${target_dir}/ != "${source_dir}/"* ]] || die "目标目录不能位于源目录内部"
    if [[ -d ${target_dir} && -n $(find "${target_dir}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        die "目标目录不是空目录：${target_dir}"
    fi

    install -d -m 0711 "${target_dir}"
    stop_docker
    log "从 ${source_dir} 迁移数据到 ${target_dir}..."
    if ! rsync -aHAX --numeric-ids --info=progress2 "${source_dir}/" "${target_dir}/"; then
        start_docker || true
        die "数据复制失败；Docker 已尝试使用原目录重新启动"
    fi

    config_backup=$(mktemp)
    if [[ -f ${DOCKER_CONFIG_FILE} ]]; then
        cp -a "${DOCKER_CONFIG_FILE}" "${config_backup}"
        had_config=true
    fi
    write_daemon_config "${target_dir}"

    if ! start_docker; then
        log "新目录启动失败，恢复原 Docker 配置..."
        if [[ ${had_config} == true ]]; then
            install -m 0644 "${config_backup}" "${DOCKER_CONFIG_FILE}"
        else
            rm -f "${DOCKER_CONFIG_FILE}"
        fi
        rm -f "${config_backup}"
        start_docker || true
        die "迁移已回滚；原数据仍位于 ${source_dir}，请检查 journalctl -u docker"
    fi
    rm -f "${config_backup}"
    log "迁移完成；确认业务正常后，可自行清理原目录 ${source_dir}"
}

show_status() {
    command -v docker >/dev/null 2>&1 || die "Docker 未安装"
    systemctl --no-pager --full status docker.service || true
    if docker info >/dev/null 2>&1; then
        printf '\nDocker version: %s\n' "$(docker --version)"
        printf 'Compose version: %s\n' "$(docker compose version 2>/dev/null || printf 'not installed')"
        printf 'Docker root:    %s\n' "$(docker info --format '{{.DockerRootDir}}')"
    fi
}

main() {
    local command=${1:-}

    case "${command}" in
        ''|-h|--help|help)
            usage
            ;;
        install)
            [[ $# -le 2 ]] || die "install 最多接受一个 DATA_DIR 参数"
            require_root "$@"
            install_docker
            if [[ -n ${2:-} ]]; then
                migrate_data "$2"
            else
                write_daemon_config
                apply_or_start_docker
            fi
            ;;
        stop)
            [[ $# -eq 1 ]] || die "stop 不接受额外参数"
            require_root "$@"
            stop_docker
            log "Docker 已停止"
            ;;
        start)
            [[ $# -eq 1 ]] || die "start 不接受额外参数"
            require_root "$@"
            start_docker
            ;;
        configure)
            [[ $# -eq 1 ]] || die "configure 不接受额外参数；请使用 migrate DATA_DIR"
            require_root "$@"
            write_daemon_config
            apply_or_start_docker
            ;;
        migrate)
            [[ $# -eq 2 ]] || die "用法：docker.sh migrate DATA_DIR"
            require_root "$@"
            migrate_data "$2"
            ;;
        setup)
            [[ $# -eq 2 ]] || die "用法：docker.sh setup DATA_DIR"
            require_root "$@"
            install_docker
            migrate_data "$2"
            ;;
        status)
            [[ $# -eq 1 ]] || die "status 不接受额外参数"
            show_status
            ;;
        *)
            usage >&2
            die "未知命令：${command}"
            ;;
    esac
}

main "$@"
