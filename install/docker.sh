#!/bin/bash

# remove docker installed by ubuntu repository
sudo apt-get remove docker docker-engine docker.io containerd runc

curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
# curl -sSL https://get.daocloud.io/docker | sh
curl -L https://github.com/docker/compose/releases/download/v2.35.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
chmod +x  /usr/local/bin/docker-compose
