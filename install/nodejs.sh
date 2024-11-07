#!/bin/bash

# https://github.com/nodesource/distributions?tab=readme-ov-file#ubuntu-versions

sudo apt-get install -y curl
curl -fsSL https://deb.nodesource.com/setup_23.x -o nodesource_setup.sh
sudo -E bash nodesource_setup.sh
sudo apt update
sudo apt-get install -y nodejs
