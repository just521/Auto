#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
SCRIPT_PATH="$(readlink -f "$0")"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}" && exit 1

# --- 核心功能函数 ---

# 1. 安装与修复环境
install_all() {
    echo -e "${YELLOW}正在同步系统时间与更新基础环境...${NC}"
    apt-get update
    apt-get install -y curl gpg lsb-release wget jq ca-certificates
    update-ca-certificates

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
    sleep 2
    
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos tunnel protocol set WireGuard
    warp-cli --accept-tos connect
    
    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        echo -e "${YELLOW}正在安装 Xray...${NC}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    init_config
    set_global_command
    echo -e "${GREEN}安装与修复完成！${NC}"
    check_status
}

# 2. 初始化 Xray 配置
init_config() {
    mkdir -p $(dirname $CONFIG_PATH)
    if [ ! -f $CONFIG_PATH ]; then
        cat > $CONFIG_PATH <<EOF
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
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:google", "geosite:netflix", "geosite:openai"],
        "outboundTag": "warp_proxy"
      },
      { "type": "field", "outboundTag": "direct", "network": "tcp,udp" }
    ]
  }
}
EOF
    fi
    systemctl restart xray
}

# 3. 域名分流管理
manage_domains() {
    echo -e "\n${BLUE}--- 域名分流管理 ---${NC}"
    current_domains=$(jq -r '.routing.rules[0].domain[]' $CONFIG_PATH)
    echo -e "当前走 WARP 的域名/标签:"
    echo -e "${YELLOW}$current_domains${NC}"
    echo "--------------------"
    echo "1. 添加域名 (例如: facebook.com)"
    echo "2. 删除域名"
    echo "0. 返回主菜单"
    read -p "请选择: " dom_opt

    case $dom_opt in
        1)
            read -p "请输入要添加的域名: " new_dom
            jq ".routing.rules[0].domain += [\"$new_dom\"]" $CONFIG_PATH > ${CONFIG_PATH}.tmp && mv ${CONFIG_PATH}.tmp $CONFIG_PATH
            systemctl restart xray && echo -e "${GREEN}已添加并重启 Xray${NC}"
            ;;
        2)
            read -p "请输入要删除的域名: " del_dom
            jq ".routing.rules[0].domain -= [\"$del_dom\"]" $CONFIG_PATH > ${CONFIG_PATH}.tmp && mv ${CONFIG_PATH}.tmp $CONFIG_PATH
            systemctl restart xray && echo -e "${GREEN}已删除并重启 Xray${NC}"
            ;;
    esac
}

# 4. IP 优选 (Endpoint 修改)
optimize_ip() {
    echo -e "\n${BLUE}--- WARP Endpoint 优选 ---${NC}"
    echo "1. 使用默认优选 IP (162.159.193.10:2408)"
    echo "2. 使用 Cloudflare 官方 IP (engage.cloudflareclient.com:2408)"
    echo "3. 手动输入优选 IP:端口"
    echo "4. 还原默认"
    read -p "请选择: " ip_opt

    case $ip_opt in
        1) target="162.159.193.10:2408" ;;
        2) target="engage.cloudflareclient.com:2408" ;;
        3) read -p "请输入 IP:端口 : " target ;;
        4) warp-cli --accept-tos tunnel endpoint reset; return ;;
    esac

    if [ ! -z "$target" ]; then
        warp-cli --accept-tos tunnel endpoint set "$target"
        echo -e "${GREEN}Endpoint 已修改为: $target${NC}"
        sleep 2
        warp-cli connect
    fi
}

# 5. 状态检查
check_status() {
    echo -e "\n${BLUE}--- 当前状态检查 ---${NC}"
    # 兼容新旧版本 warp-cli 输出
    warp_raw=$(warp-cli status)
    warp_s=$(echo "$warp_raw" | grep -Ei "Status update:|Status:" | awk '{print $NF}')
    
    echo -ne "WARP 状态: "
    if [[ "$warp_s" == "Connected" ]]; then
        echo -e "${GREEN}Connected (已连接)${NC}"
    else
        echo -e "${RED}${warp_s:-Disconnected} (未就绪)${NC}"
        echo -e "${YELLOW}提示: 若显示连接中，请稍等几秒再查看。${NC}"
    fi

    xray_s=$(systemctl is-active xray)
    echo -e "Xray 状态: $([[ "$xray_s" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}停止${NC}")"
    
    # 检查出口 IP
    echo -ne "WARP 出口 IP: "
    exit_ip=$(curl -s4m 2 --proxy socks5://127.0.0.1:40000 https://ifconfig.me)
    if [ ! -z "$exit_ip" ]; then echo -e "${GREEN}$exit_ip${NC}"; else echo -e "${RED}无法获取${NC}"; fi
    
    echo -e "--------------------"
}

# 设置全局命令
set_global_command() {
    if [[ ! -f /usr/bin/warp ]]; then
        ln -s "$SCRIPT_PATH" /usr/bin/warp
        chmod +x /usr/bin/warp
    fi
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${BLUE}====================================${NC}"
    echo -e "${GREEN}      WARP & Xray 增强管理脚本${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo -e "1. ${YELLOW}完整安装/修复环境 (含证书/协议修复)${NC}"
    echo -e "2. 域名分流管理 (添加/删除域名)"
    echo -e "3. WARP IP 优选 (修改 Endpoint)"
    echo -e "4. 刷新 WARP 连接 (更换出口 IP)"
    echo -e "5. 查看当前详细状态"
    echo -e "6. 重启所有服务"
    echo -e "0. 退出"
    echo -e "${BLUE}====================================${NC}"
    read -p "请输入选项: " opt

    case $opt in
        1) install_all ;;
        2) manage_domains ;;
        3) optimize_ip ;;
        4) warp-cli disconnect && sleep 1 && warp-cli connect && echo "已请求更换 IP" ;;
        5) check_status ;;
        6) systemctl restart warp-svc xray && echo "服务已重启" ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

# 循环显示菜单
set_global_command
while true; do
    show_menu
    echo -e "\n按任意键返回菜单..."
    read -n 1
done
