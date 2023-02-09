#! /bin/bash
check_sys() {
        if [ -f "/etc/redhat-release" ]; then
                release="centos"
        elif [ "$(cat /etc/issue | awk '{print $1}')" == "Ubuntu" ] || [ "$(cat /etc/issue | awk '{print $1}')" == "Armbian" ]; then
                release="ubuntu"
        fi
}

install_dependecy() {
        echo "current system is $release . starting to install tar unzip pigz aria2"
        echo "$release"
        if [ $release == "centos" ]; then
                yum install tinyproxy -y
        elif [ $release == "ubuntu" ]; then
                apt update
                sudo apt-get install tinyproxy -y
        fi
}

check_installed() {
    if [ ! -f "/usr/sbin/tinyproxy" ]; then
        check_sys && install_dependecy
        configFile=/etc/tinyproxy.conf
        if [ ! -f "/etc/tinyproxy.conf" ]; then
            configFile=/etc/tinyproxy/tinyproxy.conf
        fi
        sed -i "s/#Allow 127.0.0.1/Allow 127.0.0.1/g" $configFile
        sed -i "s/^Allow 127.0.0.1/# Allow all \nAllow 0.0.0.0\/0\n\n#Allow 127.0.0.1/g" $configFile
        systemctl enable tinyproxy.service
        systemctl restart tinyproxy.service
    fi
}

check_installed
