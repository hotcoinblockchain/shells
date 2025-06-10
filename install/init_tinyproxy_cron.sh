#!/bin/bash

### curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/init_tinyproxy_cron.sh | bash -s  HOOK_URL

# 检查是否存在 tinyproxy 进程
if ! pgrep -f tinyproxy > /dev/null; then
    echo "No tinyproxy process found. Exit."
    exit 0
fi

# 要写入的目标监控脚本路径
MONITOR_SCRIPT="/root/check_tinyproxy.sh"

# 如果没有这个脚本，则写入
if [ ! -f "$MONITOR_SCRIPT" ]; then
    cat << 'EOF' > "$MONITOR_SCRIPT"
#!/bin/bash

HOOK_URL=$1
LOG_FILE="/var/log/tinyproxy_monitor.log"

get_local_ip() {
    ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Unknown"
}

get_proxy_port() {
    netstat -ntpl 2>/dev/null | grep tinyproxy | grep -v tcp6 | awk '{print $4}' | awk -F: '{print $NF}' | head -n 1
}

get_direct_ip() {
    curl -s --max-time 5 ip.sb
}

get_proxy_ip() {
    local port="$1"
    curl -s --max-time 5 -x http://127.0.0.1:${port} ip.sb
}

restart_tinyproxy() {
    systemctl restart tinyproxy
    echo "$(date): tinyproxy restarted" >> "$LOG_FILE"
}

send_alert() {
    local_ip=$(get_local_ip)
    msg="# **tinyproxy 服务异常** \n- ${local_ip}:$(get_proxy_port) ，$1。"
    curl -s -X POST "${HOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"${msg}\"}}"
}

check_proxy() {
    proxy_port=$(get_proxy_port)

    if [[ -z "$proxy_port" ]]; then
        echo "$(date): 未检测到 tinyproxy 监听端口，跳过对比，触发告警。" >> "$LOG_FILE"
        send_alert "未检测到 tinyproxy 监听端口❌"
        return
    fi

    direct_ip=$(get_direct_ip)
    proxy_ip=$(get_proxy_ip "$proxy_port")

    echo "$(date): Direct IP = ${direct_ip}, Proxy IP = ${proxy_ip} (port: $proxy_port)" >> "$LOG_FILE"

    if [ "$direct_ip" != "$proxy_ip" ]; then
        echo "$(date): IP mismatch, restarting tinyproxy..." >> "$LOG_FILE"
        restart_tinyproxy
        sleep 10

        direct_ip=$(get_direct_ip)
        proxy_ip=$(get_proxy_ip "$proxy_port")

        echo "$(date): After restart - Direct IP = ${direct_ip}, Proxy IP = ${proxy_ip}" >> "$LOG_FILE"

        if [ "$direct_ip" != "$proxy_ip" ]; then
            echo "$(date): Restart ineffective, sending alert." >> "$LOG_FILE"
            send_alert "重启后仍然异常，需人工处理❌"
        else
            echo "$(date): Restart resolved the issue." >> "$LOG_FILE"
            send_alert "重启后回复正常✔"
        fi
    else
        echo "$(date): IPs match, no action needed." >> "$LOG_FILE"
    fi
}

check_proxy
EOF

    chmod +x "$MONITOR_SCRIPT"
    echo "已写入 $MONITOR_SCRIPT"
fi

# 检查是否已存在 crontab 任务
if ! crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    (crontab -l 2>/dev/null; echo "* * * * * $MONITOR_SCRIPT") | crontab -
    echo "已添加 crontab 任务：每分钟执行 $MONITOR_SCRIPT"
else
    echo "crontab 中已存在该任务，无需重复添加"
fi
