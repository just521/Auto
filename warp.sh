#!/bin/bash

# ─────────────────────────────────────────────
#  Xray WARP 动态分流管理器 (增强版)
# ─────────────────────────────────────────────

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
WARP_PORT=40000
SCRIPT_PATH="/usr/local/bin/warp"

UI_MESSAGE=""

# ─── 系统命令安装 ────────────────────────────
install_command() {
    if [[ "$0" != "$SCRIPT_PATH" ]]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        UI_MESSAGE="${GREEN}已安装系统命令，以后直接输入 ${YELLOW}warp${GREEN} 即可调用。${PLAIN}"
    fi
}

# ─── 环境检查 ────────────────────────────────
clear
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 sudo 运行此脚本！${PLAIN}"; exit 1; fi
if ! command -v jq &>/dev/null; then echo -e "${YELLOW}正在安装 jq...${PLAIN}"; apt update && apt install -y jq; fi

# ─── 状态检测函数 ────────────────────────────
check_warp_socket() {
    (echo > /dev/tcp/127.0.0.1/$WARP_PORT) >/dev/null 2>&1
}

wait_for_port() {
    for i in {1..15}; do
        if check_warp_socket; then return 0; fi
        sleep 1
    done
    return 1
}

check_xray_outbound() {
    [ -f "$CONFIG_FILE" ] && jq -e '.outbounds[] | select(.tag=="warp_proxy")' "$CONFIG_FILE" >/dev/null 2>&1
}

get_warp_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then echo ""; return; fi
    jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy") | .domain[]' "$CONFIG_FILE" 2>/dev/null
}

# ─── 核心功能 ────────────────────────────────
apply_changes() {
    systemctl restart xray >/dev/null 2>&1
}

ensure_outbound() {
    if check_xray_outbound; then return; fi
    local out_obj='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_PORT'}]}}'
    jq --argjson obj "$out_obj" '.outbounds += [$obj]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# 1. 安装/重装
install_warp() {
    clear
    echo -e "\n${CYAN}正在安装 WARP (Socks5 模式)...${PLAIN}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh c
    if wait_for_port; then
        ensure_outbound; apply_changes
        UI_MESSAGE="${GREEN}安装成功！Xray 已自动对接。${PLAIN}"
    else
        UI_MESSAGE="${RED}安装超时，请检查网络。${PLAIN}"
    fi
}

# 2. 卸载
uninstall_warp() {
    clear
    echo -e "\n${RED}正在卸载 WARP 并清理规则...${PLAIN}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh u
    jq 'del(.outbounds[] | select(.tag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    apply_changes
    UI_MESSAGE="${GREEN}卸载及规则清理完毕。${PLAIN}"
}

# 3. 分流管理
manage_custom_rule() {
    if ! check_warp_socket; then UI_MESSAGE="${RED}错误：WARP 未运行！${PLAIN}"; return; fi
    echo -e "\n${CYAN}请输入要分流的标签 (例如 geosite:google 或 domain:openai.com)${PLAIN}"
    read -p "输入已存在则删除，不存在则添加: " user_input
    [ -z "$user_input" ] && return
    ensure_outbound
    local exists=$(jq -r --arg target "$user_input" '.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain[] == $target)) | .outboundTag' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$exists" ]; then
        jq --arg target "$user_input" '.routing.rules |= map(if .outboundTag == "warp_proxy" then .domain |= map(select(. != $target)) else . end) | .routing.rules |= map(select(.domain != []))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${YELLOW}已移除分流: $user_input${PLAIN}"
    else
        local new_rule="{\"type\": \"field\", \"domain\": [\"$user_input\"], \"outboundTag\": \"warp_proxy\"}"
        jq --argjson rule "$new_rule" '.routing.rules = [$rule] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${GREEN}已添加分流: $user_input${PLAIN}"
    fi
    apply_changes
}

# 4. IP 优选 (地区/端点管理)
optimize_warp_ip() {
    if ! check_warp_socket; then UI_MESSAGE="${RED}错误：WARP 未运行！${PLAIN}"; return; fi
    clear
    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "             WARP Endpoint (端点/地区) 优选"
    echo -e "---------------------------------------------------"
    echo -e "  1. ${GREEN}自动优选${PLAIN} (寻找延迟最低的端点)"
    echo -e "  2. ${YELLOW}手动指定${PLAIN} (输入特定地区 Endpoint IP)"
    echo -e "  3. ${CYAN}刷新 IP${PLAIN} (重启 WARP 尝试更换出口)"
    echo -e "---------------------------------------------------"
    read -p "请选择 [1-3]: " opt_choice
    case "$opt_choice" in
        1) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh e ;;
        2) read -p "请输入 Endpoint (IP:Port): " ep
           [ -n "$ep" ] && (wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh e <<EOF
$ep
EOF
) ;;
        3) wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh r ;;
    esac
}

