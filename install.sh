#!/bin/bash

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

prepare_system() {
    echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
    apt-get update -y || yum update -y
    apt-get install -y curl wget tar uuid-runtime openssl socat || yum install -y curl wget tar libuuid openssl socat
}

enable_bbr_cake() {
    echo -e "${YELLOW}正在配置 BBR + Cake...${PLAIN}"
    # 写入配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}BBR + Cake 配置尝试完成。${PLAIN}"
}

install_xray() {
    echo -e "${YELLOW}正在安装 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

config_xray() {
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SNI="www.microsoft.com"
    
    # 重点修复：确保路径正确，强制使用绝对路径调用 xray 生成密钥
    /usr/local/bin/xray x25519 > /tmp/xray_keys
    PRIV_KEY=$(grep "Private key:" /tmp/xray_keys | awk '{print $3}')
    PUB_KEY=$(grep "Public key:" /tmp/xray_keys | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    # 检查公钥是否成功获取
    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}错误：无法生成 Xray 密钥，请检查 Xray 是否安装成功。${PLAIN}"
        exit 1
    fi

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
                "dest": "$SNI:443",
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

    # 防火墙
    if command -v ufw > /dev/null; then
        ufw allow $PORT/tcp
    elif command -v firewall-cmd > /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
    fi

    systemctl restart xray
    
    # 保存信息
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF
}

build_cli() {
    # 修复 info 命令
    cat <<'EOF' > /usr/bin/info
#!/bin/bash
source /etc/xray_info
IP=$(curl -s ifconfig.me)
echo -e "\033[32m--- Xray Reality 节点信息 ---\033[0m"
echo -e "地址: $IP"
echo -e "端口: $PORT"
echo -e "UUID: $UUID"
echo -e "PublicKey: $PUB_KEY"
echo -e "ShortID: $SHORT_ID"
echo -e "\033[33m--- 分享链接 ---\033[0m"
echo "vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node"
EOF

    # 修复 bbr 命令显示逻辑
    cat <<'EOF' > /usr/bin/bbr
#!/bin/bash
printf "当前拥塞控制算法: "
sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
printf "当前队列算法: "
if [ -f /proc/sys/net/core/default_qdisc ]; then
    sysctl net.core.default_qdisc | awk '{print $3}'
else
    echo "无法读取(可能受限于虚拟化技术)"
fi
EOF

    chmod +x /usr/bin/info /usr/bin/bbr
}

# 运行
prepare_system
enable_bbr_cake
install_xray
config_xray
build_cli
info
