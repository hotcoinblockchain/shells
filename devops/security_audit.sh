#!/usr/bin/env bash
# Ubuntu 主机只读安全巡检脚本。
# 退出码：0=未发现风险，1=发现告警，2=发现高危项，3=脚本执行错误。

set -uo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly MIN_UBUNTU_MAJOR=24

WARNINGS=0
CRITICALS=0
CHECK_ERRORS=0
NO_COLOR=0
DEEP_SCAN=0
declare -a ALLOWED_USERS=(root)
declare -a ALLOWED_GROUPS=(root)
declare -a DEFAULT_UBUNTU_USERS=(
  root daemon bin sys sync games man lp mail news uucp proxy www-data backup list
  irc gnats nobody _apt systemd-network systemd-timesync systemd-resolve messagebus
  syslog uuidd tcpdump tss landscape pollinate fwupd-refresh polkitd _chrony
)

usage() {
  cat <<'EOF'
用法：security_audit.sh [选项]

只读检查操作系统版本、账号、组、可交互 shell、可疑进程、关键文件及定时任务。

选项：
  --allow-user USER     将业务登录用户加入白名单（可重复）
  --allow-group GROUP   将业务组加入白名单（可重复）
  --deep                额外扫描关键配置文件中的可疑命令（可能较慢）
  --no-color            禁用彩色输出
  -h, --help            显示帮助

示例：
  sudo ./security_audit.sh --allow-user deploy --allow-user ops --allow-group sudo

说明：
  脚本不会修改系统。建议以 root 运行，以完整读取 /proc 和系统配置。
  “非默认账号”无法脱离主机用途绝对判断；未加入白名单的可登录账号会告警，
  系统账号则结合 UID、shell、主目录和命名特征判断。
EOF
}

while (($# > 0)); do
  case "$1" in
    --allow-user)
      [[ $# -ge 2 && -n ${2:-} ]] || { echo "错误：--allow-user 缺少参数" >&2; exit 3; }
      ALLOWED_USERS+=("$2")
      shift 2
      ;;
    --allow-group)
      [[ $# -ge 2 && -n ${2:-} ]] || { echo "错误：--allow-group 缺少参数" >&2; exit 3; }
      ALLOWED_GROUPS+=("$2")
      shift 2
      ;;
    --deep) DEEP_SCAN=1; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage >&2; exit 3 ;;
  esac
done

if ((NO_COLOR == 0)) && [[ -t 1 ]]; then
  RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BLUE=''; RESET=''
fi

section() { printf '\n%s== %s ==%s\n' "$BLUE" "$1" "$RESET"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; ((WARNINGS += 1)); }
critical() { printf '%s[CRITICAL]%s %s\n' "$RED" "$RESET" "$*"; ((CRITICALS += 1)); }
check_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; ((CHECK_ERRORS += 1)); }

in_array() {
  local needle=$1 item
  shift
  for item in "$@"; do [[ $item == "$needle" ]] && return 0; done
  return 1
}

is_login_shell() {
  local shell=$1
  [[ -n $shell && $shell != */nologin && $shell != /bin/false && $shell != /usr/bin/false && $shell != /bin/sync ]]
}

is_integer() { [[ $1 =~ ^[0-9]+$ ]]; }

check_os() {
  section "操作系统版本"
  if [[ ! -r /etc/os-release ]]; then
    critical "缺少或无法读取 /etc/os-release，不能确认操作系统版本"
    return
  fi

  local id='' version_id='' pretty_name=''
  while IFS='=' read -r key value; do
    value=${value%\"}; value=${value#\"}
    case "$key" in
      ID) id=$value ;;
      VERSION_ID) version_id=$value ;;
      PRETTY_NAME) pretty_name=$value ;;
    esac
  done < /etc/os-release

  info "检测到：${pretty_name:-unknown}"
  if [[ $id != ubuntu ]]; then
    critical "当前系统不是 Ubuntu（ID=${id:-unknown}）"
    return
  fi

  local major=${version_id%%.*}
  if ! is_integer "$major"; then
    critical "无法解析 Ubuntu VERSION_ID=${version_id:-missing}"
  elif ((major < MIN_UBUNTU_MAJOR)); then
    critical "Ubuntu ${version_id} 低于要求的 24.x"
  else
    ok "Ubuntu 主版本 ${major} 满足最低要求"
  fi
}

