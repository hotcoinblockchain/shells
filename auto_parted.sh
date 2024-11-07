#!/bin/bash

# /dev/vdb
# curl -sSL https://raw.githubusercontent.com/hotcoin-walle/shells/main/install/auto_parted.sh | bash -s 


# 检查是否具有 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户执行此脚本。"
    exit 1
fi

# 设置分区的设备名称
DEVICE="/dev/vdb"

# 使用 parted 工具进行分区
parted $DEVICE <<EOF
mklabel gpt
mkpart primary 1 100%
align-check optimal 1
print
quit
EOF

# 重新读取分区表
partprobe $DEVICE

echo "分区操作完成。"


#创建一个ext4文件系统
mkfs -t ext4 /dev/vdb1

#挂载
mkdir /coins
mount /dev/vdb1 /coins

#备份fstab
cp -a /etc/fstab /etc/fstab.bak
# 将新分区写入fstab
echo `blkid /dev/vdb1 | awk '{print $2}' | sed 's/\"//g'` /coins ext4 defaults 0 0 >> /etc/fstab


