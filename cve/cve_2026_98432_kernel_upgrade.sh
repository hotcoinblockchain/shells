#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

MODE="${MODE:-upgrade}"             # upgrade | check
REBOOT="${REBOOT:-no}"              # no | yes
LOCK=/run/lock/cve-2026-98432-kernel-upgrade.lock
OS_ID="" OS_VERSION="" FAMILY="" FLAVOR="" PKG="" FIX="" STATUS="UNKNOWN"
RUNNING="$(uname -r)"; TARGET=""; NEXT_KERNEL=""; NEXT_CONFIDENCE="unknown"
log(){ local lvl="$1"; shift; printf '%s [%s] %s\n' "$(date '+%F %T%z')" "$lvl" "$*"; }
die(){ log ERROR "$*" >&2; exit 1; }
on_err(){ local rc="$1" line="$2"; log ERROR "执行失败: line=$line exit=$rc; 请检查上方包管理器输出" >&2; exit "$rc"; }
trap 'on_err "$?" "$LINENO"' ERR
usage(){ cat <<USAGE
Usage: sudo bash cve_2026_98432_kernel_upgrade.sh [--check|--upgrade] [--reboot]
Default: --upgrade, no automatic reboot
Environment: MODE=check|upgrade REBOOT=yes|no
USAGE
}
for arg in "$@"; do case "$arg" in --check) MODE=check;; --upgrade) MODE=upgrade;; --reboot) REBOOT=yes;; -h|--help) usage; exit 0;; *) die "未知参数: $arg";; esac; done
[[ "$MODE" == check || "$MODE" == upgrade ]] || die "MODE 仅支持 check/upgrade"
[[ "$REBOOT" == yes || "$REBOOT" == no ]] || die "REBOOT 仅支持 yes/no"
[[ -r /etc/os-release ]] || die "缺少 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-unknown}"
[[ "$MODE" == check || "$EUID" -eq 0 ]] || die "升级需要 root 权限"
if [[ "$MODE" == upgrade ]]; then
  command -v flock >/dev/null || die "缺少 flock"
  mkdir -p /run/lock
  exec 9>"$LOCK"
  flock -n 9 || die "已有同类升级任务运行"
fi
log INFO "========== CVE-2026-98432 内核检查/升级 =========="
log INFO "模式=$MODE 自动重启=$REBOOT 主机=$(hostname) OS=${PRETTY_NAME:-$OS_ID} 运行内核=$RUNNING"
log INFO "架构=$(uname -m)"

# Only assign a threshold when the exact distro and kernel ABI/flavor are recognized.
if [[ "$OS_ID" == ubuntu ]]; then
  FAMILY=debian
  command -v dpkg >/dev/null || die "缺少 dpkg"
  case "$RUNNING" in
    *-aws) FLAVOR=aws;; *-azure) FLAVOR=azure;; *-gcp) FLAVOR=gcp;; *-oracle) FLAVOR=oracle;; *-generic) FLAVOR=generic;; *-lowlatency) FLAVOR=lowlatency;; *) FLAVOR=unknown;;
  esac
  case "$OS_VERSION:$FLAVOR" in
    22.04:generic)
      if [[ "$RUNNING" == 5.15.* ]]; then PKG=linux-generic; FIX=5.15.0-203-generic
      elif [[ "$RUNNING" == 6.8.* ]]; then PKG=linux-generic-hwe-22.04; FIX=6.8.0-149-generic
      else FLAVOR=unknown; fi;;
    24.04:generic)
      if [[ "$RUNNING" == 6.8.* ]]; then PKG=linux-generic; FIX=6.8.0-149-generic
      elif [[ "$RUNNING" == 7.0.* ]]; then PKG=linux-generic-hwe-24.04; FIX=7.0.0-43-generic
      else FLAVOR=unknown; fi;;
    26.04:generic)
      if [[ "$RUNNING" == 7.0.* ]]; then PKG=linux-generic; FIX=7.0.0-43-generic
      else FLAVOR=unknown; fi;;
  esac
  if [[ -n "$FIX" ]]; then
    if dpkg --compare-versions "${RUNNING%-generic}" ge "${FIX%-generic}"; then STATUS=FIXED; else STATUS=VULNERABLE; fi
  fi
fi

# Alibaba Cloud Linux ID values may vary by release; match explicit identifiers only.
if [[ "$OS_ID" == alinux || "$OS_ID" == aliyun || "$OS_ID" == alinux3 || "$OS_ID" == alinux4 ]]; then
  FAMILY=redhat
  FLAVOR="${RUNNING##*.}"
  if [[ "$OS_VERSION" == 3* && "$RUNNING" == 5.10.134-*al8* ]]; then
    PKG=kernel; FIX=5.10.134-19.10.al8
  elif [[ "$OS_VERSION" == 4* && "$RUNNING" == 6.6.102-*alnx4* ]]; then
    PKG=kernel; FIX=6.6.102-8.0.2.alnx4
  fi
  if [[ -n "$FIX" ]]; then
    command -v rpm >/dev/null || die "缺少 rpm"
    # Compare kernel release without the architecture suffix.
    runver="${RUNNING%.*}"; runver="${runver#*-}"
    fixver="${FIX#*-}"
    # rpmdev-vercmp not universally available; use rpm --eval Lua rpm.vercmp when supported.
    if rpm --eval '%{lua:print(rpm.vercmp("'"$runver"'", "'"$fixver"'"))}' 2>/dev/null | grep -qxE '[-]?[0-9]+'; then
      cmp="$(rpm --eval '%{lua:print(rpm.vercmp("'"$runver"'", "'"$fixver"'"))}')"
      # Kernel base versions already matched by exact prefix above.
      if (( cmp >= 0 )); then STATUS=FIXED; else STATUS=VULNERABLE; fi
    else
      log WARN "无法可靠比较 RPM release，状态保留 UNKNOWN"
    fi
  fi
