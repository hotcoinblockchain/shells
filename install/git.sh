#!/bin/bash

### 
# usage 
# curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/git.sh | bash -s 

sudo apt update  
sudo apt install software-properties-common -y
sudo add-apt-repository ppa:git-core/ppa
sudo apt-get update
sudo apt-get install git -y
