#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 1. 系统预清理
cleanup() {
    echo -e "${YELLOW}正在清理残存文件...${PLAIN}"
    systemctl stop xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/xray_info
    rm -f /usr/bin/info /usr/bin/bbr /usr/bin/update
}

# 2. 安装环境与 Xray
install_core() {
    echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl
    
    echo -e "${YELLOW}正在通过官方脚本安装 Xray...${PLAIN}"
    # 使用强制安装模式
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 3. 核心修复：密钥提取逻辑
generate_config() {
    # 自动定位 Xray
    XRAY_BIN=$(which xray)
    [ -z "$XRAY_BIN" ] && XRAY_BIN="/usr/local/bin/xray"

    echo -e "${YELLOW}正在通过 $XRAY_BIN 生成 Reality 密钥...${PLAIN}"
    
    # 获取原始输出并存入变量
    RAW_KEYS=$($XRAY_BIN x25519 2>&1)
    
    PRIV_KEY=$(echo "$RAW_KEYS" | grep "Private key:" | awk '{print $3}')
    PUB_KEY=$(echo "$RAW_KEYS" | grep "Public key:" | awk '{print $3}')

    # 如果提取失败，尝试第二种匹配方式（部分版本格式可能微调）
    if [ -z "$PUB_KEY" ]; then
        PUB_KEY=$(echo "$RAW_KEYS" | awk -F': ' '/Public key/ {print $2}' | tr -d ' ')
        PRIV_KEY=$(echo "$RAW_KEYS" | awk -F': ' '/Private key/ {print $2}' | tr -d ' ')
    fi

    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}致命错误：无法提取密钥。Xray 输出内容为：${PLAIN}"
        echo "$RAW_KEYS"
        exit 1
    fi

    # 生成其他参数
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
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

    # 开启 BBR + Cake
    echo "net.core.default_qdisc=cake" > /etc/sysctl.d/99-xray.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-xray.conf
    sysctl --system >/dev/null 2>&1

    systemctl restart xray
    
    # 固化信息
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF
}

# 4. 构建管理工具
build_tools() {
    # info 命令
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

    # bbr 命令
    cat <<'EOF' > /usr/bin/bbr
#!/bin/bash
echo -n "拥塞控制: " && sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
echo -n "队列算法: " && sysctl net.core.default_qdisc | awk '{print $3}'
EOF

    chmod +x /usr/bin/info /usr/bin/bbr
}

# 主程序
cleanup
install_core
generate_config
build_tools
echo -e "${GREEN}重装完成！${PLAIN}"
info
