#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

MODE="${MODE:-upgrade}"             # upgrade | check
REBOOT="${REBOOT:-no}"              # no | yes
LOCK=/run/lock/cve-2026-98432-kernel-upgrade.lock
OS_ID="" OS_VERSION="" FAMILY="" FLAVOR="" PKG="" FIX="" STATUS="UNKNOWN"
RUNNING="$(uname -r)"; INSTALLED_KERNELS=""; FIXED_INSTALLED=""; NEXT_STATUS="UNKNOWN"; NEXT_KERNEL=""; NEXT_CONFIDENCE="unknown"
log(){ local lvl="$1"; shift; printf '%s [%s] %s\n' "$(date '+%F %T%z')" "$lvl" "$*"; }
die(){ log ERROR "$*" >&2; exit 1; }
on_err(){
  local rc="$1" line="$2"
  # Command substitutions inherit ERR; let the parent log the failure once.
  if (( BASH_SUBSHELL == 0 )); then
    log ERROR "执行失败: line=$line exit=$rc; 请检查上方包管理器输出" >&2
  fi
  exit "$rc"
}
trap 'on_err "$?" "$LINENO"' ERR
usage(){ cat <<USAGE
Usage: sudo bash cve_2026_98432_kernel_upgrade.sh [--check|--upgrade] [--reboot]
Default: --upgrade, no automatic reboot
Environment: MODE=check|upgrade REBOOT=yes|no
USAGE
}
# Classify only the exact distro/flavor branch for which FIX was selected.
# Alibaba Cloud official thresholds (verified 2026-11-19):
# https://help.aliyun.com/en/alinux/product-overview/cve-2026-98432-vulnerability-announcement
kernel_status() {
  local kernel="$1" release cmp
  [[ -n "$FIX" ]] || { printf 'UNKNOWN'; return; }
  if [[ "$OS_ID" == ubuntu ]]; then
    if [[ ! "$kernel" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ || "${kernel%%-*}" != "${FIX%%-*}" ]]; then
      printf 'UNKNOWN'; return
    fi
    if dpkg --compare-versions "${kernel%-generic}" ge "${FIX%-generic}"; then
      printf 'FIXED'
    else
      printf 'VULNERABLE'
    fi
  elif [[ "$OS_ID" == alinux || "$OS_ID" == aliyun || "$OS_ID" == alinux3 || "$OS_ID" == alinux4 ]]; then
    # Do not mix the standard and Pro release lines, or compare different bases.
    case "$FIX" in
      5.10.134-19.10.al8) [[ "$kernel" =~ ^5\.10\.134-[0-9]+(\.[0-9]+)*\.al8\.(x86_64|aarch64)$ ]] || { printf 'UNKNOWN'; return; };;
      5.10.134-014.8.ali5000.pro.al8) [[ "$kernel" =~ ^5\.10\.134-[0-9]+(\.[0-9]+)*\.ali5000\.pro\.al8\.(x86_64|aarch64)$ ]] || { printf 'UNKNOWN'; return; };;
      6.6.102-8.0.2.alnx4) [[ "$kernel" =~ ^6\.6\.102-[0-9]+(\.[0-9]+)*\.alnx4\.(x86_64|aarch64)$ ]] || { printf 'UNKNOWN'; return; };;
      6.6.102-008.0.2.ali6000.pro.alnx4) [[ "$kernel" =~ ^6\.6\.102-[0-9]+(\.[0-9]+)*\.ali6000\.pro\.alnx4\.(x86_64|aarch64)$ ]] || { printf 'UNKNOWN'; return; };;
      *) printf 'UNKNOWN'; return;;
    esac
    release="${kernel%.*}"; release="${release#*-}"
    cmp="$(rpm --eval '%{lua:print(rpm.vercmp("'"$release"'", "'"${FIX#*-}"'"))}' 2>/dev/null)" || cmp=""
    if [[ ! "$cmp" =~ ^-?[0-9]+$ ]]; then printf 'UNKNOWN'
    elif (( cmp >= 0 )); then printf 'FIXED'
    else printf 'VULNERABLE'; fi
  else
    printf 'UNKNOWN'
  fi
}

