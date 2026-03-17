#!/usr/bin/env bash


# curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/harden_sshd.sh | bash -s

set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/etc/ssh/backup"
TIMESTAMP="$(date +%F_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/sshd_config.${TIMESTAMP}.bak"

log() {
  echo "[$(date +'%F %T')] $*"
}

die() {
  echo "[$(date +'%F %T')] ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请用 root 执行"
}

detect_service_name() {
  if systemctl cat ssh >/dev/null 2>&1; then
    SSH_SERVICE="ssh"
  elif systemctl cat sshd >/dev/null 2>&1; then
    SSH_SERVICE="sshd"
  else
    die "未找到 ssh/sshd systemd 服务"
  fi
}

ensure_line() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*(${key})[[:space:]]+.*|\1 ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
  log "已备份配置到: $BACKUP_FILE"
}

show_current_config() {
  log "当前关键 SSH 配置："
  sshd -T | egrep 'permitrootlogin|passwordauthentication|permitemptypasswords|pubkeyauthentication|maxauthtries|logingracetime|usepam' || true
}

lock_root_password() {
  local status
  status="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$status" == "L" ]]; then
    log "root 密码已锁定，跳过"
  else
    passwd -l root
    log "已锁定 root 密码"
  fi
}

main() {
  need_root

  [[ -f "$SSHD_CONFIG" ]] || die "未找到 $SSHD_CONFIG"
  command -v sshd >/dev/null 2>&1 || die "未找到 sshd 命令"

  detect_service_name

  log "开始加固 SSHD"
  show_current_config
  backup_config

  # 单项修改
  ensure_line "PermitEmptyPasswords" "no" "$SSHD_CONFIG"
  ensure_line "PasswordAuthentication" "no" "$SSHD_CONFIG"
  ensure_line "PermitRootLogin" "prohibit-password" "$SSHD_CONFIG"
  ensure_line "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
  ensure_line "UsePAM" "yes" "$SSHD_CONFIG"
  ensure_line "MaxAuthTries" "3" "$SSHD_CONFIG"
  ensure_line "LoginGraceTime" "30" "$SSHD_CONFIG"

  # 锁定 root 密码
  lock_root_password

  log "修改后关键 SSH 配置："
  grep -En '^(PermitEmptyPasswords|PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|UsePAM|MaxAuthTries|LoginGraceTime)[[:space:]]+' "$SSHD_CONFIG" || true

  # 校验配置
  sshd -t
  log "sshd 配置校验通过"

  # 重启服务
  systemctl restart "$SSH_SERVICE"
  systemctl is-active "$SSH_SERVICE" >/dev/null
  log "SSH 服务已重启: $SSH_SERVICE"

  show_current_config

  cat <<EOF

加固完成。

当前效果：
- 禁止空密码登录
- 禁止密码登录
- root 禁止密码登录，但允许公钥登录
- root 密码已锁定
- 公钥登录开启
- 最大认证次数 3
- 登录宽限时间 30 秒

备份文件：
$BACKUP_FILE

EOF
}

main "$@"
