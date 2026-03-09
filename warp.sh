#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
# 获取脚本的绝对路径，确保软链接有效
SCRIPT_PATH="$(readlink -f "$0")"

# 1. 初始化安装与环境
install_all() {
    echo -e "${YELLOW}正在安装依赖环境 (jq, curl, xray, warp)...${NC}"
    apt-get update && apt-get install -y curl gpg lsb-release wget jq
    
    # 安装 WARP
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${YELLOW}正在安装 Cloudflare WARP...${NC}"
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        # 自动识别代号，如果是 trixie 则回退到 bookworm 保证兼容性
        OS_CODENAME=$(lsb_release -cs)
        [[ "$OS_CODENAME" == "trixie" ]] && OS_CODENAME="bookworm"
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $OS_CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    fi

    systemctl enable --now warp-svc
    sleep 2
    warp-cli --accept-tos registration new 2>/dev/null
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect
    
    # 检查 WARP 状态
    warp-cli status

    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        echo -e "${YELLOW}正在安装 Xray...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 初始化配置文件
    init_config
    # 强制设置全局命令
    set_global_command
    echo -e "${GREEN}安装完成！${NC}"
}

# 2. 初始化 Xray 配置文件 (分流逻辑)
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
      { "type": "field", "domain": ["geosite:google", "geosite:openai", "geosite:netflix", "geosite:disney"], "outboundTag": "warp_proxy" },
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
        # 提取当前走 WARP 的域名列表
        current_domains=$(jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy") | .domain | join(", ")' "$CONFIG_PATH")
        echo -e "\n${BLUE}--- 域名分流管理 ---${NC}"
        echo -e "${YELLOW}当前走 WARP 的域名:${NC} ${GREEN}$current_domains${NC}"
        echo -e "1. 添加域名 (例如 geosite:netflix 或 my.checkip.com)"
        echo -e "2. 删除域名"
        echo -e "0. 返回主菜单"
        read -p "请选择: " dom_opt

        case $dom_opt in
            1)
                read -p "请输入要添加的域名: " new_dom
                if [[ -n "$new_dom" ]]; then
                    jq --arg nd "$new_dom" '.routing.rules[] |= if .outboundTag == "warp_proxy" then .domain = (.domain + [$nd] | unique) else . end' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                    systemctl restart xray && echo -e "${GREEN}添加成功，Xray 已重启。${NC}"
                fi
                ;;
            2)
                read -p "请输入要删除的域名: " del_dom
                if [[ -n "$del_dom" ]]; then
                    jq --arg dd "$del_dom" '.routing.rules[] |= if .outboundTag == "warp_proxy" then .domain = (.domain - [$dd]) else . end' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                    systemctl restart xray && echo -e "${GREEN}删除成功，Xray 已重启。${NC}"
                fi
                ;;
            0) break ;;
        esac
    done
}

# 4. 强制设置全局命令 warp (修复 Permission Denied)
set_global_command() {
    # 确保脚本自身有执行权限
    chmod +x "$SCRIPT_PATH"
    # 强制创建软链接
    ln -sf "$SCRIPT_PATH" /usr/local/bin/warp
    # 确保软链接有执行权限
    chmod +x /usr/local/bin/warp
    echo -e "${GREEN}全局命令 'warp' 设置成功！以后只需输入 warp 即可进入菜单。${NC}"
}

# 5. IP 筛选逻辑 (Rotate IP)
optimize_warp_ip() {
    echo -e "${BLUE}开始筛选非送中 IP (检查 Google 搜索重定向)...${NC}"
    for i in {1..15}; do
        echo -ne "${YELLOW}尝试第 $i 次更换 IP... ${NC}"
        # 通过 WARP 代理检查 Google 搜索
        local check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        if [[ -z "$check" ]]; then
            echo -e "\n${GREEN}✅ 成功！当前 IP 未送中。${NC}"
            # 获取当前 IP 归属地显示一下
            curl -x socks5h://127.0.0.1:40000 -s https://gs.z6.net.cn/ip.php
            return 0
        fi
        warp-cli registration rotate > /dev/null 2>&1
        sleep 3
    done
    echo -e "${RED}筛选超时，请稍后再试。${NC}"
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}==============================${NC}"
    echo -e "      WARP & Xray 管理脚本"
    echo -e "${BLUE}==============================${NC}"
    echo -e "1. 完整安装环境 (首次使用/修复)"
    echo -e "2. 域名分流管理 (添加/删除)"
    echo -e "3. 优选 IP (Rotate IP)"
    echo -e "4. 重启 Xray 服务"
    echo -e "5. 查看 WARP 状态"
    echo -e "0. 退出"
    echo -e "${BLUE}==============================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) install_all ;;
        2) manage_domains ;;
        3) optimize_warp_ip ;;
        4) systemctl restart xray && echo -e "${GREEN}Xray 已重启${NC}" ;;
        5) warp-cli status ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# 首次运行自动设置一次快捷命令
set_global_command > /dev/null 2>&1

# 进入菜单
show_menu
