#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${NC}" && exit 1

# 检查内核版本 (Cake 需要 4.19+)
kernel_version=$(uname -r | cut -d- -f1)
major=$(echo $kernel_version | cut -d. -f1)
minor=$(echo $kernel_version | cut -d. -f2)

check_status() {
    current_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')
    current_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "${BLUE}============================${NC}"
    echo -e "${YELLOW}当前内核版本: ${NC}$kernel_version"
    echo -e "${YELLOW}当前队列算法: ${NC}${GREEN}$current_qdisc${NC}"
    echo -e "${YELLOW}当前拥塞控制: ${NC}${GREEN}$current_cc${NC}"
    echo -e "${BLUE}============================${NC}"
}

apply_conf() {
    local qdisc=$1
    # 清理旧配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    # 写入新配置
    echo "net.core.default_qdisc=$qdisc" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    
    # 使配置生效
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}成功切换至 BBR + $qdisc !${NC}"
}

show_menu() {
    clear
    echo -e "${BLUE}BBR + Cake/FQ 自由切换脚本${NC}"
    echo -e "${BLUE}----------------------------${NC}"
    check_status
    echo -e "1. 切换至 ${GREEN}BBR + FQ${NC} (经典组合，适合大部分环境)"
    echo -e "2. 切换至 ${GREEN}BBR + Cake${NC} (最新算法，抗丢包更强，需内核4.19+)"
    echo -e "3. 仅开启 BBR (保持默认队列)"
    echo -e "4. 卸载/恢复系统默认设置"
    echo -e "0. 退出脚本"
    echo -e "${BLUE}----------------------------${NC}"
    read -p "请输入数字选择: " choice

    case $choice in
        1)
            apply_conf "fq"
            ;;
        2)
            if [ "$major" -lt 4 ] || ([ "$major" -eq 4 ] && [ "$minor" -lt 19 ]); then
                echo -e "${RED}错误: Cake 算法需要内核 4.19 或更高版本，当前内核不支持！${NC}"
                sleep 2
            else
                apply_conf "cake"
            fi
            ;;
        3)
            apply_conf "$(sysctl net.core.default_qdisc | awk '{print $3}')"
            ;;
        4)
            sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            echo -e "${YELLOW}已恢复默认设置。${NC}"
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入!${NC}"
            sleep 1
            ;;
    esac
}

# 循环显示菜单
while true; do
    show_menu
    echo -e "${BLUE}按任意键返回菜单...${NC}"
    read -n 1
done
