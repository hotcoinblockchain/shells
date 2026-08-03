# Usage

## Default Install 

```bash
# install 
apt update
apt install screen supervisor firewalld -y
apt install glances iftop vnstat -y
apt install bpttop

# vim
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/vim_set.sh | bash -s

# handlers
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ulimit_settings.sh | bash -s

# sshd
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/harden_sshd.sh | bash -s

# fail2ban
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s

# pyenv
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# docker
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- setup /coins/docker
```

## software

```shell
apt install screen supervisor firewalld -y
apt install glances iftop vnstat -y
apt install bpytop -y

# sudo vnstat -u -i eth0  # 替换 eth0 为你的网络接口
systemctl start vnstat
systemctl enable vnstat


apt install nginx -y
```

## vim setup

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/vim_set.sh | bash -s
```

## ulimit settings for system

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ulimit_settings.sh | bash -s
```

## mount dev by uuid

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/mount-by-uuid.sh | bash -s --  /dev/vdb1 /coins
```

## auto parted /dev/vdb

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s 
```

## ubuntu basic dependcy

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s 
```

## tinyproxy

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/tinyproxy.sh | bash -s 
```

## fail2ban

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s
```

## git

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s 
```

## GOLANG

```shell
# install latest stable Go
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s && source /etc/profile

# install latest patch release for Go 1.24
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24 && source /etc/profile

# install exact Go version
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24.3 && source /etc/profile
```

## Rust&Cargo

```shell
curl https://sh.rustup.rs -sSf | sh
```

## nodejs

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh | bash -s 
```

## pyenv

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/pyenv.sh | bash -s
source ~/.bashrc

# usage in crontab
# 0 8 * * * /root/.pyenv/bin/pyenvs 3.10.12 /root/apps/autosign/aliyun-auto-signin/app.py
```

## docker

```shell
# 默认仅显示 usage
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | bash

# 安装、自动配置并启动
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- install

# 一键安装、配置、迁移数据到 /data/docker 并启动
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- setup /data/docker

# 关闭或启动 Docker
sudo ./docker.sh stop
sudo ./docker.sh start
```

## sshd

```shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/harden_sshd.sh | bash -s
```
