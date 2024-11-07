#!/bin/bash

# remove docker installed by ubuntu repository
sudo apt-get remove docker docker-engine docker.io containerd runc

curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
curl -sSL https://get.daocloud.io/docker | sh
