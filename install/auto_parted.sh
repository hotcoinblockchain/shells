#!/bin/bash


### curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s 


# 检查是否具有 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户执行此脚本。"
    exit 1
fi

# 设置默认值
DEVICE=""
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

# 自动识别设备类型（若未手动指定）
if [[ -z "$DEVICE" ]]; then
    if [ -b /dev/nvme1n1 ]; then
        DEVICE="/dev/nvme1n1"
        echo "检测到 NVMe 设备：$DEVICE"
    elif [ -b /dev/vdb ]; then
        DEVICE="/dev/vdb"
        echo "检测到普通云盘设备：$DEVICE"
    else
        echo "❌ 未检测到可用的数据盘 (/dev/nvme1n1 或 /dev/vdb)。"
        echo "请手动执行：bash auto_parted.sh /dev/<your-disk> /mnt/path"
        exit 1
    fi
else
    echo "使用指定设备：$DEVICE"
fi

# 获取分区设备名
get_partition_device() {
    local device=$1
    if [[ "$device" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
        echo "${device}n1"  # NVMe 设备格式为 nvme0n1n1
    else
        echo "${device}1"   # 传统设备格式为 sda1, vda1 等
    fi
}

PARTITION_DEVICE=$(get_partition_device "$DEVICE")

# 检查磁盘是否已有分区
if lsblk "$DEVICE" | grep -q "part"; then
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

# 等待系统识别新分区
echo "等待系统识别新分区..."
sleep 3

# 获取实际分区设备名
ACTUAL_PARTITION=$(lsblk -nlo NAME "$DEVICE" | grep -v "^$(basename "$DEVICE")$" | head -n1)
if [ -n "$ACTUAL_PARTITION" ]; then
    PARTITION_DEVICE="/dev/$ACTUAL_PARTITION"
else
    echo "错误：无法检测到分区设备"
    exit 1
fi

# 创建一个 ext4 文件系统
mkfs -t ext4 "$PARTITION_DEVICE"

# 挂载分区
mkdir -p "$MOUNT_POINT"
mount "$PARTITION_DEVICE" "$MOUNT_POINT"

# 备份 fstab 文件
cp -a /etc/fstab /etc/fstab.bak

# 生成新的挂载记录
NEW_ENTRY="$(blkid "$PARTITION_DEVICE" | awk '{print $2}' | sed 's/\"//g') $MOUNT_POINT ext4 defaults 0 0"

# 检查是否已有相同的挂载记录
if grep -Fxq "$NEW_ENTRY" /etc/fstab; then
    echo "挂载记录已存在于 /etc/fstab 中，跳过添加。"
else
    echo "$NEW_ENTRY" >> /etc/fstab
    echo "已将新挂载记录添加到 /etc/fstab。"
fi

echo "分区和挂载完成，挂载路径为 $MOUNT_POINT。"
