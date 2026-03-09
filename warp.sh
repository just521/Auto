#!/bin/bash

# ─────────────────────────────────────────────
#  Xray WARP 分流管理器
# ─────────────────────────────────────────────

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
WARP_PORT=40000

UI_MESSAGE=""

# ─── 环境检查 ────────────────────────────────
clear
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 sudo 运行此脚本！${PLAIN}"; exit 1; fi

# ─── WARP 连通性检测 ─────────────────────────
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

# ─── Xray 配置状态检测 ───────────────────────
check_xray_outbound() {
    jq -e '.outbounds[] | select(.tag=="warp_proxy")' "$CONFIG_FILE" >/dev/null 2>&1
}

check_rule_ui() {
    local site=$1
    if jq -e --arg site "$site" '.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain | index($site)))' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${GREEN}WARP托管${PLAIN}"
    else
        echo -e "${YELLOW}默认直连${PLAIN}"
    fi
}

# ─── 配置应用 & 重启 ─────────────────────────
apply_changes() {
    systemctl restart xray >/dev/null 2>&1
}

ensure_outbound() {
    if check_xray_outbound; then return; fi
    local out_obj='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_PORT'}]}}'
    jq --argjson obj "$out_obj" '.outbounds += [$obj]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

remove_outbound() {
    jq 'del(.outbounds[] | select(.tag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# ─── 分流规则开关 ────────────────────────────
toggle_rule() {
    local name=$1; local sites_json=$2

    if ! check_warp_socket; then
        UI_MESSAGE="${YELLOW}WARP 未运行！无法修改分流，请执行 1 安装。${PLAIN}"
        return
    fi

    ensure_outbound

    local first_site=$(echo "$sites_json" | jq -r '.[0]' 2>/dev/null)
    local is_enabled=false
    if jq -e --arg site "$first_site" '.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain | index($site)))' "$CONFIG_FILE" >/dev/null 2>&1; then
        is_enabled=true
    fi

    if [ "$is_enabled" = true ]; then
        jq --argjson sites "$sites_json" 'del(.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain == $sites)))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${YELLOW}已关闭 $name 分流${PLAIN} (Xray已自动重启)"
    else
        local new_rule="{\"type\": \"field\", \"domain\": $sites_json, \"outboundTag\": \"warp_proxy\"}"
        jq --argjson rule "$new_rule" '.routing.rules = [$rule] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${GREEN}已开启 $name 分流${PLAIN} (Xray已自动重启)"
    fi
    apply_changes
}

# ─── 安装 WARP ───────────────────────────────
install_warp() {
    clear
    echo -e "\n${CYAN}正在安装 WARP (Socks5 模式)...${PLAIN}"
    (wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh c)

    if wait_for_port; then
        ensure_outbound; apply_changes
        UI_MESSAGE="${GREEN}安装成功！Xray 已自动对接。${PLAIN}"
    else
        UI_MESSAGE="${RED}安装超时或失败，请查看上方日志。${PLAIN}"
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
    clear; printf '\033[3J'
}

# ─── 卸载 WARP ───────────────────────────────
uninstall_warp() {
    clear
    echo -e "\n${RED}正在卸载 WARP...${PLAIN}"
    if command -v warp &>/dev/null; then (warp u); else (wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh u); fi
    remove_outbound; apply_changes
    UI_MESSAGE="${GREEN}卸载及规则清理完毕。${PLAIN}"
    sleep 1
    clear; printf '\033[3J'
}

# ─── 菜单界面 ────────────────────────────────
clear
show_menu() {
    tput cup 0 0

    if check_warp_socket; then STATUS_SOCK="${GREEN}● 运行中${PLAIN}"; else STATUS_SOCK="${RED}● 未运行${PLAIN}"; fi
    if check_xray_outbound; then STATUS_XRAY="${GREEN}● 已连接${PLAIN}"; else STATUS_XRAY="${YELLOW}● 未连接${PLAIN}"; fi

    STATUS_NF=$(check_rule_ui "geosite:netflix")
    STATUS_AI=$(check_rule_ui "geosite:openai")

    echo -e "${CYAN}===================================================${PLAIN}\033[K"
    echo -e "${CYAN}           WARP 分流管理面板 (Xray Warp)          ${PLAIN}\033[K"
    echo -e "${CYAN}===================================================${PLAIN}\033[K"
    echo -e "  WARP 服务: ${STATUS_SOCK}    Xray 接口: ${STATUS_XRAY}\033[K"
    echo -e "---------------------------------------------------\033[K"
    echo -e "  1. 安装/重装 WARP    - ${GRAY}自动配置 Socks5 端口 40000${PLAIN}\033[K"
    echo -e "  2. 卸载/清理 WARP    - ${GRAY}卸载并清理残留规则${PLAIN}\033[K"
    echo -e ""\033[K
    echo -e "  3. 开启/关闭 Netflix 分流              - ${STATUS_NF}\033[K"
    echo -e "  4. 开启/关闭 OpenAI, Claude, Grok 分流 - ${STATUS_AI}\033[K"
    echo -e "---------------------------------------------------\033[K"
    echo -e "  0. 退出 (Exit)\033[K"
    echo -e "===================================================\033[K"
    if [ -n "$UI_MESSAGE" ]; then
        echo -e "${YELLOW}当前操作${PLAIN}: ${UI_MESSAGE}\033[K"
        UI_MESSAGE=""
    else
        echo -e "${YELLOW}当前操作${PLAIN}: ${GRAY}等待输入...${PLAIN}\033[K"
    fi
    echo -e "===================================================\033[K"
    tput ed
}

# ─── 主循环 ──────────────────────────────────
while true; do
    show_menu

    error_msg=""
    while true; do
        if [ -n "$error_msg" ]; then
            echo -ne "\r\033[K${RED}${error_msg}${PLAIN} 请输入选项 [0-4]: "
        else
            echo -ne "\r\033[K请输入选项 [0-4]: "
        fi
        read -r choice
        case "$choice" in
            1|2|3|4|0) break ;;
            *) error_msg="输入无效！"; echo -ne "\033[1A" ;;
        esac
    done

    case "$choice" in
        1) install_warp ;;
        2) uninstall_warp ;;
        3) toggle_rule "Netflix"      '["geosite:netflix"]' ;;
        4) toggle_rule "AI Services"  '["geosite:openai","geosite:anthropic","geosite:twitter"]' ;;
        0) clear; exit 0 ;;
    esac
done