check_key_file() {
  local path=$1 expected_mode=$2 actual_mode owner group
  if [[ ! -e $path ]]; then
    critical "关键文件不存在：$path"
    return
  fi
  if [[ -L $path ]]; then
    warn "关键文件是符号链接，需确认目标可信：$path -> $(readlink "$path" 2>/dev/null || echo '?')"
  fi
  if [[ ! -f $path ]]; then
    critical "关键路径不是普通文件：$path"
    return
  fi
  if ! IFS=' ' read -r actual_mode owner group < <(stat -Lc '%a %U %G' "$path" 2>/dev/null); then
    check_error "无法读取文件属性：$path"
    return
  fi
  [[ $owner == root ]] || critical "$path 的所有者异常：$owner（期望 root）"
  [[ $group == root || $group == shadow ]] || warn "$path 的所属组异常：$group"

  # 对权限做八进制位判断：任何 other 写权限都视为高危。
  local mode_value=$((8#$actual_mode))
  (( (mode_value & 0002) == 0 )) || critical "$path 可被任意用户写入（mode=$actual_mode）"
  (( (mode_value & 0020) == 0 )) || warn "$path 可被所属组写入（mode=$actual_mode）"
  if [[ -n $expected_mode && $actual_mode != "$expected_mode" ]]; then
    info "$path 当前权限为 $actual_mode（常见基线 $expected_mode）"
  fi
}

check_accounts() {
  section "用户与认证配置"
  if [[ ! -r /etc/passwd ]]; then
    critical "无法读取 /etc/passwd"
    return
  fi

  local uid_min=1000
  if [[ -r /etc/login.defs ]]; then
    local parsed
    parsed=$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/login.defs 2>/dev/null || true)
    [[ -n $parsed ]] && uid_min=$parsed
  fi

  local line_no=0 user pass uid gid gecos home shell extra
  local -A uid_owners=()
  while IFS=: read -r user pass uid gid gecos home shell extra; do
    ((line_no += 1))
    if [[ -z $user || -z $uid || -z $gid || -n ${extra:-} ]] || ! is_integer "$uid" || ! is_integer "$gid"; then
      critical "/etc/passwd 第 $line_no 行格式异常"
      continue
    fi

    if [[ -n ${uid_owners[$uid]:-} ]]; then
      critical "UID $uid 被多个用户使用：${uid_owners[$uid]}、$user"
    else
      uid_owners[$uid]=$user
    fi

    if ((uid == 0)) && [[ $user != root ]]; then
      critical "发现额外 UID 0 超级用户：$user"
    fi
    if [[ $user == root ]] && ((uid != 0 || gid != 0)); then
      critical "root 账号 UID/GID 异常：uid=$uid gid=$gid"
    fi

    if ! in_array "$user" "${DEFAULT_UBUNTU_USERS[@]}" && ! in_array "$user" "${ALLOWED_USERS[@]}"; then
      warn "发现非 Ubuntu 常见内置账号且未加入白名单：$user (uid=$uid, shell=$shell, home=$home)"
    fi

    if is_login_shell "$shell"; then
      if ! grep -Fxq -- "$shell" /etc/shells 2>/dev/null; then
        warn "用户 $user 使用未登记的可交互 shell：$shell"
      fi
      if ! in_array "$user" "${ALLOWED_USERS[@]}"; then
        if ((uid >= uid_min)); then
          warn "发现未在白名单中的可登录用户：$user (uid=$uid, shell=$shell, home=$home)"
        else
          warn "系统账号具有可交互 shell：$user (uid=$uid, shell=$shell)"
        fi
      fi
    elif ((uid >= uid_min)) && ! in_array "$user" "${ALLOWED_USERS[@]}"; then
      warn "发现不可交互但使用普通 UID 的未授权用户：$user (uid=$uid, shell=$shell)"
    fi

    if [[ $home == /tmp* || $home == /dev/shm* || $home == /var/tmp* ]]; then
      warn "用户 $user 的主目录位于临时目录：$home"
    fi
    if [[ $pass == '' ]]; then
      critical "用户 $user 在 /etc/passwd 中密码字段为空"
    elif [[ $pass != x && $pass != '!' && $pass != '*' ]]; then
      critical "用户 $user 的密码散列疑似直接存放在 /etc/passwd"
    fi
  done < /etc/passwd

  if [[ -r /etc/shadow ]]; then
    while IFS=: read -r user hash _; do
      [[ -n $user ]] || continue
      if [[ -z $hash ]]; then
        critical "用户 $user 在 /etc/shadow 中密码为空"
      fi
    done < /etc/shadow
  else
    warn "无法读取 /etc/shadow；请以 root 运行以检查空密码账号"
  fi
}

check_groups() {
  section "用户组"
  if [[ ! -r /etc/group ]]; then
    critical "无法读取 /etc/group"
    return
  fi

  local line_no=0 group pass gid members extra member
  local -A gid_owners=()
  while IFS=: read -r group pass gid members extra; do
    ((line_no += 1))
    if [[ -z $group || -z $gid || -n ${extra:-} ]] || ! is_integer "$gid"; then
      critical "/etc/group 第 $line_no 行格式异常"
      continue
    fi
    if [[ -n ${gid_owners[$gid]:-} && ${gid_owners[$gid]} != "$group" ]]; then
      warn "GID $gid 被多个组使用：${gid_owners[$gid]}、$group"
    else
      gid_owners[$gid]=$group
    fi
    if [[ $group == root && $gid != 0 ]]; then
      critical "root 组 GID 异常：$gid"
    fi
    if [[ -n $members ]]; then
      IFS=',' read -ra member_list <<< "$members"
      for member in "${member_list[@]}"; do
        getent passwd "$member" >/dev/null 2>&1 || warn "组 $group 包含不存在的用户：$member"
      done
    fi
  done < /etc/group

  for group in sudo adm shadow disk docker lxd; do
    if getent group "$group" >/dev/null 2>&1; then
      local entry privileged_member
      entry=$(getent group "$group")
      IFS=: read -r _ _ _ privileged_members <<< "$entry"
      IFS=',' read -ra privileged_list <<< "${privileged_members:-}"
      for privileged_member in "${privileged_list[@]}"; do
        [[ -z $privileged_member ]] && continue
        if ! in_array "$privileged_member" "${ALLOWED_USERS[@]}"; then
          warn "高权限组 $group 包含未在用户白名单中的成员：$privileged_member"
        fi
      done
    fi
  done

  for group in $(getent group 2>/dev/null | awk -F: '$3 >= 1000 && $3 != 65534 {print $1}'); do
    in_array "$group" "${ALLOWED_GROUPS[@]}" || warn "发现未在白名单中的普通 GID 组：$group"
  done
}

check_suspicious_processes() {
  section "交互式 shell 与疑似后门进程"
  local found=0 pid cmd exe
  local pattern='(^|[[:space:]/])(bash|sh|dash|zsh|ksh)[[:space:]].*(-i([[:space:]]|$)|/dev/(tcp|udp))|nc([.a-z0-9_-]*)?[[:space:]].*(-e[[:space:]]|--exec)|ncat[[:space:]].*--exec|socat[[:space:]].*(EXEC|SYSTEM):|python[0-9.]*[[:space:]].*(pty\.spawn|socket\.)|perl[[:space:]].*socket|php[[:space:]].*fsockopen|ruby[[:space:]].*TCPSocket|mkfifo.*(/bin/)?(ba)?sh'

  for proc_dir in /proc/[0-9]*; do
    [[ -r $proc_dir/cmdline ]] || continue
    pid=${proc_dir##*/}
    cmd=$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null || true)
    [[ -n $cmd ]] || continue
    if printf '%s\n' "$cmd" | grep -Eiq "$pattern"; then
      exe=$(readlink "$proc_dir/exe" 2>/dev/null || echo '?')
      critical "疑似反弹 shell/交互后门：pid=$pid exe=$exe cmd=${cmd:0:300}"
      found=1
    fi
    if [[ $cmd == *"(deleted)"* ]]; then
      warn "进程命令行包含 deleted 标记：pid=$pid cmd=${cmd:0:300}"
      found=1
    fi
  done

  # 检查从临时目录运行的进程；/proc/exe 的 deleted 后缀也在此处识别。
  for proc_dir in /proc/[0-9]*; do
    [[ -L $proc_dir/exe ]] || continue
    pid=${proc_dir##*/}
    exe=$(readlink "$proc_dir/exe" 2>/dev/null || true)
    case "$exe" in
      /tmp/*|/var/tmp/*|/dev/shm/*)
        cmd=$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null || true)
        warn "进程从临时目录执行：pid=$pid exe=$exe cmd=${cmd:0:300}"
        found=1
        ;;
      *' (deleted)')
        warn "运行中的可执行文件已被删除：pid=$pid exe=$exe"
        found=1
        ;;
    esac
  done
  ((found == 1)) || ok "未发现常见反弹 shell 或临时目录执行特征"
}

scan_cron_file() {
  local path=$1 line_no=0 line
  [[ -r $path && -f $path ]] || return
  while IFS= read -r line || [[ -n $line ]]; do
    ((line_no += 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if printf '%s\n' "$line" | grep -Eiq '(/dev/(tcp|udp)|curl[^|;]*(\||;)[[:space:]]*(ba)?sh|wget[^|;]*(\||;)[[:space:]]*(ba)?sh|nc[[:space:]].*(-e|--exec)|ncat.*--exec|socat.*(EXEC|SYSTEM):|base64[[:space:]]+-d.*(\||;)|python.*(pty\.spawn|socket\.)|/tmp/|/dev/shm/|mkfifo)'; then
      critical "定时任务包含常见后门特征：$path:$line_no: ${line:0:300}"
    elif printf '%s\n' "$line" | grep -Eiq '(curl|wget|nc|ncat|socat|bash[[:space:]]+-c|sh[[:space:]]+-c|python|perl|php|ruby)'; then
      warn "定时任务调用网络或解释器命令，需人工确认：$path:$line_no: ${line:0:300}"
    fi
  done < "$path"
}

check_cron() {
  section "定时任务与持久化"
  local path file
  for path in /etc/crontab /etc/anacrontab; do
    [[ -e $path ]] && scan_cron_file "$path"
  done
  for path in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs; do
    [[ -d $path ]] || continue
    while IFS= read -r -d '' file; do
      if [[ -L $file ]]; then
        warn "cron 文件是符号链接：$file -> $(readlink "$file" 2>/dev/null || echo '?')"
      fi
      scan_cron_file "$file"
      local mode owner
      if IFS=' ' read -r mode owner < <(stat -Lc '%a %U' "$file" 2>/dev/null); then
        if [[ $path == /var/spool/cron/crontabs ]]; then
          [[ $owner == "${file##*/}" ]] || warn "用户 crontab 所有者与文件名不一致：$file (owner=$owner)"
        else
          [[ $owner == root ]] || warn "系统 cron 文件所有者不是 root：$file (owner=$owner)"
        fi
        (( (8#$mode & 0002) == 0 )) || critical "cron 文件可被任意用户写入：$file (mode=$mode)"
      fi
    done < <(find "$path" -xdev \( -type f -o -type l \) -print0 2>/dev/null)
  done

  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r unit; do
      [[ -n $unit ]] && info "已启用 timer：$unit"
    done < <(systemctl list-unit-files --type=timer --state=enabled --no-legend 2>/dev/null | awk '{print $1}')
  fi
}

check_authorized_keys() {
  section "SSH 持久化入口"
  local user home shell key_file mode owner line_count
  while IFS=: read -r user _ _ _ _ home shell; do
    [[ -n $home && $home == /* ]] || continue
    for key_file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      [[ -e $key_file ]] || continue
      if [[ ! -r $key_file ]]; then
        warn "无法读取 SSH 授权密钥：$key_file"
        continue
      fi
      line_count=$(grep -Evc '^[[:space:]]*(#|$)' "$key_file" 2>/dev/null || true)
      info "用户 $user 存在 SSH 授权密钥：$key_file（非注释行 $line_count）"
      if ! in_array "$user" "${ALLOWED_USERS[@]}"; then
        warn "未在用户白名单中的账号 $user 存在 authorized_keys"
      fi
      if IFS=' ' read -r mode owner < <(stat -Lc '%a %U' "$key_file" 2>/dev/null); then
        [[ $owner == "$user" || ($user == root && $owner == root) ]] || warn "$key_file 所有者异常：$owner"
        (( (8#$mode & 0022) == 0 )) || critical "$key_file 可被组或其他用户写入（mode=$mode）"
      fi
      if grep -Eiq '(^|,)(command=|environment=|permitopen=|tunnel=)' "$key_file" 2>/dev/null; then
        warn "$key_file 使用了 SSH key 高级选项，请确认 command/tunnel 等配置"
      fi
    done
  done < /etc/passwd
}

deep_scan_configs() {
  ((DEEP_SCAN == 1)) || return
  section "关键配置深度扫描"
  local file
  local pattern='(/dev/(tcp|udp)|nc[[:space:]].*(-e|--exec)|ncat.*--exec|socat.*(EXEC|SYSTEM):|curl[^|;]*(\||;)[[:space:]]*(ba)?sh|wget[^|;]*(\||;)[[:space:]]*(ba)?sh|pty\.spawn|mkfifo.*(ba)?sh)'
  for file in /etc/passwd /etc/group /etc/crontab /etc/rc.local /etc/profile /etc/bash.bashrc; do
    [[ -r $file && -f $file ]] || continue
    while IFS= read -r match; do
      [[ -n $match ]] && critical "关键配置疑似包含后门命令：$file: ${match:0:300}"
    done < <(grep -Ein "$pattern" "$file" 2>/dev/null || true)
  done
}

main() {
  printf '%s - Ubuntu 主机只读安全巡检\n' "$SCRIPT_NAME"
  printf '时间：%s  主机：%s  执行用户：%s\n' "$(date -Is 2>/dev/null || date)" "$(hostname 2>/dev/null || echo unknown)" "$(id -un 2>/dev/null || echo unknown)"
  ((EUID == 0)) || warn "当前不是 root；部分检查可能因权限不足而不完整"

  check_os
  section "关键文件属性"
  check_key_file /etc/passwd 644
  check_key_file /etc/group 644
  check_key_file /etc/shadow 640
  check_key_file /etc/gshadow 640
  check_key_file /etc/crontab 644
  check_accounts
  check_groups
  check_suspicious_processes
  check_cron
  check_authorized_keys
  deep_scan_configs

  section "巡检结论"
  printf '高危：%d  告警：%d  检查错误：%d\n' "$CRITICALS" "$WARNINGS" "$CHECK_ERRORS"
  if ((CRITICALS > 0)); then
    printf '%s结论：发现高危项，请立即人工复核。%s\n' "$RED" "$RESET"
    return 2
  elif ((WARNINGS > 0 || CHECK_ERRORS > 0)); then
    printf '%s结论：发现需人工确认的安全隐患或检查不完整。%s\n' "$YELLOW" "$RESET"
    return 1
  fi
  printf '%s结论：本次启发式检查未发现明显风险。%s\n' "$GREEN" "$RESET"
  return 0
}

main "$@"
