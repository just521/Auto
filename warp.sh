#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"

# 1. 安装环境
install_env() {
    echo -e "${YELLOW}正在安装依赖环境...${NC}"
    apt-get update && apt-get install -y curl gpg lsb-release wget
    
    if ! command -v warp-cli &> /dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(ls_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    fi

    systemctl enable --now warp-svc
    sleep 2
    warp-cli --accept-tos registration new 2>/dev/null
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect

    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
}

# 2. 配置 Xray (修复了原脚本最致命的 EOF 闭合问题)
setup_xray() {
    echo -e "${YELLOW}配置 Xray 路由分流...${NC}"
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
    "rules": [
      { "type": "field", "domain": ["geosite:google", "geosite:netflix", "geosite:openai"], "outboundTag": "warp_proxy" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    systemctl restart xray
    echo -e "${GREEN}Xray 配置已更新并重启。${NC}"
}

# 3. 筛选非送中 IP (修复了循环和判断逻辑)
optimize_warp_ip() {
    echo -e "${BLUE}开始筛选非送中 IP...${NC}"
    local count=1
    while [ $count -le 20 ]; do
        echo -ne "${YELLOW}正在进行第 $count 次尝试... ${NC}"
        # 检测 Google 搜索是否重定向到 .hk 或 .cn
        local check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        
        if [[ -z "$check" ]]; then
            echo -e "\n${GREEN}✅ 成功！当前 IP 未送中。${NC}"
            return 0
        else
            echo -e "${RED}失败 (送中 IP)，正在更换节点...${NC}"
            warp-cli registration rotate > /dev/null 2>&1
            sleep 3
        fi
        count=$((count + 1))
    done
    echo -e "${RED}已达最大尝试次数，请稍后再试。${NC}"
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}==============================${NC}"
    echo -e "   WARP 自动化管理脚本"
    echo -e "${BLUE}==============================${NC}"
    echo -e "1. 完整安装 (WARP + Xray + 分流)"
    echo -e "2. 仅执行 IP 筛选 (解决 Google 送中)"
    echo -e "3. 查看当前 WARP 状态"
    echo -e "0. 退出"
    echo -e "${BLUE}==============================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) install_env && setup_xray && optimize_warp_ip ;;
        2) optimize_warp_ip ;;
        3) warp-cli status ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; show_menu ;;
    esac
}

# 运行菜单
show_menu
