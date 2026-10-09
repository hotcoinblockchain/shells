# Usage

本目录只保留软件安装脚本。磁盘、挂载、SSH、firewalld、系统限制和 Vim 配置脚本已移至 [`devops/`](../devops/README.md)。

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
# 默认只显示 usage
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh \
  -o /tmp/nodejs.sh
bash /tmp/nodejs.sh

# 通过 NVM 安装指定 Node.js 版本或版本线
bash /tmp/nodejs.sh install 20
bash /tmp/nodejs.sh install 20.18.1

# 安装最新 Node.js 或最新 LTS
bash /tmp/nodejs.sh latest
bash /tmp/nodejs.sh lts
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

# 仅安装最新版 docker-compose 到 /usr/local/bin/docker-compose
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- compose

# 仅安装指定版本（VERSION 可带或不带 v）
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- compose 5.1.4

# 一键安装、配置、迁移数据到 /data/docker 并启动
curl -fsSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | sudo bash -s -- setup /data/docker

# 关闭或启动 Docker
sudo ./docker.sh stop
sudo ./docker.sh start
```
