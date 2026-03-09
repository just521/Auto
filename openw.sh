#!/bin/bash

# ─────────────────────────────────────────────
# WARP 管理面板
# 默认端口：40000
# ─────────────────────────────────────────────

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

WARP_PORT=40000
DOMAIN_FILE="/usr/local/etc/warp_domains.txt"
SCRIPT_PATH="/usr/local/bin/warp"
UI_MESSAGE=""

# ─────────────────────────────────────────────
# 自动安装 warp 命令
# ─────────────────────────────────────────────
install_command() {

if [[ "$0" != "$SCRIPT_PATH" ]]; then

cp "$0" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

UI_MESSAGE="${GREEN}已安装 warp 系统命令，以后直接输入 warp 即可打开面板${PLAIN}"

fi

}

# ─────────────────────────────────────────────
# root 检查
# ─────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
echo -e "${RED}请使用 root 运行脚本${PLAIN}"
exit 1
fi

# ─────────────────────────────────────────────
# 安装依赖
# ─────────────────────────────────────────────

install_base() {

if ! command -v curl &>/dev/null; then
apt update
apt install -y curl
fi

if ! command -v jq &>/dev/null; then
apt install -y jq
fi

}

# ─────────────────────────────────────────────
# 检测 WARP
# ─────────────────────────────────────────────

check_warp() {

warp-cli status 2>/dev/null | grep -q Connected

}

# ─────────────────────────────────────────────
# 获取本机 IP
# ─────────────────────────────────────────────

get_vps_ip() {

TRACE=$(curl -s https://www.cloudflare.com/cdn-cgi/trace)

VPS_IP=$(echo "$TRACE" | grep ip= | cut -d= -f2)
VPS_LOC=$(echo "$TRACE" | grep loc= | cut -d= -f2)

}

# ─────────────────────────────────────────────
# 获取 WARP IP
# ─────────────────────────────────────────────

get_warp_ip() {

TRACE=$(curl -s --interface warp https://www.cloudflare.com/cdn-cgi/trace)

WARP_IP=$(echo "$TRACE" | grep ip= | cut -d= -f2)
WARP_LOC=$(echo "$TRACE" | grep loc= | cut -d= -f2)

}

# ─────────────────────────────────────────────
# 安装 WARP
# ─────────────────────────────────────────────

install_warp() {

clear
echo
echo -e "${CYAN}正在安装 WARP，请稍候...${PLAIN}"

install_base

curl https://pkg.cloudflareclient.com/install.sh | bash

apt install -y cloudflare-warp

warp-cli register
warp-cli set-mode warp
warp-cli connect

UI_MESSAGE="${GREEN}WARP 安装完成${PLAIN}"

}

# ─────────────────────────────────────────────
# 卸载 WARP
# ─────────────────────────────────────────────

uninstall_warp() {

warp-cli disconnect 2>/dev/null

apt remove -y cloudflare-warp

rm -f "$DOMAIN_FILE"

UI_MESSAGE="${YELLOW}WARP 已卸载${PLAIN}"

}

# ─────────────────────────────────────────────
# 启动 WARP
# ─────────────────────────────────────────────

start_warp() {

warp-cli connect

UI_MESSAGE="${GREEN}WARP 已启动${PLAIN}"

}

# ─────────────────────────────────────────────
# 停止 WARP
# ─────────────────────────────────────────────

stop_warp() {

warp-cli disconnect

UI_MESSAGE="${YELLOW}WARP 已停止${PLAIN}"

}

# ─────────────────────────────────────────────
# 分流规则
# ─────────────────────────────────────────────

edit_rules() {

mkdir -p /usr/local/etc
touch "$DOMAIN_FILE"

echo
echo -e "${CYAN}输入域名 (存在则删除 不存在则添加)${PLAIN}"
read -p "域名: " domain

if grep -qx "$domain" "$DOMAIN_FILE"; then

sed -i "/$domain/d" "$DOMAIN_FILE"
UI_MESSAGE="已删除 $domain"

else

echo "$domain" >> "$DOMAIN_FILE"
UI_MESSAGE="已添加 $domain"

fi

}

# ─────────────────────────────────────────────
# 获取分流列表
# ─────────────────────────────────────────────

get_rules() {

if [ ! -f "$DOMAIN_FILE" ]; then
echo "无"
return
fi

cat "$DOMAIN_FILE" | tr '\n' '|' | sed 's/|$//' | sed 's/|/ | /g'

}

# ─────────────────────────────────────────────
# 面板
# ─────────────────────────────────────────────

show_menu() {

clear

get_vps_ip

if check_warp; then

WARP_STATUS="${GREEN}运行中${PLAIN}"
get_warp_ip

else

WARP_STATUS="${RED}已停止${PLAIN}"
WARP_IP="N/A"
WARP_LOC="-"

fi

if systemctl is-active xray &>/dev/null; then
XRAY_STATUS="${GREEN}运行中${PLAIN}"
else
XRAY_STATUS="${RED}已停止${PLAIN}"
fi

RULES=$(get_rules)

echo "══════════════════════════════"
echo "        WARP 管理面板"
echo "══════════════════════════════"
echo

printf "%-12s : %b\n" "WARP状态" "$WARP_STATUS"
printf "%-12s : %b\n" "XRAY状态" "$XRAY_STATUS"
printf "%-12s : %s  %s\n" "WARP IP" "$WARP_IP" "$WARP_LOC"
printf "%-12s : %s  %s\n" "本机IP" "$VPS_IP" "$VPS_LOC"
printf "%-12s : %s\n" "分流规则" "$RULES"

echo
echo "══════════════════════════════"
echo "1 安装 / 重装 WARP"
echo "2 卸载 WARP"
echo "3 启动 WARP"
echo "4 停止 WARP"
echo "5 编辑分流"
echo "0 退出"
echo "══════════════════════════════"

if [ -n "$UI_MESSAGE" ]; then

echo
echo -e "${YELLOW}提示: $UI_MESSAGE${PLAIN}"
UI_MESSAGE=""

fi

}

# ─────────────────────────────────────────────
# 主循环
# ─────────────────────────────────────────────

install_command

while true
do

show_menu

read -p "请输入选项 [0-5]: " choice

case "$choice" in

1) install_warp ;;
2) uninstall_warp ;;
3) start_warp ;;
4) stop_warp ;;
5) edit_rules ;;
0) exit ;;

*) UI_MESSAGE="输入错误" ;;

esac

done
