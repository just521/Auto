#!/bin/bash

# 1. 颜色与权限检查
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 2. 准备工作
prepare_system() {
    apt-get update -y || yum update -y
    apt-get install -y curl wget tar uuid-runtime openssl socat || yum install -y curl wget tar libuuid openssl socat
}

# 3. 安装 Xray
install_xray() {
    echo -e "${YELLOW}正在安装/检查 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 4. 生成 Reality 密钥 (增强型)
config_xray() {
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SNI="www.microsoft.com"
    SHORT_ID=$(openssl rand -hex 8)

    # 自动查找 Xray 路径
    XRAY_BIN=$(which xray)
    [ -z "$XRAY_BIN" ] && XRAY_BIN="/usr/local/bin/xray"

    if [ ! -x "$XRAY_BIN" ]; then
        echo -e "${RED}错误：找不到可执行的 Xray 二进制文件！${PLAIN}"
        exit 1
    fi

    # 核心修复：合并标准输出和错误输出，确保能抓到 key
    echo -e "${YELLOW}正在生成密钥对...${PLAIN}"
    $XRAY_BIN x25519 > /tmp/xray_keys.txt 2>&1
    
    PRIV_KEY=$(grep "Private key:" /tmp/xray_keys.txt | awk '{print $3}')
    PUB_KEY=$(grep "Public key:" /tmp/xray_keys.txt | awk '{print $3}')

    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}无法生成密钥。手动输出调试信息：${PLAIN}"
        cat /tmp/xray_keys.txt
        exit 1
    fi

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

    # 防火墙
    if command -v ufw > /dev/null; then
        ufw allow $PORT/tcp
    elif command -v firewall-cmd > /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
    fi

    systemctl restart xray
    
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF
}

build_cli() {
    # 构建 info 命令 (增加流控和指纹显示)
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
echo -e "流控: xtls-rprx-vision"
echo -e "指纹: chrome"
echo -e "\033[33m--- 分享链接 ---\033[0m"
echo "vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node"
EOF
    chmod +x /usr/bin/info
}

# 主程序
main() {
    prepare_system
    install_xray
    config_xray
    build_cli
    echo -e "${GREEN}安装成功！${PLAIN}"
    info
}

main
