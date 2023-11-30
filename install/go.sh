
#!/bin/bash

### 
# usage 
# curl -sSL https://raw.githubusercontent.com/hotcoin-walle/shells/main/install/go.sh | bash -s 1.20.7
if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

VERSION=$1
EXISTING=$(grep -c "export GOROOT=/usr/local/go" /etc/profile)

if [ $EXISTING -eq 0 ]; then
    echo "###### go environment #######" >> /etc/profile
    echo "export GOROOT=/usr/local/go" >> /etc/profile
    echo "export GOPATH=~/go" >> /etc/profile
    echo "export GOBIN=\$GOPATH/bin" >> /etc/profile
    echo "export PATH=\$GOBIN:\$PATH" >> /etc/profile
    echo "export PATH=\$GOROOT/bin:\$PATH" >> /etc/profile
fi

rm -rf /usr/local/go
wget https://dl.google.com/go/go$VERSION.linux-amd64.tar.gz
tar -zxvf go$VERSION.linux-amd64.tar.gz
mv -f go /usr/local/
mkdir -p ~/go/bin

cp /etc/profile /etc/profile.$(date +%Y%m%d%H%M).bak
source /etc/profile
