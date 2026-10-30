# shells

[English](README.md) | 中文

用于 Linux 服务器初始化、日常维护、代理配置和区块链节点运维的 Shell 与 Python 脚本集合。

大多数脚本面向 Ubuntu 服务器，少量脚本也会检测 CentOS。许多脚本会修改系统文件或安装软件包，在生产服务器上执行前请先阅读并确认脚本内容。

## 项目结构

```text
.
├── install/
│   ├── README.MD                    # 软件安装脚本使用示例
│   ├── docker.sh                    # 安装 Docker 和 Docker Compose
│   ├── fail2ban.sh                  # 安装并配置 sshd 的 fail2ban
│   ├── git.sh                       # 通过 git-core PPA 安装 Git
│   ├── go.sh                        # 安装最新或指定版本的 Go
│   ├── init_tinyproxy_cron.sh       # 添加 tinyproxy 健康检查定时任务
│   ├── nodejs.sh                    # 通过 NVM 安装和管理 Node.js
│   ├── pyenv.sh                     # 安装 pyenv 和 pyenv-virtualenv
│   ├── rust-cargo.sh                # 通过 rustup 安装 Rust
│   ├── tinyproxy.sh                 # 安装并配置 tinyproxy
│   └── ubuntu-basic-dependcy.sh     # 安装 Ubuntu 常用编译依赖
├── update/
│   ├── nginx_add_proxy_config.sh    # 添加 Nginx 反向代理配置
│   └── upgrade_apt_package.sh       # 升级已安装的 apt 软件包
├── devops/
│   ├── README.md                    # DevOps 脚本说明和 curl 示例
│   ├── auto_parted.sh               # 自动分区、格式化并挂载数据盘
│   ├── cleanup-system-logs.sh       # 按时间和容量轮转、清理系统日志
│   ├── crontab-backup-restore.sh    # 备份和恢复当前用户的 crontab
│   ├── fastdir-backup.sh            # 使用 tar/zstd 快速备份并分阶段恢复目录
│   ├── firewalld_rules_manager.sh   # 导出和导入 firewalld 配置
│   ├── harden_sshd.sh               # 加固 sshd 密码和 root 登录配置
│   ├── mount-by-uuid.sh             # 按 UUID 持久挂载块设备
│   ├── ulimit_settings.sh           # 调整文件描述符和网络内核参数
│   └── vim_set.sh                   # 向 ~/.vimrc 添加粘贴模式配置
│   └── security_audit.sh            # 服务器安全审计
│   └── system_migrate.sh            # 系统备份
└── blockchains/
    └── filecoin/
        └── lotus_export_peers.py    # 导出 Lotus 节点连接命令
```

## 快速使用

直接运行 GitHub 上的脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/vim_set.sh | bash
```

也可以克隆仓库后在本地运行：

```bash
git clone https://github.com/hotcoinblockchain/shells.git
cd shells
bash devops/vim_set.sh
```

## 默认初始化

```bash
# 常用软件
apt update
apt install screen supervisor firewalld -y
apt install glances iftop vnstat -y
apt install bpytop

# Vim
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/vim_set.sh | bash

# 系统限制
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/ulimit_settings.sh | bash

# SSH 加固
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash

# 清理系统日志
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --days 90 --max-size 2G

# fail2ban
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s

# pyenv
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# Docker
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- setup /coins/docker
```

## 常用安装与配置脚本

### 系统基础配置

```bash
# Ubuntu 常用编译和运行依赖
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s

# 为节点服务调整 ulimit 和 sysctl 参数
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/ulimit_settings.sh | bash

# 加固 sshd：禁用密码登录、锁定 root 密码并保留公钥登录
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash
```

### 磁盘分区与挂载

```bash
# 自动识别 /dev/nvme1n1 或 /dev/vdb，分区、格式化为 ext4 并挂载到 /coins
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash

# 指定磁盘和挂载点
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash -s -- /dev/vdb /coins

# 按 UUID 挂载已有分区并写入 /etc/fstab
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/mount-by-uuid.sh | sudo bash -s -- /dev/vdb1 /coins
```

### 开发运行环境

```bash
# Git
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s

# 最新稳定版 Go
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s

# Go 1.24 的最新补丁版本
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24

# 指定 Go 完整版本
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24.3
source /etc/profile

# Rust
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/rust-cargo.sh | bash -s

# 通过 NVM 安装 Node.js：下载一次，然后安装指定版本、最新版或最新 LTS
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh -o /tmp/nodejs.sh
bash /tmp/nodejs.sh install 20
bash /tmp/nodejs.sh latest
bash /tmp/nodejs.sh lts

# pyenv
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# Docker
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | bash -s

# 单独安装最新版 docker-compose 到 /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- compose
```

### 代理与安全

```bash
# tinyproxy
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/tinyproxy.sh | bash -s

