#!/bin/bash

# ─────────────────────────────────────────────
#  Xray WARP 分流管理
#  策略：默认走本机 IP，仅指定域名走 WARP
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
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 sudo 运行此脚本！${PLAIN}"; exit 1; fi
if ! command -v jq &>/dev/null; then apt update && apt install -y jq; fi

# ─── 状态检测函数 ────────────────────────────
check_warp_socket() { (echo > /dev/tcp/127.0.0.1/$WARP_PORT) >/dev/null 2>&1; }

wait_for_port() {
    for i in {1..15}; do
        if check_warp_socket; then return 0; fi
        sleep 1
    done
    return 1
}

get_warp_rules() {
    [ ! -f "$CONFIG_FILE" ] && return
    jq -r '.routing.rules[] | select(.outboundTag=="warp_proxy") | .domain[]' "$CONFIG_FILE" 2>/dev/null
}

# ─── 核心逻辑：重组配置文件 ──────────────────
rebuild_config_logic() {
    [ ! -f "$CONFIG_FILE" ] && return

    # 1. 重新构造 outbounds 数组：确保 freedom (direct_out) 是第一个，即默认出口
    jq '(.outbounds | map(select(.tag != "direct_out" and .tag != "warp_proxy"))) as $others |
        [
          {"tag": "direct_out", "protocol": "freedom", "settings": {}},
          {"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_PORT'}]}}
        ] + $others' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 2. 开启域名匹配策略
    jq '.routing.domainStrategy = "IPIfNonMatch"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

apply_changes() {
    systemctl restart xray >/dev/null 2>&1
}

# 1. 安装/重装
install_warp() {
    clear
    echo -e "\n${CYAN}正在自动安装 WARP 并配置本机 IP 优先...${PLAIN}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh c
    if wait_for_port; then
        rebuild_config_logic
        apply_changes
        UI_MESSAGE="${GREEN}安装成功！当前默认走本机 IP，分流域名走 WARP。${PLAIN}"
    else
        UI_MESSAGE="${RED}安装后启动超时，请检查服务状态。${PLAIN}"
    fi
}

# 2. 卸载
uninstall_warp() {
    clear
    echo -e "\n${RED}正在卸载 WARP 并恢复纯净配置...${PLAIN}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh u
    jq 'del(.outbounds[] | select(.tag=="warp_proxy")) | del(.routing.rules[] | select(.outboundTag=="warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    apply_changes
    UI_MESSAGE="${GREEN}卸载及规则清理完毕。${PLAIN}"
}

# 3. 分流管理
manage_custom_rule() {
    if ! check_warp_socket; then UI_MESSAGE="${RED}错误：WARP 未运行，无法配置分流！${PLAIN}"; return; fi
    echo -e "\n${CYAN}请输入要走 WARP 的域名标签 (例如 geosite:google 或 domain:openai.com)${PLAIN}"
    read -p "输入已存在则删除，不存在则添加: " user_input
    [ -z "$user_input" ] && return

    rebuild_config_logic

    local exists=$(jq -r --arg target "$user_input" '.routing.rules[] | select(.outboundTag=="warp_proxy" and (.domain[]? == $target)) | .outboundTag' "$CONFIG_FILE" 2>/dev/null)
    
    if [ -n "$exists" ]; then
        jq --arg target "$user_input" '.routing.rules |= map(if .outboundTag == "warp_proxy" then .domain |= map(select(. != $target)) else . end) | .routing.rules |= map(select(.domain != [] or .outboundTag != "warp_proxy"))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        UI_MESSAGE="${YELLOW}已移除分流: $user_input${PLAIN}"
    else
        local has_warp_rule=$(jq '.routing.rules[] | select(.outboundTag=="warp_proxy")' "$CONFIG_FILE")
        if [ -z "$has_warp_rule" ]; then
            local new_rule="{\"type\": \"field\", \"domain\": [\"$user_input\"], \"outboundTag\": \"warp_proxy\"}"
            jq --argjson rule "$new_rule" '.routing.rules = [$rule] + .routing.rules' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        else
            jq --arg target "$user_input" '(.routing.rules[] | select(.outboundTag=="warp_proxy")).domain += [$target]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        UI_MESSAGE="${GREEN}已添加分流: $user_input${PLAIN}"
    fi
    apply_changes
}

# 4. 开关
toggle_warp() {
    if check_warp_socket; then
        systemctl stop warp >/dev/null 2>&1
        UI_MESSAGE="${YELLOW}WARP 服务已停止${PLAIN}"
    else
        systemctl start warp >/dev/null 2>&1
        if wait_for_port; then
            UI_MESSAGE="${GREEN}WARP 服务已启动${PLAIN}"
        else
            UI_MESSAGE="${RED}启动失败，请确认是否已安装 WARP${PLAIN}"
        fi
    fi
}

# ─── 菜单界面 ────────────────────────────────
show_menu() {
    clear
    # 检测 WARP 状态
    if check_warp_socket; then 
        STATUS_SOCK="${GREEN}● 运行中${PLAIN}"
        local trace=$(curl -s4m 2 --socks5 127.0.0.1:$WARP_PORT https://www.cloudflare.com/cdn-cgi/trace)
        WARP_IP=$(echo "$trace" | grep "ip=" | cut -d= -f2)
        WARP_LOC=$(echo "$trace" | grep "loc=" | cut -d= -f2)
        TOGGLE_TEXT="关闭 WARP 服务"
    else 
        STATUS_SOCK="${RED}● 已停止${PLAIN}"
        WARP_IP=""; WARP_LOC=""
        TOGGLE_TEXT="开启 WARP 服务"
    fi

    # 检测 Xray 状态
    if systemctl is-active xray &>/dev/null; then
        STATUS_XRAY="${GREEN}● 已连接${PLAIN}"
    else
        STATUS_XRAY="${RED}● 未连接${PLAIN}"
    fi

    # 获取当前分流规则
    local current_rules=$(get_warp_rules | tr '\n' ' ' | sed 's/ $//')
    [ -z "$current_rules" ] && current_rules="${GRAY}无 (全部走本机IP)${PLAIN}"

    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "           Xray WARP 分流管理         "
    echo -e "${CYAN}===================================================${PLAIN}"
    echo -e "  WARP 状态: ${STATUS_SOCK}"
    echo -e "  Xray 接口: ${STATUS_XRAY}"
    echo -e "  WARP IP  : ${GREEN}${WARP_IP:-N/A}${PLAIN} (${WARP_LOC:-N/A})"
    echo -e "  归 属 地 : ${GREEN}${WARP_LOC:-N/A}${PLAIN}"
    echo -e "  分流域名 : ${YELLOW}${current_rules}${PLAIN}"
    echo -e "  默认出口 : ${CYAN}VPS 本机原生 IP${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e "  1. 安装/重装 WARP (自动优选节点)"
    echo -e "  2. 卸载/清理 WARP 及所有分流规则"
    echo -e "  3. 添加/删除 自定义分流域名 (命中则走 WARP)"
    echo -e "  4. ${YELLOW}${TOGGLE_TEXT}${PLAIN}"
    echo -e "---------------------------------------------------"
    echo -e "  0. 退出"
    echo -e "==================================================="
    if [ -n "$UI_MESSAGE" ]; then echo -e "${YELLOW}提示${PLAIN}: ${UI_MESSAGE}"; UI_MESSAGE=""; fi
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
        4) toggle_warp ;;
        0) exit 0 ;;
        *) UI_MESSAGE="${RED}无效输入！${PLAIN}" ;;
    esac
done