elif [[ "$FAMILY" != debian ]]; then
  case "$OS_ID" in
    rhel|rocky|almalinux|centos|ol|fedora) FAMILY=redhat; PKG=kernel;;
    debian) FAMILY=debian; PKG=linux-image-amd64;;
    *) FAMILY=unsupported;;
  esac
fi

log INFO "系统家族=$FAMILY 内核类型=$FLAVOR 对应升级包=${PKG:-未映射}"
log INFO "已内置修复门槛=${FIX:-无可信版本门槛} 当前运行状态=$STATUS"
if [[ "$FAMILY" == unsupported ]]; then die "不支持该发行版，拒绝自动升级"; fi
if [[ -z "$FIX" ]]; then
  log WARN "该系统/内核分支未建立经核实的 CVE 修复门槛；不会把内核较新误判为已修复"
  if [[ -z "$PKG" && "$MODE" == upgrade ]]; then die "未知内核类型，不允许自动选择内核包"; fi
  if [[ -n "$PKG" ]]; then log WARN "允许更新当前发行版内核包，但升级后 CVE 修复状态仍为 UNKNOWN"; fi
fi

if [[ "$FAMILY" == debian && -n "$PKG" ]]; then
  command -v apt-get >/dev/null || die "缺少 apt-get"
  log INFO "当前元包信息:"
  dpkg-query -W -f='${Package} ${Version} ${Status}\n' "$PKG" 2>/dev/null || true
  if [[ "$MODE" == upgrade ]]; then
    log INFO "刷新正式 APT 软件包索引（不自动更改软件源）"
    apt-get update
    log INFO "检查 APT 候选版本与来源:"
    apt-cache policy "$PKG"
    cand="$(apt-cache policy "$PKG" | awk '/Candidate:/{print $2;exit}')"
    [[ -n "$cand" && "$cand" != '(none)' ]] || die "无可用候选版本"
    # Refuse proposed candidates; apt-cache policy includes candidate and its origin lines.
    if apt-cache policy "$PKG" | grep -E '^[[:space:]]+\*\*\* ' | grep -q proposed; then die "检测到 proposed 候选，拒绝"; fi
    # Check candidate source via apt-cache madison and apt policy version table, excluding proposed-only candidates.
    if apt-cache policy "$PKG" | grep -qE '[[:space:]](jammy|noble|resolute)-proposed/'; then
      log WARN "检测到系统启用 proposed 仓库；请禁用 proposed 后重试，避免误选测试内核"
      die "拒绝在启用 proposed 的环境升级"
    fi
    log INFO "执行 apt-get install --only-upgrade (若未安装元包则正常 install)"
    if dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -qx 'install ok installed'; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$PKG"
    else
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
    fi
  else
    apt-cache policy "$PKG" || true
  fi
elif [[ "$FAMILY" == redhat && -n "$PKG" ]]; then
  if command -v dnf >/dev/null; then MANAGER=dnf
  elif command -v yum >/dev/null; then MANAGER=yum
  else die "缺少 dnf/yum"; fi
  log INFO "使用 $MANAGER，目标包=$PKG"
  if [[ "$MODE" == upgrade ]]; then
    "$MANAGER" makecache
    "$MANAGER" upgrade -y "$PKG"
  else
    "$MANAGER" list --showduplicates "$PKG" || true
  fi
fi

log INFO "========== 执行结果 =========="
log INFO "当前运行内核（重启前不会改变）: $(uname -r)"
if [[ "$FAMILY" == debian ]]; then
  log INFO "已安装内核镜像（末尾显示版本）:"
  dpkg-query -W -f='${Package} ${Version} ${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | grep 'install ok installed' || true
  if [[ -e /boot/vmlinuz ]]; then
    NEXT_KERNEL="$(readlink -f /boot/vmlinuz)"; NEXT_KERNEL="${NEXT_KERNEL##*/vmlinuz-}"
    NEXT_CONFIDENCE="/boot/vmlinuz 链接推测（不保证 GRUB 实际默认项）"
  fi
else
  log INFO "已安装 kernel 包:"
  rpm -q kernel kernel-core 2>/dev/null || true
fi
if command -v grubby >/dev/null 2>&1; then
  bootpath="$(grubby --default-kernel 2>/dev/null || true)"
  if [[ -n "$bootpath" && "$bootpath" == *vmlinuz-* ]]; then
    NEXT_KERNEL="${bootpath##*vmlinuz-}"
    NEXT_CONFIDENCE="grubby 默认启动项"
  fi
fi
if [[ -n "$NEXT_KERNEL" ]]; then
  log INFO "下次启动默认内核（${NEXT_CONFIDENCE}）: $NEXT_KERNEL"
else
  log WARN "无法可靠读取默认启动内核（GRUB/BLS/UEFI 配置可能不同），请检查引导项"
fi
if [[ -n "$FIX" && -n "$NEXT_KERNEL" ]]; then
  log INFO "修复门槛=$FIX；请重启后核对 uname -r，并检查当前分支 CVE 状态"
fi
if [[ "$MODE" == upgrade && "$REBOOT" == yes ]]; then
  log WARN "按 --reboot 请求，5 秒后重启"
  sleep 5
  reboot
else
  log INFO "未自动重启。内核升级需维护窗口重启才生效。"
fi
log INFO "========== 结束 =========="
