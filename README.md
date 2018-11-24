# wireguard
#### For CentOS7
## 使用方法
yum -y install wget && wget -O wg_install.sh https://git.io/fpRsh && bash wg_install.sh <br>
本脚本必须先升级内核才可进行一步安装。<br>
注释：由于脚本升级了内核请勿在生产环境安装！！！<br>
脚本使用了firewall来进行转发，没有采用iptables。

# 脚本参考鸣谢
[@yobabyshark](https://github.com/yobabyshark/wireguard)