# tinyproxy 监控定时任务，需要提供 webhook 地址
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/init_tinyproxy_cron.sh | bash -s WEBHOOK_URL

# fail2ban
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s

# 先下载并检查 firewalld 管理脚本
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/firewalld_rules_manager.sh \
  -o /tmp/firewalld_rules_manager.sh

# 导出全部 firewalld 永久配置
sudo bash /tmp/firewalld_rules_manager.sh export /coins/firewalld-backups

# 系统重装后导入配置，将 BACKUP_FILE 替换为实际备份文件名
sudo bash /tmp/firewalld_rules_manager.sh import /coins/firewalld-backups/BACKUP_FILE.tar.gz
```

## 更新脚本

```bash
# 升级已安装的 apt 软件包
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/upgrade_apt_package.sh | bash -s nginx

# 安装或更新 Nginx 反向代理配置
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/nginx_add_proxy_config.sh | bash -s https://wallet.cypress.klaytn.net:8651 10082 klay
```

## DevOps 脚本

### 快速目录备份与恢复

主要依赖 `zstd`、`rsync`、GNU `tar`、`flock` 和 `sha256sum`。Ubuntu/Debian 通常只需额外安装以下软件包，然后赋予脚本执行权限：

```bash
apt update
apt install -y zstd rsync
chmod +x devops/fastdir-backup.sh
```

备份 `/root` 目录中的内容。`--threads 0` 表示让 zstd 自动使用全部 CPU 核心：

```bash
./devops/fastdir-backup.sh backup \
  --source /root \
  --output /backup/root-2026-08-12.tar.zst \
  --threads 0
```

校验备份及自动生成的 `.sha256` 文件：

```bash
./devops/fastdir-backup.sh verify \
  --archive /backup/root-2026-08-12.tar.zst
```

恢复到空目录：

```bash
./devops/fastdir-backup.sh restore \
  --archive /backup/root-2026-08-12.tar.zst \
  --dest /restore/root
```

覆盖或合并到已有的 `/root`，必须显式指定 `--merge`：

```bash
./devops/fastdir-backup.sh restore \
  --archive /backup/root-2026-08-12.tar.zst \
  --dest /root \
  --merge
```

偏重备份速度并排除缓存目录：

```bash
./devops/fastdir-backup.sh backup \
  --source /root \
  --output /backup/root.tar.zst \
  --threads 0 \
  --level 1 \
  --exclude '.cache'
```

其他常用参数包括：`--threads 16` 使用 16 个压缩线程；重复使用 `--exclude` 排除多个模式；`--one-file-system` 不跨挂载点；`--level 1` 到 `--level 19` 调整压缩速度和压缩率；`--staging-dir /data/tmp` 在另一块大硬盘上临时解压。

安全行为：备份的是源目录中的内容，不额外嵌套源目录名；自动生成并强制校验 `.sha256`；恢复前测试 zstd 文件和 tar 路径；默认禁止恢复到非空目录；先解压到 staging，再用 rsync 同步；保留权限、UID/GID、软链接、硬链接、ACL、xattr 和稀疏文件；使用 `flock` 防止并发任务；禁止将 `/` 作为源目录或恢复目标；备份写入临时文件并在完成后原子发布。

该版本使用 tar 顺序读取文件、zstd 多线程压缩，不是多个 worker 同时并行读取不同文件。

### Crontab 备份与恢复

默认将当前用户的 crontab 备份到 `/coins/crontab-用户名.backup`：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup
```

指定其他备份目录：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup /data/backups
```

从备份文件恢复当前用户的 crontab：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- restore /coins/crontab-USER.backup
```

以上命令直接执行 `main` 分支。生产环境建议先下载并检查脚本。除非需要操作 root 的 crontab，否则不要使用 `sudo`。

### 系统日志清理

清理并轮转系统日志。默认保留 30 天，并将 `/var/log` 总大小限制为 5GB：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash
```

指定日志保留天数和容量上限：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --days 90 --max-size 2G
```

仅预览清理操作，不删除文件：

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --dry-run
```

## 区块链脚本

### Filecoin

`blockchains/filecoin/lotus_export_peers.py` 读取 `lotus net peers`，并输出 `lotus net connect ...` 连接命令。

```bash
python3 blockchains/filecoin/lotus_export_peers.py
```

## 注意事项

- 安装软件或写入 `/etc`、`/usr/local`、`/coins`、crontab、Nginx、sshd、firewalld 的脚本通常需要 root 权限。
- `auto_parted.sh --force` 会重新分区磁盘，执行前必须确认目标设备。
- `harden_sshd.sh` 会禁用密码登录，断开当前会话前请确认公钥登录正常。
- `install/README.MD` 提供软件安装命令；`devops/README.md` 提供服务器运维和配置脚本说明。