print_summary() {
  local installed
  STATUS="$(kernel_status "$RUNNING")"
  FIXED_INSTALLED=""
  while IFS= read -r installed; do
    [[ -n "$installed" ]] || continue
    if [[ "$(kernel_status "$installed")" == FIXED ]]; then
      FIXED_INSTALLED="${FIXED_INSTALLED:+${FIXED_INSTALLED}, }${installed}"
    fi
  done <<< "$INSTALLED_KERNELS"
  NEXT_STATUS="$(kernel_status "$NEXT_KERNEL")"
  log INFO "========== CVE-2026-98432 最终结论 =========="
  log INFO "当前运行内核: ${RUNNING}；判定=$STATUS"
  log INFO "已安装的修复内核: ${FIXED_INSTALLED:-未确认存在}"
  log INFO "下次默认启动内核: ${NEXT_KERNEL:-未确认}；判定=${NEXT_STATUS}；依据=$NEXT_CONFIDENCE"
  case "$STATUS" in
    FIXED)
      log INFO "结论 [RUNNING_FIXED]: 当前已经运行在达到本 CVE 修复门槛的内核上；不是待重启状态，无需为本 CVE 再次重启。"
      ;;
    VULNERABLE)
      if [[ -n "$FIXED_INSTALLED" ]]; then
        log WARN "结论 [FIX_INSTALLED_REBOOT_REQUIRED]: 当前运行内核仍受本 CVE 影响；修复内核已安装，但尚未运行，需重启切换。"
        if [[ "$NEXT_STATUS" != FIXED ]]; then
          log WARN "不能直接认为重启即可修复：默认启动项未确认指向修复内核，请先核对并设置启动项。"
        fi
      else
        log WARN "结论 [VULNERABLE_NO_FIX_INSTALLED]: 当前运行内核仍受本 CVE 影响，未确认安装匹配的修复内核；需安装修复版本、设置启动项并重启。"
      fi
      ;;
    *)
      log WARN "结论 [UNKNOWN]: 缺少匹配的厂商规则或可靠版本比较，无法确认当前是否受本 CVE 影响；软件包升级成功不等于漏洞已修复。"
      ;;
  esac
  if [[ "$STATUS" == FIXED && "$NEXT_STATUS" == VULNERABLE ]]; then
    log WARN "当前已修复，但默认启动项仍为受影响内核；下次重启可能回退，请调整启动项。"
  fi
  log INFO "判定仅针对本 CVE 的内置厂商版本规则，不代表内核不存在其他漏洞。"
}

