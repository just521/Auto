#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 1. 环境准备与工具安装
prepare_system() {
    echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
    apt-get update -y || yum update -y
    apt-get install -y curl wget tar uuid-runtime openssl socat || yum install -y curl wget tar libuuid openssl socat
}

# 2. 安装 BBR + Cake
enable_bbr_cake() {
    echo -e "${YELLOW}正在配置 BBR + Cake...${PLAIN}"
    if ! grep -q "net.core.default_qdisc=cake" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo -e "${GREEN}BBR + Cake 已激活。${PLAIN}"
}

# 3. 安装 Xray 核心
install_xray() {
    echo -e "${YELLOW}正在下载并安装 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 4. 生成 Reality 配置
config_xray() {
    # 随机生成高位端口 (10000-65535)
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    DEST="www.microsoft.com:443"
    SNI="www.microsoft.com"
    
    # 生成 X25519 密钥对
    KEYS=$(xray x25519)
    PRIV_KEY=$(echo "$KEYS" | awk '/Private key:/ {print $3}')
    PUB_KEY=$(echo "$KEYS" | awk '/Public key:/ {print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    cat <<EOF > /usr/local/etc/xray/config.json
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
                "dest": "$DEST",
                "xver": 0,
                "serverNames": ["$SNI"],
                "privateKey": "$PRIV_KEY",
                "shortIds": ["$SHORT_ID"]
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # 自动放行端口
    if command -v ufw > /dev/null; then
        ufw allow $PORT/tcp
    elif command -v firewall-cmd > /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
    fi

    systemctl restart xray
    
    # 保存信息用于 info 命令
    echo "PORT=$PORT" > /etc/xray_info
    echo "UUID=$UUID" >> /etc/xray_info
    echo "PUB_KEY=$PUB_KEY" >> /etc/xray_info
    echo "SHORT_ID=$SHORT_ID" >> /etc/xray_info
    echo "SNI=$SNI" >> /etc/xray_info
}

# 5. 构建管理命令
build_cli() {
    cat <<EOF > /usr/bin/info
#!/bin/bash
source /etc/xray_info
IP=\$(curl -s ifconfig.me)
echo -e "\033[32m--- Xray Reality 节点信息 ---\033[0m"
echo -e "地址: \$IP"
echo -e "端口: \$PORT"
echo -e "UUID: \$UUID"
echo -e "流控: xtls-rprx-vision"
echo -e "传输: tcp"
echo -e "安全: reality"
echo -e "SNI: \$SNI"
echo -e "PublicKey: \$PUB_KEY"
echo -e "ShortID: \$SHORT_ID"
echo -e "Fingerprint: chrome"
echo -e "\033[33m--- 分享链接 ---\033[0m"
echo "vless://\$UUID@\$IP:\$PORT?security=reality&sni=\$SNI&fp=chrome&pbk=\$PUB_KEY&sid=\$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node"
EOF

    cat <<EOF > /usr/bin/update
#!/bin/bash
bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl restart xray
echo "Xray 内核更新完成。"
EOF

    cat <<EOF > /usr/bin/bbr
#!/bin/bash
echo -n "当前拥塞控制算法: "
sysctl net.ipv4.tcp_congestion_control | awk '{print \$3}'
echo -n "当前队列算法: "
sysctl net.core.default_qdisc | awk '{print \$3}'
EOF

    chmod +x /usr/bin/info /usr/bin/update /usr/bin/bbr
}

# 主程序
main() {
    prepare_system
    enable_bbr_cake
    install_xray
    config_xray
    build_cli
    
    echo -e "${GREEN}安装完成！${PLAIN}"
    echo -e "输入 ${YELLOW}info${PLAIN} 查看节点信息"
    echo -e "输入 ${YELLOW}update${PLAIN} 更新内核"
    echo -e "输入 ${YELLOW}bbr${PLAIN} 查看加速状态"
    info
}

main
