#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 域名列表
GOOGLE_DOMAINS=("google.com" "googleapis.com" "gstatic.com" "googleusercontent.com" "ggpht.com")
OPENAI_DOMAINS=("openai.com" "chatgpt.com" "oaistatic.com" "oaiusercontent.com")
NETFLIX_DOMAINS=("netflix.com" "nflxext.com" "nflximg.net" "nflxvideo.net" "nflxso.net")

# 1. 自动安装 Cloudflare WARP 官方客户端
install_warp() {
    if command -v warp-cli &> /dev/null; then
        echo -e "${GREEN}检测到 Cloudflare WARP 已安装。${NC}"
        return
    fi

    echo -e "${YELLOW}正在安装 Cloudflare WARP 官方客户端...${NC}"
    
    # 自动识别发行版
    if [[ -f /etc/debian_version ]]; then
        sudo apt-get update
        sudo apt-get install -y curl gpg lsb-release
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
        sudo apt-get update && sudo apt-get install -y cloudflare-warp
    elif [[ -f /etc/redhat-release ]]; then
        sudo rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el$(rpm -E %rhel).rpm
        sudo yum install cloudflare-warp -y
    else
        echo -e "${RED}不支持的操作系统，请手动安装。${NC}"
        exit 1
    fi

    # 启动服务并初始化注册
    sudo systemctl enable --now warp-svc
    sleep 2
    warp-cli --accept-tos registration new
    echo -e "${GREEN}WARP 安装并注册完成。${NC}"
}

# 2. 获取地理位置 (国家代码)
get_location() {
    # 优先使用 Apple 的接口获取国家代码
    local loc=$(curl -s --max-time 5 https://gs.apple.com/fastlane/refetch | grep -oE '[A-Z]{2}' | head -n 1)
    if [[ -z "$loc" ]]; then
        # 备选接口
        loc=$(curl -s --max-time 5 https://ipapi.co/country/)
    fi
    echo "$loc"
}

# 3. 核心修复逻辑：Google 送中 + 区域匹配 (以 VPS 原生 IP 为准)
fix_google_and_loc() {
    echo -e "${BLUE}步骤 1: 正在检测 VPS 原始物理位置...${NC}"
    
    # 检查当前是否已连接，若连接则断开以获取原始 IP
    local current_status=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    if [[ "$current_status" == "Connected" ]]; then
        warp-cli disconnect > /dev/null
        sleep 2
    fi
    
    local vps_loc=$(get_location)
    if [[ -z "$vps_loc" ]]; then
        echo -e "${RED}无法获取 VPS 原始位置，请检查网络连接。${NC}"
        return
    fi
    echo -e "${GREEN}VPS 原始位置确定为: $vps_loc${NC}"
    
    echo -e "${BLUE}步骤 2: 连接 WARP 并筛选符合条件的 IP...${NC}"
    warp-cli connect > /dev/null
    sleep 3

    local count=1
    while true; do
        echo -e "${YELLOW}--- 尝试第 $count 次筛选 ---${NC}"
        
        # 检查 Google 是否重定向到 HK 或 CN (送中)
        # 使用 ncr 检查重定向头，或者直接检查搜索结果特征
        local google_check=$(curl -sI https://www.google.com/search?q=ip | grep -Ei "location: https://www.google.com.hk|location: https://www.google.cn")
        
        # 检查当前 WARP IP 的地理位置
        local warp_loc=$(get_location)
        
        echo -e "当前 WARP 识别区域: ${BLUE}$warp_loc${NC}"
        
        if [[ -z "$google_check" && "$warp_loc" == "$vps_loc" ]]; then
            echo -e "${GREEN}✅ 完美匹配！${NC}"
            echo -e "${GREEN}1. Google 搜索正常 (未送中)${NC}"
            echo -e "${GREEN}2. 区域已对齐 VPS 原生位置 ($warp_loc)${NC}"
            break
        else
            [[ ! -z "$google_check" ]] && echo -e "${RED}❌ Google 识别为中国区 (送中)${NC}"
            [[ "$warp_loc" != "$vps_loc" ]] && echo -e "${RED}❌ 区域不匹配 (目标: $vps_loc, 当前: $warp_loc)${NC}"
            
            echo -e "${YELLOW}正在更换 IP (Rotate Keys)...${NC}"
            warp-cli rotate-keys > /dev/null
            sleep 3
            ((count++))
        fi
        
        if [[ $count -gt 30 ]]; then
            echo -e "${RED}已尝试 30 次仍未找到匹配 IP。Cloudflare 当前在该区域可能没有合适的 IP 段，建议稍后再试。${NC}"
            break
        fi
    done
}

# 4. 分流管理 (Split Tunneling)
manage_split_tunnel() {
    local action=$1
    local service=$2
    local domains=()
    case $service in
        google) domains=("${GOOGLE_DOMAINS[@]}") ;;
        openai) domains=("${OPENAI_DOMAINS[@]}") ;;
        netflix) domains=("${NETFLIX_DOMAINS[@]}") ;;
    esac

    for domain in "${domains[@]}"; do
        if [[ "$action" == "add" ]]; then
            # 绕过 WARP (直连)
            warp-cli tunnel host add "$domain" > /dev/null 2>&1
        else
            # 走 WARP (从排除列表中移除)
            warp-cli tunnel host remove "$domain" > /dev/null 2>&1
        fi
    done
    echo -e "${GREEN}$service 规则已更新。${NC}"
}

# 主菜单
main_menu() {
    clear
    local status=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    [[ -z "$status" ]] && status="Disconnected"

    echo -e "${BLUE}====================================${NC}"
    echo -e "${BLUE}      Cloudflare WARP 自动化工具      ${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo -e "当前状态: ${YELLOW}$status${NC}"
    echo -e "全局命令: ${GREEN}warp${NC}"
    echo -e "------------------------------------"
    echo -e "1. 安装 / 重新注册 WARP"
    echo -e "2. 开启 WARP"
    echo -e "3. 关闭 WARP"
    echo -e "4. ${RED}修复 Google 送中 (匹配 VPS 原生区域)${NC}"
    echo -e "------------------------------------"
    echo -e "5. Google:   [走 WARP]"
    echo -e "6. Google:   [直连/绕过]"
    echo -e "7. OpenAI:   [走 WARP]"
    echo -e "8. OpenAI:   [直连/绕过]"
    echo -e "9. Netflix:  [走 WARP]"
    echo -e "10. Netflix: [直连/绕过]"
    echo -e "------------------------------------"
    echo -e "0. 退出"
    echo -n "请选择: "
}

# 脚本入口
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 root 权限运行此脚本 (sudo warp)${NC}"
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
        5) manage_split_tunnel "remove" "google" ;;
        6) manage_split_tunnel "add" "google" ;;
        7) manage_split_tunnel "remove" "openai" ;;
        8) manage_split_tunnel "add" "openai" ;;
        9) manage_split_tunnel "remove" "netflix" ;;
        10) manage_split_tunnel "add" "netflix" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
    echo -e "\n按任意键返回菜单..."
    read -n 1
done
