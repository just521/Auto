cat > warp.sh <<'EOF'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
GEOSITE_LIST="/usr/local/etc/xray/warp_geosites.list"

# 1. 安装环境
install_all() {
    echo -e "${YELLOW}正在安装依赖...${NC}"
    if ! command -v warp-cli &> /dev/null; then
        if [[ -f /etc/debian_version ]]; then
            apt-get update && apt-get install -y curl gpg lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update && apt-get install -y cloudflare-warp
        elif [[ -f /etc/redhat-release ]]; then
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el$(rpm -E %rhel).rpm
            yum install cloudflare-warp -y
        fi
        systemctl enable --now warp-svc
        sleep 2
        warp-cli --accept-tos registration new
    fi

    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect

    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    mkdir -p /usr/local/etc/xray/
    if [ ! -f "$GEOSITE_LIST" ]; then
        echo '"geosite:google","geosite:openai","geosite:netflix"' > "$GEOSITE_LIST"
    fi

    update_xray_config
    fix_google_and_loc
}

# 2. 更新 Xray 配置
update_xray_config() {
    local domains=$(cat "$GEOSITE_LIST" 2>/dev/null || echo '"geosite:google"')
    cat > $CONFIG_PATH <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
      "port": 1080, "protocol": "socks",
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] },
      "settings": { "auth": "noauth", "udp": true }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "tag": "warp_proxy", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": [ $domains ], "outboundTag": "warp_proxy" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF
    systemctl restart xray
    echo -e "${GREEN}Xray 配置已更新并重启。${NC}"
}

# 3. 获取区域
get_warp_location() {
    curl -x socks5h://127.0.0.1:40000 -s --max-time 5 https://gs.apple.com/fastlane/refetch | grep -oE '[A-Z]{2}' | head -n 1
}

# 4. 筛选 IP (修复语法错误)
fix_google_and_loc() {
    echo -e "${BLUE}开始筛选优质 IP...${NC}"
    warp-cli connect > /dev/null 2>&1
    sleep 2
    
    local vps_loc=$(curl -s https://ipapi.co/country/)
    [ -z "$vps_loc" ] && vps_loc="Unknown"
    echo -e "${GREEN}VPS 原始区域: $vps_loc${NC}"

    local count=1
    while [ $count -le 50 ]; do
        echo -ne "${YELLOW}尝试第 $count 次筛选... \r${NC}"
        
        local google_check=$(curl -x socks5h://127.0.0.1:40000 -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        local warp_loc=$(get_warp_location)
        
        if [[ -z "$google_check" && "$warp_loc" == "$vps_loc" ]]; then
            echo -e "\n${GREEN}✅ 成功！Google 未送中，区域: $warp_loc${NC}"
            return 0
        else
            warp-cli registration rotate > /dev/null 2>&1 || warp-cli rotate-keys > /dev/null 2>&1
            sleep 3
            count=$((count + 1))
        fi
    done
    echo -e "\n${RED}已达最大尝试次数，请手动检查。${NC}"
}

# 5. 管理域名
manage_domains() {
    echo -e "${BLUE}当前规则: $(cat "$GEOSITE_LIST")${NC}"
    read -p "输入要添加/删除的规则 (如 geosite:disney): " new_rule
    if [[ -n "$new_rule" ]]; then
        if grep -q "$new_rule" "$GEOSITE_LIST"; then
            sed -i "s/\"$new_rule\",//g; s/,\"$new_rule\"//g; s/\"$new_rule\"//g" "$GEOSITE_LIST"
            echo -e "${RED}已移除${NC}"
        else
            local current=$(cat "$GEOSITE_LIST")
            [ -z "$current" ] && echo "\"$new_rule\"" > "$GEOSITE_LIST" || echo "$current,\"$new_rule\"" > "$GEOSITE_LIST"
            echo -e "${GREEN}已添加${NC}"
        fi
        update_xray_config
    fi
}

# 主菜单
while true; do
    clear
    status=$(warp-cli status 2>/dev/null | grep -i "Status update:" | awk '{print $3}')
    echo -e "${BLUE}==============================${NC}"
    echo -e "   WARP 修复版管理工具"
    echo -e "   WARP 状态: ${YELLOW}${status:-Disconnected}${NC}"
    echo -e "${BLUE}==============================${NC}"
    echo -e "1. 安装/初始化"
    echo -e "2. 开启 WARP"
    echo -e "3. 关闭 WARP"
    echo -e "4. 筛选 IP (解决送中)"
    echo -e "5. 管理分流域名"
    echo -e "0. 退出"
    read -p "选择: " choice
    case $choice in
        1) install_all ;;
        2) warp-cli connect ;;
        3) warp-cli disconnect ;;
        4) fix_google_and_loc ;;
        5) manage_domains ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    read -p "按回车继续..."
done
EOF

chmod +x warp.sh
./warp.sh
