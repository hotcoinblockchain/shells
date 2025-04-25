#!/bin/bash

CONF_FILE="/etc/fail2ban/jail.d/defaults-debian.conf"

# 确保 fail2ban 服务开启
apt update
apt install fail2ban -y
systemctl enable fail2ban.service
systemctl start fail2ban.service

# 检查配置文件是否存在
if [ ! -f "$CONF_FILE" ]; then
    echo "配置文件 $CONF_FILE 不存在，创建中..."
    echo "[sshd]" > "$CONF_FILE"
fi

# 检查是否有 bantime 配置
if ! grep -qE '^\s*bantime\s*=' "$CONF_FILE"; then
    echo "bantime 未配置，添加 bantime = 1h"
    echo "bantime = 1h" >> "$CONF_FILE"
else
    echo "已存在 bantime 配置，跳过。"
fi

# 检查是否有 maxretry 配置
if ! grep -qE '^\s*maxretry\s*=' "$CONF_FILE"; then
    echo "maxretry 未配置，添加 maxretry = 5"
    echo "maxretry = 5" >> "$CONF_FILE"
else
    echo "已存在 maxretry 配置，跳过。"
fi

# 重启 fail2ban 服务以应用修改
systemctl restart fail2ban.service
echo "fail2ban 配置已检查并应用。"
