# Usage

## software
``` shell
apt install screen supervisor firewalld -y

apt install screen glances iftop vnstat -y

apt install bpytop -y


# sudo vnstat -u -i eth0  # 替换 eth0 为你的网络接口
systemctl start vnstat
systemctl enable vnstat


apt install nginx -y
```
## vim setup
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/vim_set.sh | bash -s
```

## ulimit settings for system
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ulimit_settings.sh | bash -s
```

## mount dev by uuid
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/mount-by-uuid.sh | bash -s /dev/vdb1 /coins

```
## auto parted /dev/vdb
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s 

``` 


## ubuntu basic dependcy
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s 
```

## tinyproxy
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/tinyproxy.sh | bash -s 
```

## fail2ban
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/fail2ban.sh | bash -s
```


## git
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s 
```


## GOLANG
``` shell
# install latest stable Go
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s && source /etc/profile

# install latest patch release for Go 1.24
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24 && source /etc/profile

# install exact Go version
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.24.3 && source /etc/profile

```

## Rust&Cargo
``` shell
curl https://sh.rustup.rs -sSf | sh
```

## nodejs
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh | bash -s 
```

## docker
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | bash -s 
```

## sshd
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/harden_sshd.sh | bash -s

```
