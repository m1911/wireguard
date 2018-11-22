#!/bin/bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#检测是否是root用户
if [ $(id -u) != "0" ]; then
	echo "错误：必须使用Root用户才能执行此脚本."
	exit 1
fi
#检查系统版本
checkOS()
{
	if [ -f /usr/bin/yum ]; then
		system=`rpm -q centos-release|cut -d- -f3`
		if [ ${system} -lt 7 ]; then
			echo "当前脚只支持CentOS7！"
			exit
		fi
	fi
}
#更新内核
update_kernel()
{
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
	rpm -Uvh https://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
	yum -y --enablerepo=elrepo-kernel install kernel-lt kernel-lt-devel
	grub2-set-default 0
    read -p "需要重启VPS，再次执行脚本选择安装wireguard，是否现在重启? [Y/n]:" is_reboot
	if [[ ${is_reboot} == [yY] ]]; then
        reboot
	else
		echo -e "\033[32m"请自行手动重启服务器"\033[0m"
		exit
	fi
}
#配置防火墙
checkfirewall()
{
    if [ -e /etc/sysconfig/firewalld ]; then
        systemctl stop firewalld
        systemctl disable firewalld
        yum -y install iptables-services
        systemctl enable iptables
        systemctl start iptables
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        service iptables save
        service iptables restart
    else
        yum -y install iptables-services
        systemctl enable iptables
        systemctl start iptables
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        service iptables save
        service iptables restart
    fi
}
#生成随机端口
rand()
{
    min=$1
    max=$(($2-$min+1))
    num=$(cat /dev/urandom | head -n 10 | cksum | awk -F ' ' '{print $1}')
    echo $(($num%$max+$min))  
}
#更新wireguard
wg_update()
{
    yum -y update wireguard-dkms wireguard-tools
    echo "更新完成"
}
#生成客户端配置文件
build_config()
{
	cat > /etc/wireguard/client/default.conf <<-EOF
[Interface]
PrivateKey = $cPRIVATEkey
Address = 10.0.0.2/24 
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $sPUBLICkey
Endpoint = $serverip:$port
AllowedIPs = 0.0.0.0/0, ::0/0
PersistentKeepalive = 25
EOF
}
#安装wireguard
wg_install()
{
    curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
    yum -y install epel-release
    yum -y install wireguard-dkms wireguard-tools qrencode
    mkdir -p /etc/wireguard
    mkdir -p /etc/wireguard/client /etc/wireguard/c_privatekey /etc/wireguard/c_publickey
    cd /etc/wireguard
    wg genkey | tee sprivatekey | wg pubkey > spublickey
    wg genkey | tee cprivatekey | wg pubkey > cpublickey
    sPRIVATEkey=`cat sprivatekey`
    sPUBLICkey=`cat spublickey`
    cPRIVATEkey=`cat cprivatekey`
    cPUBLICkey=`cat cpublickey`
    serverip=`ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | awk -F"/" '{print $1}'`
    port=$(rand 10000 60000)
    echo $serverip:$port > /tmp/ports.txt
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.conf
    sysctl -p
    network=`ip addr | grep BROADCAST | awk -F: '{print $2}'`
    checkfirewall
    cat > /etc/wireguard/wg0.conf <<-EOF
[Interface]
PrivateKey = $sPRIVATEkey
Address = 10.0.0.1/24 
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o${network} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o${network} -j MASQUERADE
ListenPort = $port
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $cPUBLICkey
AllowedIPs = 10.0.0.2/32
EOF
    chmod 755 -R /etc/wireguard
    build_config
    wg-quick up wg0
    systemctl enable wg-quick@wg0
    echo -e "\033[31mPC请下载/etc/wireguard/client/default.conf\033[0m"
}
#添加用户
add_user()
{
	read -p "请输入ip(只需要输入最后ip即可)：" ip
    if [ -e /etc/wireguard/client/c_wg${ip}.conf ]; then
        echo "输入的IP已存在，请重新输入！！！"
        exit
        if [ ${ip} = "" ]; then
            echo "IP不能为空"
            exit
         fi
    fi
	iplist=10.0.0.${ip}
	cd /etc/wireguard
	wg genkey | tee c_privatekey/cprivatekey${ip} | wg pubkey > c_publickey/cpublickey${ip}
	wg set wg0 peer $(cat c_publickey/cpublickey${ip}) allowed-ips ${iplist}/32
	wg-quick save wg0
	cat > /etc/wireguard/client/c_wg${ip}.conf <<-EOF
[Interface]
PrivateKey = `cat c_privatekey/cprivatekey${ip}`
Address = ${iplist}/24 
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = `cat spublickey`
Endpoint = `cat /tmp/ports.txt`
AllowedIPs = 0.0.0.0/0, ::0/0
PersistentKeepalive = 25
EOF
}
#删除用户
del_user()
{	
    echo -e "\033[31m只需要输入文件结尾数字即可\033[0m"
    list=`ls /etc/wireguard/c_publickey`
    echo $list
    echo -ne "\033[33m请选择用户进行删除：\033[0m"
    read deluser
    wg set wg0 peer $(cat /etc/wireguard/c_publickey/cpublickey${deluser}) remove
    wg-quick save wg0
    cd /etc/wireguard/c_publickey && rm -rf cpublickey${deluser}
    cd /etc/wireguard/c_privatekey && rm -rf cprivatekey${deluser}
    cd /etc/wireguard/client && rm -rf c_wg${deluser}.conf

}
#生成二维码
build_qrencode()
{
    echo -e "\033[31m暂时只提供默认配置文件生成\033[0m"
	content=`cat /etc/wireguard/client/default.conf`
    echo "${content}" | qrencode -o - -t UTF8
}
#开始菜单
start_menu(){
    clear
    echo "========================="
    echo
    echo " 本脚本只适用于CentOS7"
    echo
    echo "========================="
    echo
    echo "1. 升级系统内核"
    echo "2. 安装WireGuard"
    echo "3. 添加用户"
    echo "4. 删除用户"
    echo "5. 生成二维码"
    echo "6. 升级WireGuard"
    echo "q. 退出脚本"
    echo
    read -p "请输入选项：" num
    case "$num" in
            1)
                update_kernel
            ;;
            2)
                wg_install                
            ;;
            3)
                add_user
            ;;
            4)
                del_user
            ;;
            5)
                build_qrencode
            ;;
            6)
                wg_update
            ;;
            [qQ])
                exit 1
            ;;
            *)
                clear
                echo "请输入正确数字"
                sleep 5s
                start_menu
            ;;
    esac
}
start_menu
checkOS