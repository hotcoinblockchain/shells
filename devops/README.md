# DevOps Scripts

服务器初始化、配置维护、备份恢复和日志清理脚本。

这些脚本可能修改磁盘分区、挂载配置、SSH、firewalld、内核参数或用户配置。生产环境执行前请先检查脚本内容，并确认命令中的设备和文件路径。

## Disk Partition and Mount

自动识别 `/dev/nvme1n1` 或 `/dev/vdb`，分区、格式化为 ext4，并挂载到 `/coins`：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash
```

指定磁盘和挂载点：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash -s -- /dev/vdb /coins
```

`--force` 会重新分区并破坏目标磁盘上的现有数据，使用前必须确认设备：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash -s -- /dev/vdb /coins --force
```

将已有文件系统的分区按 UUID 持久挂载，并更新 `/etc/fstab`：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/mount-by-uuid.sh | sudo bash -s -- /dev/vdb1 /coins
```

## Firewalld Rules

导出永久 firewalld 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/firewalld_rules_manager.sh | sudo bash -s -- export /coins/firewalld-backups
```

先将 runtime 规则保存为 permanent，再导出：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/firewalld_rules_manager.sh | sudo bash -s -- export /coins/firewalld-backups --runtime-to-permanent
```

导入备份文件：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/firewalld_rules_manager.sh | sudo bash -s -- import /coins/firewalld-backups/BACKUP_FILE.tar.gz
```

## SSH Hardening

预览 SSH 加固变更：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash -s -- --dry-run
```

应用 SSH 加固：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash
```

执行前应确认公钥登录正常，避免禁用密码登录后失去服务器访问权限。

## System Limits

配置文件描述符限制及节点常用网络内核参数：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/ulimit_settings.sh | bash
```

## Vim Settings

为当前用户的 `~/.vimrc` 添加粘贴模式设置：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/vim_set.sh | bash
```

## Crontab Backup and Restore

将当前用户的 crontab 备份到 `/coins`：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup
```

指定备份目录：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup /data/backups
```

恢复当前用户的 crontab：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- restore /coins/crontab-USER.backup
```

使用 `sudo` 执行时，操作对象是 root 的 crontab。

## System Log Cleanup

按默认策略清理系统日志：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash
```

指定保留天数及 `/var/log` 大小上限：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --days 90 --max-size 2G
```

仅预览，不删除日志：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --dry-run
```

直接通过网络执行脚本很方便，但生产环境建议先下载并审查，再以固定提交版本运行。
