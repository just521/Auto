#!/usr/bin/env bash

export LANG=zh_CN.UTF-8

WARP_PORT=40000
INSTALL_PATH="/usr/local/bin/warp"
DOMAIN_FILE="/usr/local/etc/xray/warp_domains.txt"

GREEN="\033[32m"
RED="\033[31m"
PLAIN="\033[0m"

install_deps(){
for p in curl wget jq bc; do
if ! command -v $p >/dev/null 2>&1; then
if command -v apt >/dev/null; then
apt update -y && apt install -y $p
elif command -v yum >/dev/null; then
yum install -y $p
elif command -v dnf >/dev/null; then
dnf install -y $p
fi
fi
done
}

install_cmd(){
if [ ! -f "$INSTALL_PATH" ]; then
cp "$0" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
fi
}

check_warp(){
(echo >/dev/tcp/127.0.0.1/$WARP_PORT) >/dev/null 2>&1
}

check_xray(){
systemctl is-active xray >/dev/null 2>&1
}

ip_country(){
ip=$1
c=$(curl -s ipinfo.io/$ip/country)
echo "$ip ($c)"
}

warp_ip(){
ip=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://ipinfo.io/ip 2>/dev/null)
[ -n "$ip" ] && ip_country "$ip"
}

default_ip(){
ip=$(curl -s ipinfo.io/ip)
ip_country "$ip"
}

ai_status(){

openai=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://chat.openai.com >/dev/null && echo "✓" || echo "✗")
claude=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://claude.ai >/dev/null && echo "✓" || echo "✗")
gemini=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://gemini.google.com >/dev/null && echo "✓" || echo "✗")
genmini=$gemini

echo "AI 状态    : OpenAI $openai  Claude $claude  Gemini $gemini genmini   $genmini"

}

google_region(){

google_country=$(curl -s https://ipinfo.io/country)

if [ "$google_country" = "CN" ]; then
google="中国"
else
google="$google_country"
fi

yt=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://www.youtube.com | grep -o 'countryCode":"[A-Z]*' | head -n1 | cut -d'"' -f3)

[ -z "$yt" ] && yt="Unknown"

echo "Google    ：Google（$google）YouTube（$yt）"

}

install_warp(){
wget -qN https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh
bash menu.sh b
}

uninstall_warp(){
wget -qN https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh
bash menu.sh u
}

start_warp(){
warp on 2>/dev/null
}

stop_warp(){
warp off 2>/dev/null
}

domain_manage(){

mkdir -p /usr/local/etc/xray
touch "$DOMAIN_FILE"

echo
echo "已添加的分流域名:"
cat "$DOMAIN_FILE" 2>/dev/null

echo
read -p "输入域名: " d

if grep -q "^$d$" "$DOMAIN_FILE" 2>/dev/null; then
sed -i "/^$d$/d" "$DOMAIN_FILE"
echo "已删除: $d"
else
echo "$d" >> "$DOMAIN_FILE"
echo "已添加: $d"
fi

}

show_domains(){
if [ -f "$DOMAIN_FILE" ]; then
tr '\n' ' ' < "$DOMAIN_FILE"
else
echo "无"
fi
}

show_status(){

clear

if check_warp; then
warp_status="${GREEN}● 运行中${PLAIN}"
else
warp_status="${RED}● 未运行${PLAIN}"
fi

if check_xray; then
xray_status="${GREEN}● 运行中${PLAIN}"
else
xray_status="${RED}● 未运行${PLAIN}"
fi

warpip=$(warp_ip)
defaultip=$(default_ip)
domains=$(show_domains)

echo "==================================================="
echo "           Xray WARP 分流管理 #包含系统级命令warp 终端输入即可进入交互界面"
echo "==================================================="
echo -e "WARP 状态: $warp_status"
echo -e "XRAY 状态: $xray_status"
echo "WARP IP  : $warpip"
echo "默认出口 : $defaultip"
echo "分流域名 : $domains"
ai_status
google_region
echo "---------------------------------------------------"
echo "1 安装/重装 WARP #以vps本机IP地址自动优选warp IP"
echo "2 卸载 WARP"
echo "3 自定义分流域名 #没有的域名则添加 有的即删除 并显示已添加的domain"
echo "4 启动/停止 WARP"
echo "---------------------------------------------------"
echo "0 退出"
echo "==================================================="

}

menu(){

while true
do

show_status

read -p "请选择: " num

case "$num" in

1)
install_warp
;;

2)
uninstall_warp
;;

3)
domain_manage
;;

4)

if check_warp; then
stop_warp
else
start_warp
fi

;;

0)
exit
;;

esac

read -n1 -r -p "按任意键继续..."

done

}

install_deps
install_cmd
menu
