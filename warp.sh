#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
SCRIPT_PATH="$(readlink -f "$0")"

# 1. 初始化安装与环境
install_all() {
    echo -e "${YELLOW}正在同步系统时间与更新基础环境...${NC}"
    apt-get update
    apt-get install -y curl gpg lsb-release wget jq ca-certificates
    update-ca-certificates --force

    # 安装 WARP
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${YELLOW}正在安装 Cloudflare WARP...${NC}"
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        OS_CODENAME=$(lsb_release -cs)
        [[ "$OS_CODENAME" == "trixie" || "$OS_CODENAME" == "sid" ]] && OS_CODENAME="bookworm"
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $OS_CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    fi

    echo -e "${YELLOW}正在初始化 WARP 配置...${NC}"
    systemctl enable --now warp-svc
    sleep 3
    
    # 核心修复：锁定 WireGuard 协议并设置代理
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos tunnel protocol set wireguard
    warp-cli --accept-tos connect
    
    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        echo -e "${YELLOW}正在安装 Xray...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    init_config
    set_global_command
    echo -e "${GREEN}安装与配置完成！${NC}"
    check_status
}

# 2. 初始化 Xray 配置文件 (优化分流逻辑)
init_config() {
    echo -e "${YELLOW}正在配置 Xray 分流规则...${NC}"
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
    { 
      "tag": "warp_proxy", 
      "protocol": "socks", 
      "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } 
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:google",
          "geosite:youtube",
          "geosite:openai",
          "geosite:netflix",
          "geosite:disney"
        ],
        "outboundTag": "warp_proxy"
      },
      {
        "type": "field",
        "ip": ["geoip:google", "geoip:netflix"],
        "outboundTag": "warp_proxy"
      },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    systemctl restart xray
}

# 3. 域名管理
manage_domains() {
    while true; do
        current_domains=$(jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy" and .domain != null) | .domain | join(", ")' "$CONFIG_PATH")
        echo -e "\n${BLUE}--- 域名分流管理 ---${NC}"
        echo -e "${YELLOW}当前走 WARP 的域名:${NC} ${GREEN}${current_domains:-无}${NC}"
        echo -e "1. 添加域名 (如 geosite:twitter 或 telegram.org)"
        echo -e "2. 删除域名"
        echo -e "0. 返回主菜单"
        read -p "请选择: " dom_opt

        case $dom_opt in
            1)
                read -p "请输入要添加的域名: " new_dom
                if [[ -n "$new_dom" ]]; then
                    jq --arg nd "$new_dom" '.routing.rules |= map(if .outboundTag == "warp_proxy" and .domain != null then .domain = (.domain + [$nd] | unique) else . end)' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                    systemctl restart xray && echo -e "${GREEN}添加成功！${NC}"
                fi
                ;;
            2)
                read -p "请输入要删除的域名: " del_dom
                if [[ -n "$del_dom" ]]; then
                    jq --arg dd "$del_dom" '.routing.rules |= map(if .outboundTag == "warp_proxy" and .domain != null then .domain = (.domain - [$dd]) else . end)' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                    systemctl restart xray && echo -e "${GREEN}删除成功！${NC}"
                fi
                ;;
            0) break ;;
        esac
    done
}

# 4. 设置全局快捷命令
set_global_command() {
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" /usr/local/bin/warp
    echo -e "${GREEN}快捷命令 'warp' 已就绪。${NC}"
}

# 5. 优选非送中 IP (Rotate IP)
optimize_warp_ip() {
    echo -e "${BLUE}开始筛选非送中 IP (检查 Google 重定向)...${NC}"
    for i in {1..10}; do
        echo -ne "${YELLOW}尝试第 $i 次更换 IP... ${NC}"
        # 强制旋转身份
        warp-cli --accept-tos registration rotate > /dev/null 2>&1
        sleep 4
        
        # 检查是否重定向到 google.com.hk (送中标志)
        local check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk")
        
        if [[ -z "$check" ]]; then
            echo -e "\n${GREEN}✅ 成功！当前 IP 未发现送中迹象。${NC}"
            echo -ne "${PURPLE}当前出口 IP 归属: ${NC}"
            curl -x socks5h://127.0.0.1:40000 -s https://gs.z6.net.cn/ip.php || echo "无法获取"
            return 0
        else
            echo -e "${RED}失败 (检测到 HK 重定向)${NC}"
        fi
    done
    echo -e "${RED}已尝试 10 次，未能获取理想 IP，请稍后再试。${NC}"
}

# 6. 查看状态
check_status() {
    echo -e "\n${BLUE}--- 当前状态检查 ---${NC}"
    warp_s=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    echo -e "WARP 状态: ${GREEN}${warp_s:-未知}${NC}"
    xray_s=$(systemctl is-active xray)
    echo -e "Xray 状态: ${GREEN}${xray_s}${NC}"
    echo -e "WARP 代理端口: ${BLUE}40000${NC}"
    echo -e "Xray 监听端口: ${BLUE}1080${NC}"
    echo -e "--------------------"
}

# 主菜单
show_menu() {
    echo -e "\n${BLUE}====================================${NC}"
    echo -e "      WARP & Xray 增强管理脚本"
    echo -e "${BLUE}====================================${NC}"
    echo -e "1. 完整安装/修复环境 (包含证书修复)"
    echo -e "2. 域名分流管理 (Google/Netflix等)"
    echo -e "3. 刷新 WARP IP (解决 Google 送中)"
    echo -e "4. 重启 Xray 服务"
    echo -e "5. 查看当前连接状态"
    echo -e "0. 退出"
    echo -e "${BLUE}====================================${NC}"
    read -p "请输入选项: " choice

    case $choice in
        1) install_all ;;
        2) manage_domains ;;
        3) optimize_warp_ip ;;
        4) systemctl restart xray && echo -e "${GREEN}Xray 已重启${NC}" ;;
        5) check_status ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# 脚本入口
if [[ $# -gt 0 ]]; then
    case $1 in
        install) install_all ;;
        rotate) optimize_warp_ip ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
