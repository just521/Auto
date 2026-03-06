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

# 3. 安装 Xray (先安装，后生成密钥)
install_xray() {
    echo -e "${YELLOW}正在安装 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    sleep 2 # 等待文件写入
}

# 4. 修复的关键：生成并捕获 Reality 密钥
config_xray() {
    # 随机参数
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SNI="www.microsoft.com"
    SHORT_ID=$(openssl rand -hex 8)

    # 重点：通过临时文件捕获密钥对，并使用绝对路径
    XRAY_BIN="/usr/local/bin/xray"
    if [ ! -f "$XRAY_BIN" ]; then
        XRAY_BIN=$(which xray)
    fi

    # 尝试生成密钥
    $XRAY_BIN x25519 > /tmp/xray_keys.txt
    PRIV_KEY=$(grep "Private key:" /tmp/xray_keys.txt | awk '{print $3}')
    PUB_KEY=$(grep "Public key:" /tmp/xray_keys.txt | awk '{print $3}')

    # 如果还是空的，手动抛出错误停止，不生成错误的节点
    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}致命错误：无法提取 PublicKey。请检查 /usr/local/bin/xray 是否存在。${PLAIN}"
        exit 1
    fi

    # 写入 JSON 配置
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
    
    # 固化信息到文件以便 info 命令读取
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF
}

# 5. 构建命令
build_cli() {
    # 构建 info 命令
    cat <<'EOF' > /usr/bin/info
#!/bin/bash
if [ ! -f /etc/xray_info ]; then echo "未发现配置文件"; exit 1; fi
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
    chmod +x /usr/bin/info
}

# 主程序顺序调整：先安装环境 -> 安装Xray -> 再生成配置
main() {
    prepare_system
    install_xray
    config_xray
    build_cli
    echo -e "${GREEN}安装成功！${PLAIN}"
    info
}

main
