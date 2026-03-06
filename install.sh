#!/bin/bash

# 颜色与权限
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

cleanup() {
    echo -e "${YELLOW}清理旧环境...${PLAIN}"
    systemctl stop xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/xray_info /usr/bin/info /usr/bin/bbr /usr/bin/update
}

install_all() {
    echo -e "${YELLOW}安装依赖与 Xray 核心...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 核心函数：不再依赖 Xray 提取，改用 OpenSSL 生成标准 Reality 密钥
generate_reality_keys() {
    echo -e "${YELLOW}正在通过 OpenSSL 独立生成 Reality 密钥对...${PLAIN}"
    
    # 1. 生成 32 字节私钥并进行 Base64URL 编码 (Reality 标准)
    openssl genpkey -algorithm x25519 -out /tmp/x_priv.pem 2>/dev/null
    PRIV_KEY=$(openssl pkey -in /tmp/x_priv.pem -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    
    # 2. 从私钥推导公钥 (使用 Xray 内部转换，这是最后一次调用它)
    # 如果这一步还失败，说明二进制文件有问题
    PUB_KEY=$(/usr/local/bin/xray x25519 -i "$PRIV_KEY" | grep "Public key:" | awk '{print $3}')
    
    # 3. 终极自检
    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}密钥推导失败！尝试直接从 OpenSSL 提取...${PLAIN}"
        # 备用推导方案
        PUB_KEY=$(openssl pkey -in /tmp/x_priv.pem -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    fi
    
    rm -f /tmp/x_priv.pem
}

config_xray() {
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    SNI="www.microsoft.com"

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

    # BBR + Cake 
    echo "net.core.default_qdisc=cake" > /etc/sysctl.d/99-xray.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-xray.conf
    sysctl --system >/dev/null 2>&1
    
    systemctl restart xray
    echo -e "PORT=$PORT\nUUID=$UUID\nPUB_KEY=$PUB_KEY\nSHORT_ID=$SHORT_ID\nSNI=$SNI" > /etc/xray_info
}

build_cli() {
    cat <<'EOF' > /usr/bin/info
#!/bin/bash
source /etc/xray_info
IP=$(curl -s ifconfig.me)
echo -e "\033[32m--- Xray Reality 节点信息 ---\033[0m"
echo -e "地址: $IP  端口: $PORT"
echo -e "UUID: $UUID"
echo -e "PublicKey: $PUB_KEY"
echo -e "ShortID: $SHORT_ID"
echo -e "\033[33m--- 分享链接 ---\033[0m"
echo "vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node"
EOF

    cat <<'EOF' > /usr/bin/bbr
#!/bin/bash
echo -n "拥塞算法: " && sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
echo -n "队列算法: " && sysctl net.core.default_qdisc | awk '{print $3}'
EOF
    
    chmod +x /usr/bin/info /usr/bin/bbr
}

# 主程序
main() {
    cleanup
    install_all
    generate_reality_keys
    config_xray
    build_cli
    echo -e "${GREEN}安装成功！${PLAIN}"
    info
}

main
