# shells

English | [中文](README_CN.md)

Daily-use shell and Python scripts for Linux server initialization, maintenance, proxy setup, and blockchain node operations.

Most scripts are designed for Ubuntu servers, with a few scripts also detecting CentOS. Many scripts modify system files or install packages, so review the script before running it on a production machine.

## Project Structure

```text
.
├── install/
│   ├── README.MD                    # Install script usage snippets
│   ├── docker.sh                    # Install Docker and Docker Compose
│   ├── fail2ban.sh                  # Install and configure fail2ban for sshd
│   ├── git.sh                       # Install Git from git-core PPA
│   ├── go.sh                        # Install latest/specified Go version
│   ├── init_tinyproxy_cron.sh       # Add tinyproxy health-check cron job
│   ├── nodejs.sh                    # Install Node.js through NodeSource
│   ├── pyenv.sh                     # Install pyenv and pyenv-virtualenv
│   ├── rust-cargo.sh                # Install Rust through rustup
│   ├── tinyproxy.sh                 # Install and configure tinyproxy
│   └── ubuntu-basic-dependcy.sh     # Install common Ubuntu build dependencies
├── update/
│   ├── nginx_add_proxy_config.sh    # Add nginx reverse proxy config
│   └── upgrade_apt_package.sh       # Upgrade an installed apt package
├── devops/
│   ├── README.md                    # DevOps script usage and curl examples
│   ├── auto_parted.sh               # Auto partition, format, mount data disk
│   ├── cleanup-system-logs.sh       # Rotate and clean system logs by age/size
│   ├── crontab-backup-restore.sh    # Backup and restore the current user's crontab
│   ├── firewalld_rules_manager.sh   # Export and import firewalld configuration
│   ├── harden_sshd.sh               # Harden sshd password/root login settings
│   ├── mount-by-uuid.sh             # Persistently mount a block device by UUID
│   ├── ulimit_settings.sh           # Raise fd limits and network sysctl values
│   └── vim_set.sh                   # Add paste-mode helpers to ~/.vimrc
└── blockchains/
    └── filecoin/
        └── lotus_export_peers.py    # Export lotus peer connect commands
```

## Quick Usage

Run scripts directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/vim_set.sh | bash
```

Or clone the repository and run locally:

```bash
git clone https://github.com/hotcoinblockchain/shells.git
cd shells
bash devops/vim_set.sh
```

## Default Install

```bash
# install 
apt update
apt install screen supervisor firewalld -y
apt install glances iftop vnstat -y
apt install bpytop

# vim
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/vim_set.sh | bash

# handlers
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/ulimit_settings.sh | bash

# sshd
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash

# clean system logs
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --days 90 --max-size 2G

# fail2ban
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s

# pyenv
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# docker
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- setup /coins/docker
```

## Common Install Scripts

### System Basics

```bash
# Common Ubuntu build/runtime dependencies
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s

# Raise ulimit/sysctl values for node workloads
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/ulimit_settings.sh | bash

# Harden sshd: disable password login, lock root password, keep public-key login
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/harden_sshd.sh | sudo bash
```

### Disk Mounting

```bash
# Auto-detect /dev/nvme1n1 or /dev/vdb, partition, format ext4, mount to /coins
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash

# Specify disk and mount point
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/auto_parted.sh | sudo bash -s -- /dev/vdb /coins

# Mount an existing partition by UUID and write /etc/fstab
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/mount-by-uuid.sh | sudo bash -s -- /dev/vdb1 /coins
```

### Runtime Tools

```bash
# Git
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s

# Go
# Latest stable Go
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s

# Latest patch release for Go 1.24
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24

# Exact Go version
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24.3
source /etc/profile

# Rust
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/rust-cargo.sh | bash -s

# Node.js
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh | bash -s

# pyenv
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# Docker
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | bash -s
```

### Proxy and Security

```bash
# tinyproxy
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/tinyproxy.sh | bash -s

# tinyproxy monitor cron, requires a webhook URL
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/init_tinyproxy_cron.sh | bash -s WEBHOOK_URL

# fail2ban
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s

# Download and review the script first
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/firewalld_rules_manager.sh \
  -o /tmp/firewalld_rules_manager.sh

# Export all permanent firewalld configuration to a backup directory
sudo bash /tmp/firewalld_rules_manager.sh export /coins/firewalld-backups

# Import after reinstalling the system (replace BACKUP_FILE with the exported archive)
sudo bash /tmp/firewalld_rules_manager.sh import /coins/firewalld-backups/BACKUP_FILE.tar.gz
```

## Update Scripts

```bash
# Upgrade an installed apt package
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/upgrade_apt_package.sh | bash -s nginx

# Install or update nginx reverse proxy config
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/nginx_add_proxy_config.sh | bash -s https://wallet.cypress.klaytn.net:8651 10082 klay
```

## DevOps Scripts

### Crontab Backup and Restore

Back up the current user's crontab to `/coins/crontab-USER.backup` by default:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup
```

Specify another backup directory:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- backup /data/backups
```

Restore the current user's crontab from a backup file:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/crontab-backup-restore.sh | bash -s -- restore /coins/crontab-USER.backup
```

The commands above execute the current `main` branch directly. For production systems, download and inspect the script first. Do not use `sudo` unless you intend to back up or restore root's crontab.

### System Log Cleanup

Clean and rotate system logs. The defaults retain logs for up to 30 days and limit `/var/log` to 5GB:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash
```

Specify the retention period and maximum size:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --days 90 --max-size 2G
```

Preview the cleanup without deleting anything:

```bash
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/devops/cleanup-system-logs.sh | sudo bash -s -- --dry-run
```

## Blockchain Scripts

### Filecoin

`blockchains/filecoin/lotus_export_peers.py` reads `lotus net peers` and prints `lotus net connect ...` commands.

```bash
python3 blockchains/filecoin/lotus_export_peers.py
```

## Notes

- Scripts that install packages or write to `/etc`, `/usr/local`, `/coins`, crontab, nginx, sshd, or firewalld usually require root privileges.
- `auto_parted.sh --force` can repartition a disk. Use it only after confirming the target device.
- `harden_sshd.sh` disables password authentication. Confirm public-key login works before disconnecting from the server.
- `install/README.MD` contains software installation snippets; `devops/README.md` documents server operations and configuration scripts.