# ─── 菜单界面 ────────────────────────────────
show_menu() {
    clear
    # 状态计算
    if check_warp_socket; then 
        STATUS_SOCK="${GREEN}● 运行中${PLAIN}"
        # 获取 WARP 详细信息 (设置 2秒超时防止卡顿)
        local trace=$(curl -s4m 2 --socks5 127.0.0.1:$WARP_PORT https://www.cloudflare.com/cdn-cgi/trace)
        WARP_IP=$(echo "$trace" | grep "ip=" | cut -d= -f2)
        WARP_LOC=$(echo "$trace" | grep "loc=" | cut -d= -f2)
        [ -z "$WARP_IP" ] && WARP_IP="${RED}获取失败${PLAIN}"
        [ -z "$WARP_LOC" ] && WARP_LOC="${RED}获取失败${PLAIN}"
    else 
        STATUS_SOCK="${RED}● 未运行${PLAIN}"
        WARP_IP="${GRAY}N/A${PLAIN}"
        WARP_LOC="${GRAY}N/A${PLAIN}"
    fi

    if check_xray_outbound; then STATUS_XRAY="${GREEN}● 已连接${PLAIN}"; else STATUS_XRAY="${YELLOW}● 未连接${PLAIN}"; fi
    
    local current_rules=$(get_warp_rules | tr '\n' ' ' | sed 's/ $//')
    [ -z "$current_rules" ] && current_rules="${GRAY}无${PLAIN}"

    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "${CYAN}           WARP 动态分流管理面板 (Xray)           ${PLAIN}"
    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "  WARP 状态: ${STATUS_SOCK}"
    echo -e "  Xray 接口: ${STATUS_XRAY}"
    echo -e "  WARP IP  : ${GREEN}${WARP_IP}${PLAIN}"
    echo -e "  归 属 地 : ${GREEN}${WARP_LOC}${PLAIN}"
    echo -e "  当前分流 : ${YELLOW}${current_rules}${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e "  1. 安装/重装 WARP (Socks5:40000)"
    echo -e "  2. 卸载/清理 WARP 及所有分流规则"
    echo -e "  3. 添加/删除 自定义分流 (geosite/domain)"
    echo -e "  4. ${CYAN}优选 WARP Endpoint (更换出口地区/延迟)${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e "  0. 退出 (Exit)"
    echo -e "==================================================="
    if [ -n "$UI_MESSAGE" ]; then
        echo -e "${YELLOW}提示${PLAIN}: ${UI_MESSAGE}"
        UI_MESSAGE=""
    fi
}

# ─── 主循环 ──────────────────────────────────
install_command
while true; do
    show_menu
    echo -ne "请输入选项 [0-4]: "
    read -r choice
    case "$choice" in
        1) install_warp ;;
        2) uninstall_warp ;;
        3) manage_custom_rule ;;
        4) optimize_warp_ip ;;
        0) clear; exit 0 ;;
        *) UI_MESSAGE="${RED}无效输入！${PLAIN}" ;;
    esac
done
