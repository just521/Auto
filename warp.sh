#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 自动安装并初始化为 Include 模式
install_warp() {
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${YELLOW}正在安装 Cloudflare WARP...${NC}"
        if [[ -f /etc/debian_version ]]; then
            sudo apt-get update && sudo apt-get install -y curl gpg lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
            sudo apt-get update && sudo apt-get install -y cloudflare-warp
        elif [[ -f /etc/redhat-release ]]; then
            sudo rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el$(rpm -E %rhel).rpm
            sudo yum install cloudflare-warp -y
        fi
        sudo systemctl enable --now warp-svc
        sleep 2
        warp-cli --accept-tos registration new
    fi

    # 关键设置：切换为仅包含模式 (Include Mode)
    # 在此模式下，默认所有流量不走 WARP，除非手动添加 host
    warp-cli tunnel mode include
    echo -e "${GREEN}WARP 已初始化为 [仅指定域名走通道] 模式。${NC}"
}

# 2. 获取地理位置
get_location() {
    local loc=$(curl -s --max-time 5 https://gs.apple.com/fastlane/refetch | grep -oE '[A-Z]{2}' | head -n 1)
    [[ -z "$loc" ]] && loc=$(curl -s --max-time 5 https://ipapi.co/country/)
    echo "$loc"
}

# 3. 修复 Google 送中并筛选 IP
fix_google_and_loc() {
    echo -e "${BLUE}开始筛选优质 WARP IP...${NC}"
    
    # 获取 VPS 原始区域
    warp-cli disconnect > /dev/null 2>&1
    local vps_loc=$(get_location)
    echo -e "${GREEN}VPS 原始区域: $vps_loc${NC}"

    # 暂时切换到全局模式以便测试 IP 质量
    warp-cli tunnel mode global
    warp-cli connect > /dev/null 2>&1
    sleep 3

    local count=1
    while true; do
        echo -e "${YELLOW}尝试第 $count 次筛选...${NC}"
        local google_check=$(curl -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        local warp_loc=$(get_location)
        
        if [[ -z "$google_check" && "$warp_loc" == "$vps_loc" ]]; then
            echo -e "${GREEN}✅ 找到理想 IP！Google 未送中 且 区域匹配 ($warp_loc)${NC}"
            break
        else
            warp-cli rotate-keys > /dev/null && sleep 3
            ((count++))
        fi
        [[ $count -gt 20 ]] && echo -e "${RED}尝试次数过多，已停止。${NC}" && break
    done

    # 恢复为 Include 模式
    warp-cli tunnel mode include
    echo -e "${BLUE}已切回 [指定域名走通道] 模式。${NC}"
}

# 4. 手动管理域名
add_custom_domain() {
    echo -n "请输入要走 WARP 的域名 (例如 google.com): "
    read domain
    if [[ ! -z "$domain" ]]; then
        warp-cli tunnel host add "$domain"
        echo -e "${GREEN}域名 $domain 已添加，现在它将通过 WARP 访问。${NC}"
    fi
}

remove_custom_domain() {
    echo -n "请输入要移除的域名: "
    read domain
    if [[ ! -z "$domain" ]]; then
        warp-cli tunnel host remove "$domain"
        echo -e "${YELLOW}域名 $domain 已移除，恢复直连。${NC}"
    fi
}

list_domains() {
    echo -e "${BLUE}--- 当前走 WARP 的域名列表 ---${NC}"
    warp-cli tunnel host list
    echo -e "${BLUE}----------------------------${NC}"
}

# 主菜单
main_menu() {
    clear
    local status=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    local mode=$(warp-cli tunnel mode | awk '{print $3}')
    [[ -z "$status" ]] && status="Disconnected"

    echo -e "${BLUE}==============================${NC}"
    echo -e "   WARP 域名分流工具"
    echo -e "   状态: ${YELLOW}$status${NC} | 模式: ${GREEN}$mode${NC}"
    echo -e "${BLUE}==============================${NC}"
    echo -e "1. 安装 / 初始化 WARP"
    echo -e "2. 连接 WARP (开启服务)"
    echo -e "3. 断开 WARP (全直连)"
    echo -e "4. ${RED}筛选优质 IP (修复送中/匹配区域)${NC}"
    echo -e "------------------------------"
    echo -e "5. ${CYAN}添加域名 (走 WARP)${NC}"
    echo -e "6. ${CYAN}删除域名 (回直连)${NC}"
    echo -e "7. 查看当前走 WARP 的域名列表"
    echo -e "------------------------------"
    echo -e "0. 退出"
    echo -n "请选择: "
}

# 运行逻辑
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 root 权限运行 (sudo warp)${NC}"
   exit 1
fi

while true; do
    main_menu
    read choice
    case $choice in
        1) install_warp ;;
        2) warp-cli connect ;;
        3) warp-cli disconnect ;;
        4) fix_google_and_loc ;;
        5) add_custom_domain ;;
        6) remove_custom_domain ;;
        7) list_domains ;;
        0) exit 0 ;;
    esac
    echo -e "\n按任意键返回..."
    read -n 1
done