upgrade_debian_kernel() {
  local policy cand installed_status
  log INFO "刷新正式 APT 软件包索引（不自动更改软件源）"
  apt-get update
  log INFO "检查 APT 候选版本与来源:"
  # Read the producer completely before parsing. An early awk exit or grep -q
  # in a pipe can SIGPIPE apt-cache and abort under pipefail (exit 141).
  policy="$(LC_ALL=C apt-cache policy "$PKG")"
  printf '%s\n' "$policy"
  cand="$(LC_ALL=C awk '$1 == "Candidate:" && !found {print $2; found=1}' <<< "$policy")"
  [[ -n "$cand" && "$cand" != '(none)' ]] || die "无可用候选版本"
  log INFO "APT 候选版本=$cand"
  if grep -Eq '[[:space:]][^[:space:]/]+-proposed/' <<< "$policy"; then
    log WARN "检测到系统启用 proposed 仓库；请禁用 proposed 后重试，避免误选测试内核"
    die "拒绝在启用 proposed 的环境升级"
  fi
  log INFO "执行 apt-get install --only-upgrade (若未安装元包则正常 install)"
  installed_status="$(dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null)" || installed_status=""
  if [[ "$installed_status" == 'install ok installed' ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$PKG"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG"
  fi
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
fi

# Alibaba Cloud Linux ID values may vary by release; match explicit identifiers only.
if [[ "$OS_ID" == alinux || "$OS_ID" == aliyun || "$OS_ID" == alinux3 || "$OS_ID" == alinux4 ]]; then
  FAMILY=redhat
  FLAVOR="${RUNNING##*.}"
  if [[ "$OS_VERSION" == 3* && "$RUNNING" == 5.10.134-*.ali5000.pro.al8.* ]]; then
    PKG=kernel; FIX=5.10.134-014.8.ali5000.pro.al8
  elif [[ "$OS_VERSION" == 4* && "$RUNNING" == 6.6.102-*.ali6000.pro.alnx4.* ]]; then
    PKG=kernel; FIX=6.6.102-008.0.2.ali6000.pro.alnx4
  elif [[ "$OS_VERSION" == 3* && "$RUNNING" == 5.10.134-*al8* ]]; then
    PKG=kernel; FIX=5.10.134-19.10.al8
  elif [[ "$OS_VERSION" == 4* && "$RUNNING" == 6.6.102-*alnx4* ]]; then
    PKG=kernel; FIX=6.6.102-8.0.2.alnx4
  fi
elif [[ "$FAMILY" != debian ]]; then
  case "$OS_ID" in
    rhel|rocky|almalinux|centos|ol|fedora) FAMILY=redhat; PKG=kernel;;
    debian) FAMILY=debian; PKG=linux-image-amd64;;
    *) FAMILY=unsupported;;
  esac
fi

STATUS="$(kernel_status "$RUNNING")"
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
    upgrade_debian_kernel
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
RUNNING="$(uname -r)"
log INFO "当前运行内核（重启前不会改变）: $RUNNING"
if [[ "$FAMILY" == debian ]]; then
  log INFO "已安装内核镜像（末尾显示版本）:"
  dpkg-query -W -f='${Package} ${Version} ${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | grep 'install ok installed' || true
  INSTALLED_KERNELS="$(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' 2>/dev/null |
    awk '$2 == "install" && $3 == "ok" && $4 == "installed" { sub(/:[^:]+$/, "", $1); sub(/^linux-image-(unsigned-)?/, "", $1); print $1 }' || true)"
  if [[ -e /boot/vmlinuz ]]; then
    NEXT_KERNEL="$(readlink -f /boot/vmlinuz)"; NEXT_KERNEL="${NEXT_KERNEL##*/vmlinuz-}"
    NEXT_CONFIDENCE="/boot/vmlinuz 链接推测（不保证 GRUB 实际默认项）"
  fi
else
  log INFO "已安装 kernel 包:"
  rpm -q kernel kernel-core 2>/dev/null || true
  INSTALLED_KERNELS="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2>/dev/null || true)"
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
print_summary
if [[ "$MODE" == upgrade && "$REBOOT" == yes && "$STATUS" != FIXED ]]; then
  if [[ "$NEXT_STATUS" != FIXED || "$NEXT_CONFIDENCE" != 'grubby 默认启动项' || ! -r "${bootpath:-}" ]] ||
     ! grep -Fxq -- "$NEXT_KERNEL" <<< "$INSTALLED_KERNELS"; then
    die "未确认默认启动项为修复内核，取消自动重启；请人工核对引导项后安排重启"
  fi
  log WARN "修复内核已设为默认启动项；按 --reboot 请求，5 秒后重启"
  sleep 5
  reboot
elif [[ "$STATUS" == FIXED ]]; then
  log INFO "当前运行内核已达到修复门槛，本次不重启。"
elif [[ "$MODE" == check ]]; then
  log INFO "本次为检查模式，未执行内核升级或重启。"
else
  log INFO "本次未自动重启，请按上述最终结论安排后续操作。"
fi
log INFO "========== 结束 =========="
