#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
SCRIPT_PATH="$(readlink -f "$0")"

# 1. 初始化安装与环境
install_all() {
    echo -e "${YELLOW}正在安装依赖环境 (jq, curl, xray, warp)...${NC}"
    apt-get update && apt-get install -y curl gpg lsb-release wget jq
    
    # 安装 WARP
    if ! command -v warp-cli &> /dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    fi

    systemctl enable --now warp-svc
    sleep 2
    warp-cli --accept-tos registration new 2>/dev/null
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect

    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 初始化配置文件
    init_config
    # 设置全局命令
    set_global_command
}

# 2. 初始化 Xray 配置文件
init_config() {
    echo -e "${YELLOW}正在初始化 Xray 配置文件...${NC}"
    mkdir -p /usr/local/etc/xray
    cat > "$CONFIG_PATH" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": 1080,
    "protocol": "socks",
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
    "settings": { "auth": "noauth", "udp": true }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "tag": "warp_proxy", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      { "type": "field", "domain": ["geosite:google", "geosite:openai"], "outboundTag": "warp_proxy" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    systemctl restart xray
}

# 3. 域名管理功能
manage_domains() {
    while true; do
        current_domains=$(jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy") | .domain | join(", ")' "$CONFIG_PATH")
        echo -e "\n${BLUE}--- 域名分流管理 ---${NC}"
        echo -e "${YELLOW}当前走 WARP 的域名:${NC} ${GREEN}$current_domains${NC}"
        echo -e "1. 添加域名 (如 geosite:netflix 或 my.checkip.com)"
        echo -e "2. 删除域名"
        echo -e "0. 返回主菜单"
        read -p "请选择: " dom_opt

        case $dom_opt in
            1)
                read -p "请输入要添加的域名: " new_dom
                # 使用 jq 添加到数组并去重
                jq --arg nd "$new_dom" '.routing.rules[] |= if .outboundTag == "warp_proxy" then .domain = (.domain + [$nd] | unique) else . end' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                systemctl restart xray && echo -e "${GREEN}添加成功并已重启服务。${NC}"
                ;;
            2)
                read -p "请输入要删除的域名: " del_dom
                jq --arg dd "$del_dom" '.routing.rules[] |= if .outboundTag == "warp_proxy" then .domain = (.domain - [$dd]) else . end' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                systemctl restart xray && echo -e "${GREEN}删除成功并已重启服务。${NC}"
                ;;
            0) break ;;
        esac
    done
}

# 4. 设置全局命令 warp
set_global_command() {
    if [ ! -f /usr/local/bin/warp ]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/warp
        chmod +x /usr/local/bin/warp
        echo -e "${GREEN}全局命令 'warp' 设置成功！以后只需输入 warp 即可。${NC}"
    fi
}

# 5. IP 筛选逻辑
optimize_warp_ip() {
    echo -e "${BLUE}开始筛选非送中 IP...${NC}"
    for i in {1..15}; do
        echo -ne "${YELLOW}尝试第 $i 次更换 IP... ${NC}"
        local check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        if [[ -z "$check" ]]; then
            echo -e "\n${GREEN}✅ 成功！当前 IP 未送中。${NC}"
            return 0
        fi
        warp-cli registration rotate > /dev/null 2>&1
        sleep 3
    done
}

# 主菜单
show_menu() {
    echo -e "\n${BLUE}==============================${NC}"
    echo -e "      WARP & Xray 管理脚本"
    echo -e "${BLUE}==============================${NC}"
    echo -e "1. 完整安装环境 (首次使用)"
    echo -e "2. 域名分流管理 (添加/删除)"
    echo -e "3. 筛选非送中 IP (Rotate IP)"
    echo -e "4. 重启 Xray 服务"
    echo -e "0. 退出"
    read -p "请输入选项: " choice

    case $choice in
        1) install_all ;;
        2) manage_domains ;;
        3) optimize_warp_ip ;;
        4) systemctl restart xray && echo "已重启" ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

show_menu
