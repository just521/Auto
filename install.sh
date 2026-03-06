#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 1. 深度清理函数
cleanup() {
    echo -e "${YELLOW}正在深度清理旧残留文件...${PLAIN}"
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray
    rm -rf /etc/systemd/system/xray*
    rm -f /usr/bin/info /usr/bin/bbr /usr/bin/update
    rm -f /etc/xray_info /tmp/xray_keys.txt
    systemctl daemon-reload
    echo -e "${GREEN}清理完成。${PLAIN}"
}

# 2. 系统环境准备
prepare_system() {
    echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}"
    apt-get update -y || yum update -y
    apt-get install -y curl wget uuid-runtime openssl socat tar unzip || yum install -y curl wget libuuid openssl socat tar unzip
}

# 3. 安装 Xray 核心
install_xray() {
    echo -e "${YELLOW}正在安装最新版 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    sleep 1
}

# 4. 核心配置与密钥生成
config_xray() {
    XRAY_BIN="/usr/local/bin/xray"
    echo -e "${YELLOW}正在生成 Reality 密钥对...${PLAIN}"
    
    # 强制捕获 x25519 密钥对输出
    local key_output
    key_output=$($XRAY_BIN x25519 2>&1)
    
    # 使用正则表达式提取，增强兼容性
    PRIV_KEY=$(echo "$key_output" | grep "Private key:" | awk '{print $3}')
    PUB_KEY=$(echo "$key_output" | grep "Public key:" | awk '{print $3}')

    # 容错提取：如果 awk $3 失败，尝试提取最后一列
    if [ -z "$PUB_KEY" ]; then
        PRIV_KEY=$(echo "$key_output" | awk -F': ' '/Private key/ {print $2}' | xargs)
        PUB_KEY=$(echo "$key_output" | awk -F': ' '/Public key/ {print $2}' | xargs)
    fi

    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}致命错误：无法提取密钥。输出内容如下：${PLAIN}"
        echo "$key_output"
        exit 1
    fi

    # 随机化参数
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    SNI="www.microsoft.com"

    # 写入 JSON 配置文件
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

    # 端口放行
    if command -v ufw > /dev/null; then
        ufw allow $PORT/tcp
    elif command -v firewall-cmd > /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
    fi

    # 开启 BBR + Cake
    echo -e "${YELLOW}配置 BBR + Cake 加速...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    systemctl restart xray
    
    # 固化数据以备 info 调用
    echo "PORT=$PORT" > /etc/xray_info
    echo "UUID=$UUID" >> /etc/xray_info
    echo "PUB_KEY=$PUB_KEY" >> /etc/xray_info
    echo "SHORT_ID=$SHORT_ID" >> /etc/xray_info
    echo "SNI=$SNI" >> /etc/xray_info
}

# 5. 构建命令工具
build_commands() {
    # info
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

    # bbr
    cat <<'EOF' > /usr/bin/bbr
#!/bin/bash
echo -n "拥塞算法: " && sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
echo -n "队列算法: " && sysctl net.core.default_qdisc | awk '{print $3}'
EOF

    # update
    cat <<'EOF' > /usr/bin/update
#!/bin/bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl restart xray
echo "Xray 内核更新成功！"
EOF

    chmod +x /usr/bin/info /usr/bin/bbr /usr/bin/update
}

# 执行流程
main() {
    cleanup
    prepare_system
    install_xray
    config_xray
    build_commands
    echo -e "${GREEN}全部安装并优化完成！${PLAIN}"
    info
}

main
