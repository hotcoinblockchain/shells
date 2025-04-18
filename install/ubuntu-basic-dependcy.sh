#!/bin/bash

# curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/ubuntu-basic-dependcy.sh | bash -s 


sudo apt install -y g++ gcc cmake wget curl supervisor screen firewalld nginx
sudo apt-get install -y libleveldb-dev sqlite3 libsqlite3-dev libunwind8-dev 
sudo apt-get install -y librocksdb-dev 


sudo apt-get install -y libleveldb-dev libssl-dev



sudo apt-get install -y software-properties-common
# sudo add-apt-repository ppa:bitcoin/bitcoin
sudo apt-get update
sudo apt-get install -y build-essential libtool autotools-dev automake pkg-config libssl-dev libevent-dev bsdmainutils python3 libboost-all-dev

## libdb4.8
sudo apt-get install -y libdb4.8-dev libdb4.8++-de

## libs
sudo apt-get install -y libminiupnpc-dev libzmq3-dev libqt5gui5 libqt5core5a libqt5dbus5 qttools5-dev qttools5-dev-tools libprotobuf-dev protobuf-compiler libqrencode-dev pkg-config autoconf libtool libdb-dev  libdb++-dev  libboost-dev libboost-system-dev libboost-filesystem-dev libboost-chrono-dev libboost-program-options-dev libboost-test-dev libboost-thread-dev  libssl-dev libevent-dev libcurl4-openssl-dev libffi-dev openssl-dev uuid-dev libffi-dev

for pkg in zlib1g-dev libbz2-dev liblzma-dev libncurses5-dev libreadline6-dev libsqlite3-dev libssl-dev libgdbm-devliblzma-dev tk8.5-dev lzma lzma-dev libgdbm-dev
do
    apt-get -y install $pkg
done
