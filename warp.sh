cat > /usr/local/bin/warp << 'EOF'
#!/bin/bash

# 定义颜色
CYAN="\033[36m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
GRAY="\033[90m"
PLAIN="\033[0m"

# Xray 配置文件路径
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_BAK="/usr/local/etc/xray/config.json.bak"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本！${PLAIN}"
  exit 1
fi

# ================= 辅助函数 =================

# 备份配置
backup_conf() {
    cp "$XRAY_CONF" "$XRAY_BAK"
}

# 重启 Xray
restart_xray() {
    systemctl restart xray
    echo -e "${GREEN}Xray 服务已重启。${PLAIN}"
}

# 获取 Socks5 状态
get_sock_status() {
    if netstat -tlnp | grep -q ":40000"; then
        echo -e "${GREEN}运行中 (Port 40000)${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

# 获取 Xray 状态
get_xray_status() {
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

# 获取 WARP IP
get_warp_ip() {
    local ip=$(curl -s --connect-timeout 3 -x socks5h://127.0.0.1:40000 https://api.ipify.org)
    if [ -n "$ip" ]; then
        echo -e "${GREEN}${ip}${PLAIN}"
    else
        echo -e "${RED}获取失败 / 未连接${PLAIN}"
    fi
}

# 获取本机主 IP
get_main_ip() {
    local ip=$(curl -s --connect-timeout 3 https://api.ipify.org)
    echo -e "${CYAN}${ip}${PLAIN}"
}

# 根据 tag 获取 Xray 路由规则中的域名
_get_domains_by_tag() {
    local tag=$1
    if [ ! -f "$XRAY_CONF" ]; then
        echo "未找到配置文件"
        return
    fi
    local domains=$(jq -r ".routing.rules[]? | select(.outboundTag == \"$tag\") | .domain[]?" "$XRAY_CONF" | paste -sd ", " -)
    if [ -z "$domains" ]; then
        echo "无"
    else
        echo "$domains"
    fi
}

# ================= 核心功能 =================

# 1. 安装 WARP
install_warp() {
    echo -e "${CYAN}开始安装 Cloudflare WARP...${PLAIN}"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update && apt-get install cloudflare-warp -y
    
    warp-cli registration new
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect
    systemctl enable warp-svc
    
    echo -e "${CYAN}配置 Xray 出站规则...${PLAIN}"
    backup_conf
    # 添加 warp_proxy 出站
    jq 'if .outbounds | map(.tag == "warp_proxy") | any then . else .outbounds += [{"protocol": "socks","tag": "warp_proxy","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}] end' "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"
    
    restart_xray
    echo -e "${GREEN}WARP 安装并配置完成！${PLAIN}"
    sleep 2
}

# 2. 卸载 WARP
uninstall_warp() {
    echo -e "${CYAN}正在卸载 WARP 并清理分流规则...${PLAIN}"
    warp-cli disconnect
    apt-get remove --purge cloudflare-warp -y
    
    backup_conf
    # 移除出站和路由规则
    jq 'del(.outbounds[] | select(.tag == "warp_proxy")) | del(.routing.rules[]? | select(.outboundTag == "warp_proxy"))' "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"
    
    restart_xray
    echo -e "${GREEN}WARP 已卸载，Xray 配置已清理。${PLAIN}"
    sleep 2
}

# 3. 更换出口 IP
change_ip() {
    echo -e "${CYAN}正在重新连接 WARP 以刷新 IP...${PLAIN}"
    warp-cli disconnect
    sleep 2
    warp-cli connect
    sleep 3
    echo -e "${GREEN}当前新 IP: $(get_warp_ip)${PLAIN}"
    sleep 2
}

# 4/5. 修改分流规则 (添加/删除)
modify_routing() {
    local target_tag=$1
    echo -e "${CYAN}请输入域名或 geosite (例如: geosite:netflix, google.com)${PLAIN}"
    read -p "目标域名: " domain
    
    if [ -z "$domain" ]; then
        echo -e "${RED}输入为空，取消操作。${PLAIN}"
        sleep 1
        return
    fi

    echo -e "请选择操作: [1] 添加  [2] 删除"
    read -p "选择: " op_choice

    backup_conf

    # 初始化 routing 和 rules (如果不存在)
    jq '.routing //= {"domainStrategy": "AsIs", "rules": []}' "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"

    # 检查规则对象是否存在，不存在则创建
    rule_exists=$(jq "(.routing.rules[]? | select(.outboundTag == \"$target_tag\")) != null" "$XRAY_CONF")
    
    if [ "$rule_exists" != "true" ]; then
         jq ".routing.rules += [{\"type\": \"field\", \"outboundTag\": \"$target_tag\", \"domain\": []}]" "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"
    fi

    if [ "$op_choice" == "1" ]; then
        # 添加域名并去重
        jq "(.routing.rules[] | select(.outboundTag == \"$target_tag\") | .domain) |= (. + [\"$domain\"] | unique)" "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"
        echo -e "${GREEN}已添加 ${domain} 到 ${target_tag}${PLAIN}"
    elif [ "$op_choice" == "2" ]; then
        # 删除域名
        jq "(.routing.rules[] | select(.outboundTag == \"$target_tag\") | .domain) |= map(select(. != \"$domain\"))" "$XRAY_CONF" > tmp.json && mv tmp.json "$XRAY_CONF"
        echo -e "${GREEN}已从 ${target_tag} 移除 ${domain}${PLAIN}"
    fi

    restart_xray
    sleep 2
}

# ================= 菜单界面 =================
while true; do
    clear
    STATUS_SOCK=$(get_sock_status)
    STATUS_XRAY=$(get_xray_status)

    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "${CYAN}            WARP 分流管理面板 (Xray Warp)          ${PLAIN}"
    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e " Warp 服务 : ${STATUS_SOCK}"
    echo -e " Xray 接口 : ${STATUS_XRAY}"
    echo -e " Warp IP   : $(get_warp_ip)"
    echo -e " 默认出口  : $(get_main_ip)"
    echo -e " 直连域名  : $(_get_domains_by_tag 'direct')"
    echo -e " WARP 域名 : $(_get_domains_by_tag 'warp_proxy')"
    echo -e "---------------------------------------------------"
    echo -e " 1. 安装 WARP      ${GRAY}(自动配置 Socks5 端口 40000)${PLAIN}"
    echo -e " 2. 卸载 WARP      ${GRAY}(清理分流规则)${PLAIN}"
    echo -e " 3. 更换出口 IP    ${GRAY}(刷取新 IP )${PLAIN}"
    echo -e " 4. 添加/删除 直连分流 ${GRAY}(本地代理)${PLAIN}"
    echo -e " 5. 添加/删除 WARP分流 ${GRAY}(WARP 代理)${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e " 0. 退出 (Exit)"
    echo ""
    read -p "请输入选项 [0-5]: " choice

    case $choice in
        1) install_warp ;;
        2) uninstall_warp ;;
        3) change_ip ;;
        4) modify_routing "direct" ;;
        5) modify_routing "warp_proxy" ;;
        0) echo -e "${GREEN}已退出。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}输入错误，请重新输入。${PLAIN}"; sleep 1 ;;
    esac
done
EOF

chmod +x /usr/local/bin/warp
