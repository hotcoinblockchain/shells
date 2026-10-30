#!/usr/bin/env bash
# Debian/Ubuntu 系统备份与迁移脚本
# 备份：/root、/home、/usr/local、常见服务目录与配置、APT/服务/crontab 元数据
# 恢复：安装手动安装的 APT 包、还原文件与 crontab、恢复 systemd enable 状态

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

TEMP_DIR=""
PARTIAL_ARCHIVE=""
ASSUME_YES=false
DRY_RUN=false

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
  if [[ -n "${PARTIAL_ARCHIVE}" && -f "${PARTIAL_ARCHIVE}" ]]; then
    rm -f -- "${PARTIAL_ARCHIVE}"
  fi
}
trap cleanup EXIT
trap 'die "第 ${LINENO} 行执行失败"' ERR

usage() {
  cat <<'EOF'
用法：
  system_migrate.sh backup [选项]
  system_migrate.sh restore --archive <备份包> [选项]
  system_migrate.sh inspect --archive <备份包>

备份选项：
  -o, --output FILE          备份包完整路径，扩展名决定格式：
                             .tar、.tar.gz、.tgz、.zip
                             （默认：当前目录/HOST_YYYYmmdd_HHMMSS.tar.gz）
      --include PATH         额外备份绝对路径，可重复
      --exclude PATTERN      额外 tar 排除模式，可重复
      --include-service-data 额外包含常见服务数据目录（见下方说明）
  -y, --yes                  不询问确认

恢复选项：
  -a, --archive FILE         要恢复的备份包
      --skip-packages        不通过 apt 安装原机器的手动安装包
      --skip-files           不恢复文件
      --skip-crontabs        不恢复用户 crontab
      --skip-services        不恢复 systemd enable 状态
      --dry-run              只显示恢复计划，不做任何更改
  -y, --yes                  不询问确认（适合自动化）

inspect 只读取备份包，显示来源机器、时间、系统版本和内容概要。

默认文件范围：
  /root /home /usr/local /opt /srv /var/www，以及 /etc 下的 APT、SSH、
  systemd、cron、sudo、网络、防火墙、Web、数据库、容器等常见配置。

--include-service-data 还会尝试包含：
  /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/lib/docker
  /var/lib/containerd /var/lib/mongodb /var/lib/rabbitmq
注意：在线复制数据库文件可能不一致。生产迁移应先停服务，或另外执行
mysqldump、pg_dump/pg_dumpall、redis BGSAVE 等原生备份。

示例：
  sudo ./system_migrate.sh backup -o /mnt/backup/server-a.tar.gz
  sudo ./system_migrate.sh backup -o /mnt/backup/server-a.tar
  sudo ./system_migrate.sh backup -o /mnt/backup/server-a.zip
  sudo ./system_migrate.sh backup -o /mnt/backup/web-01.tar.gz --yes
  ./system_migrate.sh inspect -a /mnt/backup/web-01.tar.gz
  sudo ./system_migrate.sh restore -a /mnt/backup/web-01.tar.gz --dry-run
  sudo ./system_migrate.sh restore -a /mnt/backup/web-01.tar.gz
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "该操作需要 root 权限，请使用 sudo 运行"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

archive_type() {
  case "$1" in
    *.tar.gz|*.tgz) printf 'tar.gz\n' ;;
    *.tar)          printf 'tar\n' ;;
    *.zip)          printf 'zip\n' ;;
    *) die "不支持的备份包扩展名：$1（支持 .tar、.tar.gz、.tgz、.zip）" ;;
  esac
}

list_archive() {
  local archive="$1"
  case "$(archive_type "${archive}")" in
    tar)    tar -tf "${archive}" ;;
    tar.gz) tar -tzf "${archive}" ;;
    zip)    require_command unzip; unzip -p "${archive}" | tar -tf - ;;
  esac
}

make_temp_dir() {
  local temp_base="${TMPDIR:-/var/tmp}"
  TEMP_DIR="$(mktemp -d "${temp_base%/}/system-migrate.XXXXXXXX")"
}

