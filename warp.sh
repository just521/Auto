#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
GEOSITE_LIST="/usr/local/etc/xray/warp_geosites.list"

# 1. 安装 WARP 和 Xray
install_all() {
    echo -e "${YELLOW}正在安装依赖 (WARP & Xray)...${NC}"
    
    # 安装 WARP
    if ! command -v warp-cli &> /dev/null; then
        if [[ -f /etc/debian_version ]]; then
            apt-get update && apt-get install -y curl gpg lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(ls_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update && apt-get install -y cloudflare-warp
        elif [[ -f /etc/redhat-release ]]; then
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el$(rpm -E %rhel).rpm
            yum install cloudflare-warp -y
        fi
        systemctl enable --now warp-svc
        sleep 2
        warp-cli --accept-tos registration new
    fi

    # 设置 WARP 为代理模式 (端口 40000)
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect

    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 初始化域名列表文件
    if [ ! -f "$GEOSITE_LIST" ]; then
        echo '"geosite:google","geosite:openai","geosite:netflix"' > "$GEOSITE_LIST"
    fi

    update_xray_config
    fix_google_and_loc
}

# 2. 更新 Xray 配置文件 (核心分流逻辑)
update_xray_config() {
    local domains=$(cat "$GEOSITE_LIST")
    
    cat > $CONFIG_PATH <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 1080, 
      "protocol": "socks",
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    {
      "tag": "warp_proxy",
      "protocol": "socks",
      "settings": {
        "servers": [ { "address": "127.0.0.1", "port": 40000 } ]
      }
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": [ $domains ],
        "outboundTag": "warp_proxy"
      },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    systemctl restart xray
    echo -e "${GREEN}Xray 配置已更新并重启。${NC}"
}

# 3. 获取地理位置 (通过 WARP 代理端口)
get_warp_location() {
    local loc=$(curl -x socks5h://127.0.0.1:40000 -s --max-time 5 https://gs.apple.com/fastlane/refetch | grep -oE '[A-Z]{2}' | head -n 1)
    echo "$loc"
}

# 4. 筛选 IP (修复送中)
fix_google_and_loc() {
    echo -e "${BLUE}开始筛选优质 WARP IP...${NC}"
    
    # 获取 VPS 原始区域
    local vps_loc=$(curl -s https://ipapi.co/country/)
    echo -e "${GREEN}VPS 原始区域: $vps_loc${NC}"

    local count=1
    while true; do
        echo -ne "${YELLOW}尝试第 $count 次筛选 IP... \r${NC}"
        # 检测 Google 是否送中 (通过 WARP 端口)
        local google_check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        local warp_loc=$(get_warp_location)
        
        if [[ -z "$google_check" && "$warp_loc" == "$vps_loc" ]]; then
            echo -e "\n${GREEN}✅ 完美匹配！Google 未送中 且 区域为 $warp_loc${NC}"
            break
        else
            warp-cli rotate-keys > /dev/null && sleep 2
            ((count++))
        fi
        [[ $count -gt 50 ]] && echo -e "\n${RED}尝试次数过多，请手动重试。${NC}" && break
    done
}

# 5. 管理域名列表
manage_domains() {
    echo -e "${BLUE}当前分流规则:${NC}"
    cat "$GEOSITE_LIST"
    echo -e "\n${YELLOW}请输入要【添加】或【删除】的规则 (例如 geosite:youtube 或 gemini.google.com)${NC}"
    echo -e "${YELLOW}直接按回车取消。${NC}"
    read -p "输入规则: " new_rule
    
    if [[ ! -z "$new_rule" ]]; then
        if grep -q "$new_rule" "$GEOSITE_LIST"; then
            # 存在则删除
            sed -i "s/\"$new_rule\",//g; s/,\"$new_rule\"//g; s/\"$new_rule\"//g" "$GEOSITE_LIST"
            # 清理可能残留的逗号
            sed -i 's/,,/,/g; s/^,//; s/,$//' "$GEOSITE_LIST"
            echo -e "${RED}已移除 $new_rule${NC}"
        else
            # 不存在则添加
            local current=$(cat "$GEOSITE_LIST")
            if [[ -z "$current" ]]; then
                echo "\"$new_rule\"" > "$GEOSITE_LIST"
            else
                echo "$current,\"$new_rule\"" > "$GEOSITE_LIST"
            fi
            echo -e "${GREEN}已添加 $new_rule${NC}"
        fi
        update_xray_config
    fi
}

# 主菜单
main_menu() {
    clear
    local warp_status=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    echo -e "${BLUE}====================================${NC}"
    echo -e "   WARP & Xray 分流管理工具"
    echo -e "   WARP 状态: ${YELLOW}$warp_status${NC} (Port: 40000)"
    echo -e "   Xray 状态: ${GREEN}Running${NC} (SOCKS5 Port: 1080)"
    echo -e "${BLUE}====================================${NC}"
    echo -e "1. 安装 / 重新初始化环境"
    echo -e "2. 开启 WARP"
    echo -e "3. 关闭 WARP"
    echo -e "4. ${RED}筛选优质 IP (修复 Google 送中)${NC}"
    echo -e "------------------------------------"
    echo -e "5. 管理分流域名 (geosite 或 domain)"
    echo -e "6. 查看当前所有分流规则"
    echo -e "------------------------------------"
    echo -e "0. 退出"
    echo -n "请选择: "
}

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 root 权限运行${NC}"
   exit 1
fi

while true; do
    main_menu
    read choice
    case $choice in
        1) install_all ;;
        2) warp-cli connect ;;
        3) warp-cli disconnect ;;
        4) fix_google_and_loc ;;
        5) manage_domains ;;
        6) cat "$GEOSITE_LIST"; echo ""; read -p "按回车继续..." ;;
        0) exit 0 ;;
    esac
    echo -e "\n按任意键继续..."
    read -n 1
done
