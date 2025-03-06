# Usage

## software
```
apt install screen supervisor firewalld -y

apt install screen glances iftop vnstat -y

pip3 install bpytop


# sudo vnstat -u -i eth0  # 替换 eth0 为你的网络接口
systemctl start vnstat
systemctl enable vnstat


apt install nginx -y
```

## auto parted /dev/vdb
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/auto_parted.sh | bash -s 

```


## ubuntu basic dependcy
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s 
```

## tinyproxy
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/tinyproxy.sh | bash -s 
```



## git
``` shell
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s 
```


## GOLANG
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/go.sh | bash -s 1.23.2 && source /etc/profile

```

## Rust&Cargo
```
curl -sSf https://static.rust-lang.org/rustup.sh | sh
```

## nodejs
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/nodejs.sh | bash -s 
```

## docker
```
curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/docker.sh | bash -s 
```
