#!/bin/bash

# 颜色与权限
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 1. 清理
cleanup() {
    echo -e "${YELLOW}清理旧环境...${PLAIN}"
    systemctl stop xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/xray_info /usr/bin/info /usr/bin/bbr /usr/bin/update
}

# 2. 安装
install_all() {
    echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl coreutils
    echo -e "${YELLOW}正在安装 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 3. 核心：使用 OpenSSL 生成 x25519 密钥 (不再依赖 xray 输出)
generate_config() {
    echo -e "${YELLOW}正在通过 OpenSSL 生成 Reality 密钥对...${PLAIN}"
    
    # 生成私钥 (Base64格式)
    PRIV_KEY=$(openssl genpkey -algorithm x25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    
    # 使用 Xray 根据私钥推导公钥 (这是最稳妥的办法)
    PUB_KEY=$(/usr/local/bin/xray x25519 -i "$PRIV_KEY" | grep "Public key:" | awk '{print $3}')

    # 兜底：如果 Xray 连推导都报错，则提示
    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}致命错误：密钥推导失败。请检查 /usr/local/bin/xray 是否可用。${PLAIN}"
        exit 1
    fi

    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    SNI="www.microsoft.com"

    # 写入 JSON
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
    echo -e "${YELLOW}优化 BBR + Cake...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    systemctl restart xray
    
    # 保存数据
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF
}

# 4. 构建常用命令
build_cli() {
    # info 命令
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

    # bbr 命令
    cat <<'EOF' > /usr/bin/bbr
#!/bin/bash
echo -n "拥塞算法: " && sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
echo -n "队列算法: " && sysctl net.core.default_qdisc | awk '{print $3}'
EOF

    # update 命令
    cat <<'EOF' > /usr/bin/update
#!/bin/bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl restart xray
echo "更新完成。"
EOF

    chmod +x /usr/bin/info /usr/bin/bbr /usr/bin/update
}

# 运行程序
main() {
    cleanup
    install_all
    generate_config
    build_cli
    echo -e "${GREEN}安装成功！${PLAIN}"
    info
}

main