confirm() {
  local prompt="$1" answer
  ${ASSUME_YES} && return 0
  [[ -t 0 ]] || die "非交互环境必须使用 --yes"
  read -r -p "${prompt} [y/N] " answer
  [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

write_if_command() {
  local output="$1"
  shift
  if command -v "$1" >/dev/null 2>&1; then
    "$@" >"${output}" 2>&1 || true
  else
    printf 'command not found: %s\n' "$1" >"${output}"
  fi
}

collect_metadata() {
  local meta_dir="$1"
  mkdir -p "${meta_dir}/apt" "${meta_dir}/systemd" "${meta_dir}/crontabs" \
    "${meta_dir}/accounts" "${meta_dir}/inventory"

  {
    printf 'format_version=1\n'
    printf 'script_version=%s\n' "${SCRIPT_VERSION}"
    printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'hostname=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'kernel=%s\n' "$(uname -srmo)"
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      printf 'os_id=%s\n' "${ID:-unknown}"
      printf 'os_version=%s\n' "${VERSION_ID:-unknown}"
      printf 'os_pretty_name=%s\n' "${PRETTY_NAME:-unknown}"
    fi
  } >"${meta_dir}/manifest"

  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n' \
      >"${meta_dir}/apt/dpkg-packages.tsv"
  fi
  write_if_command "${meta_dir}/apt/manual-packages.txt" apt-mark showmanual
  write_if_command "${meta_dir}/apt/held-packages.txt" apt-mark showhold
  if command -v debconf-get-selections >/dev/null 2>&1; then
    debconf-get-selections >"${meta_dir}/apt/debconf-selections.txt" 2>/dev/null || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager \
      2>/dev/null | awk '{print $1}' >"${meta_dir}/systemd/enabled-services.txt" || true
    systemctl list-units --type=service --state=running --no-legend --no-pager \
      2>/dev/null | awk '{print $1}' >"${meta_dir}/systemd/running-services.txt" || true
    systemctl list-timers --all --no-pager >"${meta_dir}/systemd/timers.txt" 2>&1 || true
  fi

  getent passwd >"${meta_dir}/accounts/passwd.txt"
  getent group >"${meta_dir}/accounts/group.txt"
  getent passwd | while IFS=: read -r user _; do
    if command -v crontab >/dev/null 2>&1 && crontab -l -u "${user}" >/dev/null 2>&1; then
      crontab -l -u "${user}" >"${meta_dir}/crontabs/${user}"
    fi
  done

  write_if_command "${meta_dir}/inventory/lsblk.txt" lsblk -f
  write_if_command "${meta_dir}/inventory/mounts.txt" findmnt
  write_if_command "${meta_dir}/inventory/ip-address.txt" ip -brief address
  write_if_command "${meta_dir}/inventory/listening-ports.txt" ss -lntup
  write_if_command "${meta_dir}/inventory/docker-version.txt" docker version
  write_if_command "${meta_dir}/inventory/docker-images.txt" docker image ls --digests
  write_if_command "${meta_dir}/inventory/snap-list.txt" snap list
  write_if_command "${meta_dir}/inventory/flatpak-list.txt" flatpak list
}

add_existing_path() {
  local path="$1" list_file="$2" relative
  [[ "${path}" == /* ]] || die "备份路径必须是绝对路径：${path}"
  [[ "${path}" != "/" ]] || die "拒绝把整个 / 作为额外路径，请指定更精确的目录"
  relative="${path#/}"
  if [[ -e "${path}" || -L "${path}" ]]; then
    printf '%s\0' "${relative}" >>"${list_file}"
  fi
}

backup_main() {
  local output=""
  local format=""
  local include_service_data=false
  local -a extra_includes=() extra_excludes=()

  while (($#)); do
    case "$1" in
      -o|--output) [[ $# -ge 2 ]] || die "$1 缺少参数"; output="$2"; shift 2 ;;
      --include) [[ $# -ge 2 ]] || die "$1 缺少参数"; extra_includes+=("$2"); shift 2 ;;
      --exclude) [[ $# -ge 2 ]] || die "$1 缺少参数"; extra_excludes+=("$2"); shift 2 ;;
      --include-service-data) include_service_data=true; shift ;;
      -y|--yes) ASSUME_YES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知备份选项：$1" ;;
    esac
  done

  require_root
  require_command tar
  require_command mktemp
  tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar' \
    || die "当前脚本需要 GNU tar（Debian/Ubuntu 默认提供）"

  if [[ -z "${output}" ]]; then
    output="$(pwd -P)/$(hostname -s)_$(date +%Y%m%d_%H%M%S).tar.gz"
  fi
  output="$(readlink -m -- "${output}")"
  [[ "${output}" != "/" ]] || die "无效输出路径"
  format="$(archive_type "${output}")"
  if [[ "${format}" == "zip" ]]; then
    require_command zip
  fi

  if [[ -e "${output}" ]] && ! confirm "文件已存在，是否覆盖：${output}？"; then
    die "操作已取消"
  fi
  mkdir -p -- "$(dirname -- "${output}")"
  [[ -w "$(dirname -- "${output}")" ]] || die "输出目录不可写：$(dirname -- "${output}")"

  if ${include_service_data}; then
    warn "已请求备份在线服务数据。请确认数据库服务已停止或已完成一致性快照。"
    confirm "仍要继续吗？" || die "操作已取消"
  fi

  make_temp_dir
  local bundle_meta="${TEMP_DIR}/.system-migrate"
  local path_list="${TEMP_DIR}/paths.list"
  : >"${path_list}"
  collect_metadata "${bundle_meta}"

  local -a default_paths=(
    /root /home /usr/local /opt /srv /var/www
    /etc/apt /etc/ssh /etc/sudoers /etc/sudoers.d
    /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly
    /etc/systemd/system /etc/default /etc/environment /etc/profile.d
    /etc/sysctl.conf /etc/sysctl.d /etc/security/limits.conf /etc/security/limits.d
    /etc/modules-load.d /etc/modprobe.d /etc/logrotate.conf /etc/logrotate.d
    /etc/rsyslog.conf /etc/rsyslog.d
    /etc/hosts /etc/hostname /etc/fstab /etc/crypttab /etc/resolv.conf /etc/exports
    /etc/netplan /etc/NetworkManager/system-connections
    /etc/ufw /etc/fail2ban
    /etc/nginx /etc/apache2 /etc/php /etc/haproxy /etc/keepalived
    /etc/mysql /etc/postgresql /etc/redis /etc/redis.conf /etc/mongod.conf
    /etc/docker /etc/containerd /etc/rabbitmq
    /etc/letsencrypt /etc/certbot /etc/supervisor /etc/supervisord.conf
    /var/spool/cron
  )
  local path
  for path in "${default_paths[@]}" "${extra_includes[@]}"; do
    add_existing_path "${path}" "${path_list}"
  done

  if ${include_service_data}; then
    local -a data_paths=(
      /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/lib/docker
      /var/lib/containerd /var/lib/mongodb /var/lib/rabbitmq
    )
    for path in "${data_paths[@]}"; do
      add_existing_path "${path}" "${path_list}"
    done
  fi

  # 避免输出包本身位于某个备份目录时被递归打包。
  PARTIAL_ARCHIVE="${output}.partial.$$"
  local output_relative="${output#/}"
  local partial_relative="${PARTIAL_ARCHIVE#/}"
  local -a tar_args=(
    --create --preserve-permissions --numeric-owner --acls --xattrs
    --exclude="${output_relative}"
    --exclude="${partial_relative}"
  )
  local pattern
  for pattern in "${extra_excludes[@]}"; do
    tar_args+=(--exclude="${pattern}")
  done

  log "开始备份到：${output}"
  case "${format}" in
    tar)
      tar "${tar_args[@]}" --file "${PARTIAL_ARCHIVE}" \
        -C "${TEMP_DIR}" .system-migrate \
        -C / --null --files-from="${path_list}"
      ;;
    tar.gz)
      tar "${tar_args[@]}" --gzip --file "${PARTIAL_ARCHIVE}" \
        -C "${TEMP_DIR}" .system-migrate \
        -C / --null --files-from="${path_list}"
      ;;
    zip)
      tar "${tar_args[@]}" --file - \
        -C "${TEMP_DIR}" .system-migrate \
        -C / --null --files-from="${path_list}" \
        | zip -q - - >"${PARTIAL_ARCHIVE}"
      ;;
  esac
  mv -f -- "${PARTIAL_ARCHIVE}" "${output}"
  PARTIAL_ARCHIVE=""

  local archive_size
  archive_size="$(du -h -- "${output}" | awk '{print $1}')"
  log "备份完成：${output}（${archive_size}）"
  log "建议在复制到新机器后执行：${SCRIPT_NAME} inspect --archive '${output}'"
}

validate_archive() {
  local archive="$1" member
  [[ -f "${archive}" ]] || die "备份包不存在：${archive}"
  archive_type "${archive}" >/dev/null
  list_archive "${archive}" >/dev/null || die "备份包损坏或格式不正确：${archive}"
  list_archive "${archive}" \
    | awk '/^(\.\/)?\.system-migrate\/manifest$/ { found=1 } END { exit !found }' \
    || die "不是 ${SCRIPT_NAME} 创建的备份包（缺少 manifest）"

  while IFS= read -r member; do
    member="${member#./}"
    [[ "${member}" != /* ]] || die "压缩包包含绝对路径，拒绝恢复：${member}"
    [[ "/${member}/" != *'/../'* ]] || die "压缩包包含路径穿越条目，拒绝恢复：${member}"
  done < <(list_archive "${archive}")
}

extract_metadata() {
  local archive="$1"
  make_temp_dir
  case "$(archive_type "${archive}")" in
    tar)
      tar -xf "${archive}" -C "${TEMP_DIR}" .system-migrate 2>/dev/null \
        || tar -xf "${archive}" -C "${TEMP_DIR}" ./.system-migrate
      ;;
    tar.gz)
      tar -xzf "${archive}" -C "${TEMP_DIR}" .system-migrate 2>/dev/null \
        || tar -xzf "${archive}" -C "${TEMP_DIR}" ./.system-migrate
      ;;
    zip)
      unzip -p "${archive}" | tar -xf - -C "${TEMP_DIR}" .system-migrate 2>/dev/null \
        || unzip -p "${archive}" | tar -xf - -C "${TEMP_DIR}" ./.system-migrate
      ;;
  esac
}

show_manifest() {
  local manifest="$1"
  [[ -f "${manifest}" ]] || die "备份元数据不完整：缺少 manifest"
  printf '%s\n' '--- 备份信息 ---'
  sed -n \
    -e 's/^created_at=/创建时间: /p' \
    -e 's/^hostname=/来源主机: /p' \
    -e 's/^os_pretty_name=/来源系统: /p' \
    -e 's/^kernel=/来源内核: /p' \
    -e 's/^script_version=/脚本版本: /p' \
    "${manifest}"
}

inspect_main() {
  local archive=""
  while (($#)); do
    case "$1" in
      -a|--archive) [[ $# -ge 2 ]] || die "$1 缺少参数"; archive="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知 inspect 选项：$1" ;;
    esac
  done
  [[ -n "${archive}" ]] || die "inspect 必须指定 --archive"
  require_command tar
  validate_archive "${archive}"
  extract_metadata "${archive}"
  show_manifest "${TEMP_DIR}/.system-migrate/manifest"
  printf '\n--- 内容概要 ---\n'
  printf '压缩包大小: %s\n' "$(du -h -- "${archive}" | awk '{print $1}')"
  printf '归档条目数: %s\n' "$(list_archive "${archive}" | wc -l | tr -d ' ')"
  printf '手动 APT 包: %s\n' "$(wc -l <"${TEMP_DIR}/.system-migrate/apt/manual-packages.txt" 2>/dev/null || printf 0)"
  printf '启用的服务: %s\n' "$(wc -l <"${TEMP_DIR}/.system-migrate/systemd/enabled-services.txt" 2>/dev/null || printf 0)"
  printf '用户 crontab: %s\n' "$(find "${TEMP_DIR}/.system-migrate/crontabs" -type f 2>/dev/null | wc -l | tr -d ' ')"
}

install_apt_packages() {
  local package_file="$1"
  [[ -s "${package_file}" ]] || { warn "没有可恢复的 APT 包清单"; return 0; }
  command -v apt-get >/dev/null 2>&1 || { warn "目标系统没有 apt-get，跳过软件安装"; return 0; }

  log "更新 APT 索引"
  DEBIAN_FRONTEND=noninteractive apt-get update

  local -a batch=()
  local package
  while IFS= read -r package || [[ -n "${package}" ]]; do
    [[ "${package}" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.:~-]*$ ]] || continue
    batch+=("${package}")
    if ((${#batch[@]} >= 100)); then
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${batch[@]}"
      batch=()
    fi
  done <"${package_file}"
  if ((${#batch[@]})); then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${batch[@]}"
  fi
}

restore_files() {
  local archive="$1"
  log "还原文件到 /（保留权限、ACL、扩展属性与数字 UID/GID）"
  local -a extract_args=(
    --extract --preserve-permissions --numeric-owner --acls --xattrs
    -C /
    --exclude='.system-migrate' --exclude='.system-migrate/*'
    --exclude='./.system-migrate' --exclude='./.system-migrate/*'
  )
  case "$(archive_type "${archive}")" in
    tar)    tar "${extract_args[@]}" --file "${archive}" ;;
    tar.gz) tar "${extract_args[@]}" --gzip --file "${archive}" ;;
    zip)    unzip -p "${archive}" | tar "${extract_args[@]}" --file - ;;
  esac
}

restore_crontabs() {
  local cron_dir="$1" cron_file user
  [[ -d "${cron_dir}" ]] || return 0
  command -v crontab >/dev/null 2>&1 || { warn "目标系统没有 crontab 命令，跳过用户定时任务"; return 0; }
  for cron_file in "${cron_dir}"/*; do
    [[ -f "${cron_file}" ]] || continue
    user="${cron_file##*/}"
    if id "${user}" >/dev/null 2>&1; then
      crontab -u "${user}" "${cron_file}"
      log "已恢复用户 crontab：${user}"
    else
      warn "目标系统不存在用户 ${user}，跳过其 crontab"
    fi
  done
}

restore_services() {
  local service_file="$1" service
  [[ -s "${service_file}" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || { warn "目标系统没有 systemctl，跳过服务状态恢复"; return 0; }
  systemctl daemon-reload
  while IFS= read -r service || [[ -n "${service}" ]]; do
    [[ "${service}" =~ ^[a-zA-Z0-9@_.:-]+\.service$ ]] || continue
    if systemctl cat "${service}" >/dev/null 2>&1; then
      systemctl enable "${service}" || warn "无法启用服务：${service}"
    else
      warn "目标系统不存在服务：${service}"
    fi
  done <"${service_file}"
}

restore_main() {
  local archive=""
  local do_packages=true do_files=true do_crontabs=true do_services=true
  while (($#)); do
    case "$1" in
      -a|--archive) [[ $# -ge 2 ]] || die "$1 缺少参数"; archive="$2"; shift 2 ;;
      --skip-packages) do_packages=false; shift ;;
      --skip-files) do_files=false; shift ;;
      --skip-crontabs) do_crontabs=false; shift ;;
      --skip-services) do_services=false; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -y|--yes) ASSUME_YES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知恢复选项：$1" ;;
    esac
  done
  [[ -n "${archive}" ]] || die "restore 必须指定 --archive"
  require_command tar
  validate_archive "${archive}"
  extract_metadata "${archive}"
  show_manifest "${TEMP_DIR}/.system-migrate/manifest"

  printf '\n--- 恢复计划 ---\n'
  printf '安装 APT 软件: %s\n' "${do_packages}"
  printf '覆盖还原文件: %s\n' "${do_files}"
  printf '恢复 crontab:  %s\n' "${do_crontabs}"
  printf '启用服务:     %s\n' "${do_services}"
  printf '目标主机:     %s\n' "$(hostname -f 2>/dev/null || hostname)"

  if ${DRY_RUN}; then
    log "dry-run 完成，未修改系统"
    return 0
  fi

  require_root
  warn "恢复会安装软件并覆盖目标机上的同名文件。建议先对目标机做快照。"
  warn "用户账号数据库不会自动覆盖；不存在的用户需先创建，避免 UID/GID 不一致。"
  confirm "确认执行上述恢复计划吗？" || die "操作已取消"

  if ${do_packages}; then
    install_apt_packages "${TEMP_DIR}/.system-migrate/apt/manual-packages.txt"
  fi
  if ${do_files}; then
    restore_files "${archive}"
  fi
  if ${do_crontabs}; then
    restore_crontabs "${TEMP_DIR}/.system-migrate/crontabs"
  fi
  if ${do_services}; then
    restore_services "${TEMP_DIR}/.system-migrate/systemd/enabled-services.txt"
  fi

  log "恢复完成。建议检查网络、用户 UID/GID、数据库一致性及服务日志后再切换流量。"
  log "脚本只恢复 enable 状态，不会自动启动全部服务；确认配置后请手动启动。"
}

main() {
  local action="${1:-}"
  case "${action}" in
    backup) shift; backup_main "$@" ;;
    restore) shift; restore_main "$@" ;;
    inspect) shift; inspect_main "$@" ;;
    -h|--help|help) usage ;;
    '') usage; exit 1 ;;
    *) die "未知操作：${action}（应为 backup、restore 或 inspect）" ;;
  esac
}

main "$@"
