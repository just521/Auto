#!/bin/bash

# ─────────────────────────────────────────────────────────────
#  Xray-Reality 一键全自动安装脚本 (整合优化版)
# ─────────────────────────────────────────────────────────────

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 路径定义
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"
INFO_PATH="/etc/xray_info"

# ─── 权限检查 ───
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！" && exit 1

# ─── 任务执行装饰器 ───
execute_task() {
    local cmd="$1"
    local desc="$2"
    echo -ne "  [执行] $desc... "
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}成功${PLAIN}"
        return 0
    else
        echo -e "${RED}失败${PLAIN}"
        return 1
    fi
}

# ─── 1. 环境清理与准备 ───
prepare_env() {
    echo -e "${CYAN}--- 1. 环境准备 ---${PLAIN}"
    
    # 清理旧锁
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
    
    # 停止旧服务
    systemctl stop xray 2>/dev/null
    
    # 安装必要依赖
    export DEBIAN_FRONTEND=noninteractive
    execute_task "apt-get update -qq && apt-get install -y -qq curl wget tar unzip openssl jq cron ca-certificates chrony lsof" "安装系统依赖"
}

# ─── 2. 核心组件安装 ───
install_core() {
    echo -e "${CYAN}--- 2. 核心安装 ---${PLAIN}"
    
    # 安装 Xray 核心
    local install_cmd="bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install --without-geodata"
    execute_task "$install_cmd" "下载并安装 Xray Core" || { echo "安装失败"; exit 1; }
    
    # 下载 GeoData
    mkdir -p "$XRAY_SHARE_DIR"
    local url_ip="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local url_site="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    
    execute_task "curl -sSL -o $XRAY_SHARE_DIR/geoip.dat $url_ip" "拉取 GeoIP 规则"
    execute_task "curl -sSL -o $XRAY_SHARE_DIR/geosite.dat $url_site" "拉取 GeoSite 规则"
    chmod 644 "$XRAY_SHARE_DIR"/*.dat
}

# ─── 3. 密钥生成 (物理提取优化版) ───
generate_reality_keys() {
    echo -e "${CYAN}--- 3. 密钥生成 ---${PLAIN}"
    local tmp_file="/tmp/xray_keys.txt"
    $XRAY_BIN x25519 > "$tmp_file"
    
    PRIV_KEY=$(grep "Private key:" "$tmp_file" | awk '{print $3}')
    PUB_KEY=$(grep "Public key:" "$tmp_file" | awk '{print $3}')
    
    if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" ]]; then
        echo -e "${RED}密钥生成异常，尝试备选提取方案...${PLAIN}"
        PRIV_KEY=$(sed -n 's/Private key: //p' "$tmp_file")
        PUB_KEY=$(sed -n 's/Public key: //p' "$tmp_file")
    fi
    rm -f "$tmp_file"
    echo -e "  └─ 公钥: ${GREEN}$PUB_KEY${PLAIN}"
}

# ─── 4. 配置生成与系统优化 ───
configure_xray() {
    echo -e "${CYAN}--- 4. 配置与性能优化 ---${PLAIN}"
    
    PORT=$((RANDOM % 45536 + 10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    SNI="www.microsoft.com" # 可根据需要修改为其他符合 Reality 要求的域名

    mkdir -p "$XRAY_CONF_DIR"
    cat <<EOF > "$XRAY_CONF_DIR/config.json"
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $PORT,
        "protocol": "vless",
        "settings": {
            "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$SNI:443",
                "xver": 0,
                "serverNames": ["$SNI"],
                "privateKey": "$PRIV_KEY",
                "shortIds": ["$SHORT_ID"]
            }
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "tag": "direct"
    }]
}
EOF

    # BBR 优化
    echo "net.core.default_qdisc=cake" > /etc/sysctl.d/99-xray-custom.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-xray-custom.conf
    sysctl --system >/dev/null 2>&1
    
    systemctl restart xray
    echo -e "PORT=$PORT\nUUID=$UUID\nPUB_KEY=$PUB_KEY\nSHORT_ID=$SHORT_ID\nSNI=$SNI" > "$INFO_PATH"
}

# ─── 5. 构建快捷 CLI 命令 ───
build_cli() {
    # info 命令
    cat <<'EOF' > /usr/local/bin/xray-info
#!/bin/bash
source /etc/xray_info
IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org)
echo -e "\033[36m==============================\033[0m"
echo -e "\033[32m   Xray Reality 节点配置\033[0m"
echo -e "\033[36m==============================\033[0m"
echo -e " 地址: \033[33m$IP\033[0m"
echo -e " 端口: \033[33m$PORT\033[0m"
echo -e " UUID: \033[33m$UUID\033[0m"
echo -e " 公钥: \033[33m$PUB_KEY\033[0m"
echo -e " SID : \033[33m$SHORT_ID\033[0m"
echo -e " SNI : \033[33m$SNI\033[0m"
echo -e " 流控: \033[33mxtls-rprx-vision\033[0m"
echo -e "\033[36m------------------------------\033[0m"
echo -e "\033[32m 分享链接 (直接复制到客户端):\033[0m"
echo -e "vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node"
EOF

    # 快捷查看 BBR 状态
    echo -e "echo -n '拥塞算法: ' && sysctl net.ipv4.tcp_congestion_control | awk '{print \$3}'\necho -n '队列算法: ' && sysctl net.core.default_qdisc | awk '{print \$3}'" > /usr/local/bin/xray-bbr
    
    chmod +x /usr/local/bin/xray-info /usr/local/bin/xray-bbr
    ln -sf /usr/local/bin/xray-info /usr/bin/info
    ln -sf /usr/local/bin/xray-bbr /usr/bin/bbr
}

# ─── 6. GeoData 自动更新脚本 ───
setup_geodata_cron() {
    local updater="/usr/local/bin/xray-update-geo"
    cat <<EOF > "$updater"
#!/bin/bash
curl -sSL -o $XRAY_SHARE_DIR/geoip.dat.tmp https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
curl -sSL -o $XRAY_SHARE_DIR/geosite.dat.tmp https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
if [ \$(du -k "$XRAY_SHARE_DIR/geoip.dat.tmp" | awk '{print \$1}') -gt 1000 ]; then
    mv "$XRAY_SHARE_DIR/geoip.dat.tmp" "$XRAY_SHARE_DIR/geoip.dat"
    mv "$XRAY_SHARE_DIR/geosite.dat.tmp" "$XRAY_SHARE_DIR/geosite.dat"
    systemctl restart xray
    echo "\$(date) GeoData 更新成功" >> /var/log/xray-geo.log
fi
EOF
    chmod +x "$updater"
    (crontab -l 2>/dev/null | grep -v "xray-update-geo"; echo "0 4 * * 0 $updater >/dev/null 2>&1") | crontab -
}

# ─── 主函数 ───
main() {
    clear
    echo -e "${CYAN}============================================${PLAIN}"
    echo -e "${CYAN}   Xray Reality 自动化安装脚本 (多脚本整合版)${PLAIN}"
    echo -e "${CYAN}============================================${PLAIN}"
    
    prepare_env
    install_core
    generate_reality_keys
    configure_xray
    build_cli
    setup_geodata_cron
    
    echo -e "\n${GREEN}所有组件部署完成！${PLAIN}\n"
    xray-info
}

main
