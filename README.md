# shells

Daily-use shell and Python scripts for Linux server initialization, maintenance, proxy setup, and blockchain node operations.

Most scripts are designed for Ubuntu servers, with a few scripts also detecting CentOS. Many scripts modify system files or install packages, so review the script before running it on a production machine.

## Project Structure

```text
.
├── install/
│   ├── README.MD                    # Install script usage snippets
│   ├── auto_parted.sh               # Auto partition, format, mount data disk
│   ├── docker.sh                    # Install Docker and Docker Compose
│   ├── export_firewalld_rules.sh    # Export current firewalld rules
│   ├── fail2ban.sh                  # Install and configure fail2ban for sshd
│   ├── git.sh                       # Install Git from git-core PPA
│   ├── go.sh                        # Install latest/specified Go version
│   ├── harden_sshd.sh               # Harden sshd password/root login settings
│   ├── init_tinyproxy_cron.sh       # Add tinyproxy health-check cron job
│   ├── mount-by-uuid.sh             # Persistently mount a block device by UUID
│   ├── nodejs.sh                    # Install Node.js through NodeSource
│   ├── pyenv.sh                     # Install pyenv and pyenv-virtualenv
│   ├── rust-cargo.sh                # Install Rust through rustup
│   ├── tinyproxy.sh                 # Install and configure tinyproxy
│   ├── ubuntu-basic-dependcy.sh     # Install common Ubuntu build dependencies
│   ├── ulimit_settings.sh           # Raise fd limits and network sysctl values
│   └── vim_set.sh                   # Add paste-mode helpers to ~/.vimrc
├── update/
│   ├── nginx_add_proxy_config.sh    # Add nginx reverse proxy config
│   └── upgrade_apt_package.sh       # Upgrade an installed apt package
└── blockchains/
    └── filecoin/
        └── lotus_export_peers.py    # Export lotus peer connect commands
```

## Quick Usage

Run scripts directly from GitHub:

```bash
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/vim_set.sh | bash -s
```

Or clone the repository and run locally:

```bash
git clone https://github.com/hotcoinblockchain/shells.git
cd shells
bash install/vim_set.sh
```

## Common Install Scripts

### System Basics

```bash
# Common Ubuntu build/runtime dependencies
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s

# Raise ulimit/sysctl values for node workloads
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ulimit_settings.sh | bash -s

# Harden sshd: disable password login, lock root password, keep public-key login
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/harden_sshd.sh | bash -s
```

### Disk Mounting

```bash
# Auto-detect /dev/nvme1n1 or /dev/vdb, partition, format ext4, mount to /coins
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s

# Specify disk and mount point
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s /dev/vdb /coins

# Mount an existing partition by UUID and write /etc/fstab
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/mount-by-uuid.sh | bash -s /dev/vdb1 /coins
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

# Export firewalld rules to /coins/firewalld.rules.sh
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/export_firewalld_rules.sh | bash -s
```

## Update Scripts

```bash
# Upgrade an installed apt package
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/upgrade_apt_package.sh | bash -s nginx

# Install or update nginx reverse proxy config
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/update/nginx_add_proxy_config.sh | bash -s https://wallet.cypress.klaytn.net:8651 10082 klay
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
- `install/README.MD` keeps shorter copy-paste snippets for install scripts.
