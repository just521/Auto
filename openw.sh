#!/usr/bin/env bash

export LANG=zh_CN.UTF-8

WARP_PORT=40000
INSTALL_PATH="/usr/local/bin/warp"
DOMAIN_FILE="/usr/local/etc/xray/warp_domains.txt"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

# -------------------------------
# 安装依赖
# -------------------------------

install_deps(){

for pkg in jq curl wget; do

if ! command -v $pkg >/dev/null 2>&1; then

echo -e "${CYAN}安装依赖 $pkg${PLAIN}"

if command -v apt >/dev/null; then
apt update -y
apt install -y $pkg
elif command -v yum >/dev/null; then
yum install -y $pkg
elif command -v dnf >/dev/null; then
dnf install -y $pkg
fi

fi
done

}

# -------------------------------
# 安装 warp 命令
# -------------------------------

install_cmd(){

if [ ! -f "$INSTALL_PATH" ]; then

cp "$0" $INSTALL_PATH
chmod +x $INSTALL_PATH

echo
echo -e "${GREEN}系统命令 warp 已安装${PLAIN}"
echo "以后直接输入 warp 即可打开面板"

fi

}

# -------------------------------
# WARP 检测
# -------------------------------

check_warp(){

(echo >/dev/tcp/127.0.0.1/$WARP_PORT) >/dev/null 2>&1

}

# -------------------------------
# 安装 WARP
# -------------------------------

install_warp(){

echo
echo -e "${CYAN}安装 WARP Socks5 模式...${PLAIN}"

wget -qN https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh

bash menu.sh s5

}

# -------------------------------
# 卸载 WARP
# -------------------------------

uninstall_warp(){

wget -qN https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh

bash menu.sh u

}

# -------------------------------
# WARP 开关
# -------------------------------

start_warp(){

warp on 2>/dev/null

}

stop_warp(){

warp off 2>/dev/null

}

# -------------------------------
# WARP IP
# -------------------------------

warp_ip(){

echo
curl -s --socks5 127.0.0.1:$WARP_PORT https://ipinfo.io
echo

}

# -------------------------------
# Netflix检测
# -------------------------------

check_netflix(){

echo
echo "检测 Netflix..."

res=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://www.netflix.com/title/81215567)

if echo "$res" | grep -q "Not Available"; then
echo -e "${RED}Netflix 不支持${PLAIN}"
else
echo -e "${GREEN}Netflix 已解锁${PLAIN}"
fi

}

# -------------------------------
# AI检测
# -------------------------------

check_ai(){

echo

echo "OpenAI..."
curl -s --socks5 127.0.0.1:$WARP_PORT https://chat.openai.com >/dev/null && echo -e "${GREEN}可用${PLAIN}" || echo -e "${RED}不可用${PLAIN}"

echo "Claude..."
curl -s --socks5 127.0.0.1:$WARP_PORT https://claude.ai >/dev/null && echo -e "${GREEN}可用${PLAIN}" || echo -e "${RED}不可用${PLAIN}"

echo "Grok..."
curl -s --socks5 127.0.0.1:$WARP_PORT https://x.ai >/dev/null && echo -e "${GREEN}可用${PLAIN}" || echo -e "${RED}不可用${PLAIN}"

echo "Gemini..."
curl -s --socks5 127.0.0.1:$WARP_PORT https://gemini.google.com >/dev/null && echo -e "${GREEN}可用${PLAIN}" || echo -e "${RED}不可用${PLAIN}"

}

# -------------------------------
# 域名分流
# -------------------------------

domain_manage(){

mkdir -p /usr/local/etc/xray

touch $DOMAIN_FILE

echo
echo "当前域名:"
cat $DOMAIN_FILE

echo
read -p "输入域名添加 (回车删除): " d

if [ -z "$d" ]; then

read -p "输入删除域名: " dd

sed -i "/$dd/d" $DOMAIN_FILE

else

echo "$d" >> $DOMAIN_FILE

fi

}

# -------------------------------
# 状态
# -------------------------------

show_status(){

clear

if check_warp; then
status="${GREEN}● 运行中${PLAIN}"
else
status="${RED}● 未运行${PLAIN}"
fi

ip=$(curl -s https://ipinfo.io/ip)

warpip=$(curl -s --socks5 127.0.0.1:$WARP_PORT https://ipinfo.io/ip 2>/dev/null)

domains=$(cat $DOMAIN_FILE 2>/dev/null | wc -l)

echo "==================================================="
echo "           Xray WARP 分流管理"
echo "==================================================="
echo -e "WARP 状态: $status"
echo "WARP IP  : $warpip"
echo "默认出口 : $ip"
echo "分流域名 : $domains 条"
echo "---------------------------------------------------"
echo "1 安装/重装 WARP"
echo "2 卸载 WARP"
echo "3 自定义分流域名"
echo "4 启动/停止 WARP"
echo "5 WARP IP检测"
echo "6 Netflix检测"
echo "7 AI检测(OpenAI Claude Grok Gemini)"
echo "---------------------------------------------------"
echo "0 退出"
echo "==================================================="

}

# -------------------------------
# 菜单
# -------------------------------

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

5)
warp_ip
;;

6)
check_netflix
;;

7)
check_ai
;;

0)
exit
;;

esac

read -n1 -r -p "按任意键继续..."

done

}

# -------------------------------
# 主入口
# -------------------------------

install_deps
install_cmd
menu
