#!/bin/bash

# 检查是否具有 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户执行此脚本。"
    exit 1
fi

# 设置默认值
DEVICE="/dev/vdb"
MOUNT_POINT="/coins"
FORCE_PARTITION=""

# 解析传入的参数
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE_PARTITION="--force"
    elif [[ "$arg" == /dev/* ]]; then
        DEVICE="$arg"
    else
        MOUNT_POINT="$arg"
    fi
done

# 如果设备不是 /dev/vdb 且没有提供挂载路径，则提示用户输入挂载路径
if [[ "$DEVICE" != "/dev/vdb" && "$MOUNT_POINT" == "/coins" ]]; then
    echo "非 vdb 设备，请提供挂载路径，例如 /mnt/mydisk"
    exit 1
fi

# 检查磁盘是否已有分区
if lsblk -no NAME "${DEVICE}1" &>/dev/null; then
    if [[ "$FORCE_PARTITION" != "--force" ]]; then
        echo "检测到 ${DEVICE} 已经被分区。使用 --force 参数可以强制重新分区。"
        exit 0
    else
        echo "检测到 ${DEVICE} 已经被分区，但将强制重新分区。"
    fi
fi

# 使用 parted 工具进行分区
parted "$DEVICE" <<EOF
mklabel gpt
mkpart primary 1 100%
align-check optimal 1
print
quit
EOF

# 重新读取分区表
partprobe "$DEVICE"

echo "分区操作完成。"

# 创建一个 ext4 文件系统
mkfs -t ext4 "${DEVICE}1"

# 挂载分区
mkdir -p "$MOUNT_POINT"
mount "${DEVICE}1" "$MOUNT_POINT"

# 备份 fstab 文件
cp -a /etc/fstab /etc/fstab.bak

# 生成新的挂载记录
NEW_ENTRY="$(blkid "${DEVICE}1" | awk '{print $2}' | sed 's/\"//g') $MOUNT_POINT ext4 defaults 0 0"

# 检查是否已有相同的挂载记录
if grep -Fxq "$NEW_ENTRY" /etc/fstab; then
    echo "挂载记录已存在于 /etc/fstab 中，跳过添加。"
else
    echo "$NEW_ENTRY" >> /etc/fstab
    echo "已将新挂载记录添加到 /etc/fstab。"
fi

echo "分区和挂载完成，挂载路径为 $MOUNT_POINT。"
