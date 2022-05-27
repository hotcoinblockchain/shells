#! /bin/bash

# auto install nginx proxy for chain nodes; 
# curl https://raw.githubusercontent.com/hotcoin-walle/shells/main/addnginx.sh | bash -s https\\:\\/\\/wallet.cypress.klaytn.net:8651 10082 klay

weburl=$1
webport=$2
configureName=$3.conf
filePath=/etc/nginx/conf.d/${configureName}


check_sys(){
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif [[ `cat /etc/issue | awk '{print $1}'` == "Ubuntu" ]]; then
        release="ubuntu"
    fi
}


install_nginx(){
    if [ ! -d "/etc/nginx" ];then
        if [[ $release == "centos" ]]; then
            # yum install -y http://rpms.famillecollet.com/enterprise/remi-release-7.rpm
            # yum --enablerepo=remi install -y redis
            yum install nginx -y
        elif [[ $release == "ubuntu" ]]; then
            apt update
            sudo apt-get install -y nginx
        fi
    fi
}

wirte_settings(){
    mkdir -p /etc/nginx/conf.d/
    cat >  ${filePath} <<EOF
##
# You should look at the following URL's in order to grasp a solid understanding
# of Nginx configuration files in order to fully unleash the power of Nginx.
# http://wiki.nginx.org/Pitfalls
# http://wiki.nginx.org/QuickStart
# http://wiki.nginx.org/Configuration
#
# Generally, you will want to move this file somewhere, and start with a clean
# file but keep this around for reference. Or just disable in sites-enabled.
#
# Please see /usr/share/doc/nginx-doc/examples/ for more detailed examples.
##

# Default server configuration
#



server {
        listen 10081;
        server_name _;
        location / {
            client_max_body_size 10m;
            client_body_buffer_size 10m;
            proxy_buffer_size 1m;
            proxy_buffers 50 5m;
            proxy_busy_buffers_size 5m;
            proxy_temp_file_write_size 5m;
            proxy_ssl_server_name on;
            proxy_pass https://nodes;
        }
}

EOF

    #update conf
    sed -i "s/listen 10081/listen ${webport}/g" ${filePath}
    sed -i "s/proxy_pass\ https\:\/\/nodes/proxy_pass\ ${weburl}/g" ${filePath}
}






open_proxy_ssl_server_name(){
    # checkou ssl proxy name
    let defaultCount=1
    count=`cat /etc/nginx/conf.d/${configureName}|grep "proxy_ssl_server_name on;" |wc -l`

    if [ ! $defaultCount -eq $count ];then
        if [ -f ${filePath} ];then
            sed -i "s/proxy_temp_file_write_size 5m;/proxy_temp_file_write_size 5m;\n            proxy_ssl_server_name on; /g" ${filePath}
            nginx -s reload
        fi
    fi
}

start_nginx(){
    systemctl enable nginx
    systemctl start nginx
    nginx -s reload
}

# 

check_sys && install_nginx && wirte_settings && open_proxy_ssl_server_name && start_nginx
