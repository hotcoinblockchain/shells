# 1. 临时提升当前会话（立即生效，重启失效）
ulimit -n 1048576

# 2. 永久提升当前用户（推荐所有节点都这么做）
sudo tee /etc/security/limits.d/99-blockchain.conf <<EOF
# <domain>      <type>  <item>         <value>
*               soft    nofile         1048576
*               hard    nofile         1048576
root            soft    nofile         1048576
root            hard    nofile         1048576
EOF

# 3. 系统级全局最大值（必须改，不然上面也无效）
sudo tee /etc/sysctl.d/99-blockchain.conf <<EOF
# 最大文件描述符数量（系统全局）
fs.file-max = 2097152

# 每个进程最大能申请的 fd 数量
fs.nr_open = 2097152

# 下面这些顺手一起调了，防其他连接问题
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF

# 4. 立即生效
sudo sysctl -p /etc/sysctl.d/99-blockchain.conf

# 5.查看结果
echo "######## show ulimit settings ########"
ulimit -n
cat /etc/sysctl.d/99-blockchain.conf
cat /etc/security/limits.d/99-blockchain.conf
