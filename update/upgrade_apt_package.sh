#!/bin/bash

### tips ### 
## usage 
# curl -sSL https://raw.githubusercontent.com/hotcoin-walle/shells/main/upgrade_apt_package.sh | bash -s nginx

## mul

# packages=("package1" "package2" "package3")  # array of packages
# for package in "${packages[@]}"; do
#     curl -sSL https://raw.githubusercontent.com/hotcoin-walle/shells/main/upgrade_apt_package.sh | bash -s "$package"  
# done



packageName=$1
version=$2

# check package is installed
if dpkg -l | grep -q "^ii.*${packageName}"; then
    echo "Package '${packageName}' is installed."
    
    # if exist version try to install
    if [ -n "$version" ]; then
        echo "Attempting to upgrade '${packageName}' to version '${version}'..."
        sudo apt-get install "${packageName}=${version}" -y
    else
        echo "No version specified. Performing regular upgrade of '${packageName}'..."
        sudo apt-get install --only-upgrade "${packageName}" -y
    fi
else
    echo "Package '${packageName}' is not installed."
fi
