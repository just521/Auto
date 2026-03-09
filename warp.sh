#!/bin/bash

# ─────────────────────────────────────────────
#  Xray WARP 动态分流
# ─────────────────────────────────────────────

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
WARP_PORT=40000
SCRIPT_PATH="/usr/local/bin/warp"

UI_MESSAGE=""

# ─── 系统命令安装逻辑 ────────────────────────
# 检查脚本是否已安装为 'warp' 命令，如果没有则自动安装
install_command() {
    if [[ "$0" != "$SCRIPT_PATH" ]]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        UI_MESSAGE="${GREEN}已将脚本安装为系统命令，以后直接输入 ${YELLOW}warp${GREEN} 即可调用。${PLAIN}"
    fi
}

# ─── 环境检查 ────────────────────────────────
clear
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 sudo 运行此脚本！${PLAIN}"; exit 1; fi
if ! command -v jq &>/dev/null; then echo -e "${YELLOW}正在安装 jq...${PLAIN}"; apt update && apt install -y jq; fi

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
    [ -f "$CONFIG_FILE" ] && jq -e '.outbounds[] | select(.tag=="warp_proxy")' "$CONFIG_FILE" >/dev/null 2>&1
}

get_warp_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then echo ""; return; fi
    jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy") | .domain[]' "$CONFIG_FILE" 2>/dev/null
}

# ─── 配置应用 & 重启 ─────────────────────────
apply_changes() {
    systemctl restart xray >/dev/null 2>&1
}

ensure_outbound() {
    if check_xray_outbound; then return; fi
    local out_obj='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_PORT'}]}}'
    jq --argjson obj "$out_obj" '.outbounds += [$obj]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# ─── 核心：自定义分流管理 ──────────────────────
manage_custom_rule() {
    if ! check_warp_socket; then
        UI_MESSAGE="${RED}错误：WARP 未运行，请先安装 WARP！${PLAIN}"
        return
    fi

    echo -e "\n${CYAN}请输入要分流的标签 (例如 geosite:google 或 domain:openai.com)${PLAIN}"
    echo -ne "${YELLOW}输入已存在的标签则删除，不存在则添加: ${PLAIN}"
    read -r user_input

    if [ -z "$user_input" ]; then
        UI_MESSAGE="${GRAY}操作取消${PLAIN}"
        return
    fi

    ensure_outbound

    local exists=$(jq -r --arg target "$user_input" '.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain[] == $target)) | .outboundTag' "$CONFIG_FILE" 2>/dev/null)

    if [ -n "$exists" ]; then
        jq --arg target "$user_input" '
            .routing.rules |= map(
                if .outboundTag == "warp_proxy" then
                    .domain |= map(select(. != $target))
                else . end
            ) | .routing.rules |= map(select(.domain != []))
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${YELLOW}已移除分流: $user_input${PLAIN}"
    else
        local new_rule="{\"type\": \"field\", \"domain\": [\"$user_input\"], \"outboundTag\": \"warp_proxy\"}"
        jq --argjson rule "$new_rule" '.routing.rules = [$rule] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${GREEN}已添加分流: $user_input${PLAIN}"
    fi

    apply_changes
}

# ─── 安装/卸载 WARP ──────────────────────────
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

uninstall_warp() {
    clear
    echo -e "\n${RED}正在卸载 WARP 并清理规则...${PLAIN}"
    if command -v warp &>/dev/null; then 
        # 避免调用本脚本自身，尝试调用原版 warp 卸载
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh u
    fi
    jq 'del(.outbounds[] | select(.tag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq 'del(.routing.rules[] | select(.outboundTag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    apply_changes
    UI_MESSAGE="${GREEN}卸载及规则清理完毕。${PLAIN}"
}

# ─── 菜单界面 ────────────────────────────────
show_menu() {
    clear
    if check_warp_socket; then STATUS_SOCK="${GREEN}● 运行中${PLAIN}"; else STATUS_SOCK="${RED}● 未运行${PLAIN}"; fi
    if check_xray_outbound; then STATUS_XRAY="${GREEN}● 已连接${PLAIN}"; else STATUS_XRAY="${YELLOW}● 未连接${PLAIN}"; fi

    local current_rules=$(get_warp_rules | tr '\n' ' ' | sed 's/ $//')
    [ -z "$current_rules" ] && current_rules="${GRAY}无${PLAIN}"

    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "${CYAN}           WARP 动态分流管理面板 (Xray)           ${PLAIN}"
    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "  WARP 服务: ${STATUS_SOCK}    Xray 接口: ${STATUS_XRAY}"
    echo -e "  当前分流: ${YELLOW}${current_rules}${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e "  1. 安装/重装 WARP (Socks5:40000)"
    echo -e "  2. 卸载/清理 WARP 及所有分流规则"
    echo -e "  3. 添加/删除 自定义分流 (geosite/domain)"
    echo -e "---------------------------------------------------"
    echo -e "  0. 退出 (Exit)"
    echo -e "==================================================="
    if [ -n "$UI_MESSAGE" ]; then
        echo -e "${YELLOW}提示${PLAIN}: ${UI_MESSAGE}"
        UI_MESSAGE=""
    fi
}

# ─── 主循环 ──────────────────────────────────
install_command  # 运行即检查安装命令
while true; do
    show_menu
    echo -ne "请输入选项 [0-3]: "
    read -r choice
    case "$choice" in
        1) install_warp ;;
        2) uninstall_warp ;;
        3) manage_custom_rule ;;
        0) clear; exit 0 ;;
        *) UI_MESSAGE="${RED}无效输入！${PLAIN}" ;;
    esac
done
