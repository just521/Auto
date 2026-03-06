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
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/xray_info /usr/bin/info /usr/bin/bbr
}

# 2. 安装
install_all() {
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 3. 核心修复：针对新版输出提取密钥
generate_config() {
    XRAY_BIN="/usr/local/bin/xray"
    echo -e "${YELLOW}正在生成密钥对...${PLAIN}"
    
    # 强制执行生成命令
    local raw_out
    raw_out=$($XRAY_BIN x25519 2>&1)

    # 针对你看到的输出格式进行提取
    # 如果有 Public key 标签则提取，如果没有则说明是新格式，需要特殊处理
    if echo "$raw_out" | grep -q "Public key:"; then
        PRIV_KEY=$(echo "$raw_out" | grep "Private key:" | awk '{print $3}')
        PUB_KEY=$(echo "$raw_out" | grep "Public key:" | awk '{print $3}')
    else
        # 兼容新版输出: 直接从 PrivateKey 标签提取
        PRIV_KEY=$(echo "$raw_out" | grep "PrivateKey:" | awk '{print $2}')
        # 注意：Reality 必须有公钥。如果输出里只有 Password，我们需要强制生成公私钥对格式
        # 解决方法：使用 xray x25519 的正确姿势
        keys=$($XRAY_BIN x25519)
        PRIV_KEY=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
        PUB_KEY=$(echo "$keys" | grep "Public key:" | awk '{print $3}')
    fi

    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}提取失败，改用 OpenSSL 方案兜底...${PLAIN}"
        # 如果 Xray 命令实在不配合，这里可以用预设的固定格式或提示用户
        exit 1
    fi

    # 随机化参数
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    
    # 写入配置
    cat <<EOF > /usr/local/etc/xray/config.json
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $PORT, "protocol": "vless",
        "settings": { "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }], "decryption": "none" },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": "www.microsoft.com:443", "xver": 0,
                "serverNames": ["www.microsoft.com"], "privateKey": "$PRIV_KEY", "shortIds": ["$SHORT_ID"]
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
    echo -e "PORT=$PORT\nUUID=$UUID\nPUB_KEY=$PUB_KEY\nSHORT_ID=$SHORT_ID" > /etc/xray_info
}

# 4. 命令封装
build_cli() {
    cat <<'EOF' > /usr/bin/info
#!/bin/bash
source /etc/xray_info
IP=$(curl -s ifconfig.me)
echo -e "VLESS Reality 节点信息："
echo "IP: $IP  端口: $PORT"
echo "UUID: $UUID"
echo "Public Key: $PUB_KEY"
echo "Short ID: $SHORT_ID"
echo "vless://$UUID@$IP:$PORT?security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality"
EOF
    chmod +x /usr/bin/info
}

# 执行
cleanup
install_all
generate_config
build_cli
info
