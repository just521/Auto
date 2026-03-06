#!/bin/bash

# 1. 颜色与权限
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 2. Xray 密钥生成函数 (核心修复)
generate_keys() {
    echo -e "${YELLOW}尝试提取 Reality 密钥对...${PLAIN}"
    
    # 强制尝试两个可能的路径
    if [ -f "/usr/local/bin/xray" ]; then
        XRAY="/usr/local/bin/xray"
    else
        XRAY=$(which xray)
    fi

    # 打印测试
    echo "使用 Xray 路径: $XRAY"
    
    # 关键：直接运行并将结果存入变量
    local temp_output
    temp_output=$($XRAY x25519 2>&1)
    
    # 从变量中提取
    PRIV_KEY=$(echo "$temp_output" | grep "Private key:" | awk '{print $3}')
    PUB_KEY=$(echo "$temp_output" | grep "Public key:" | awk '{print $3}')

    if [ -z "$PUB_KEY" ]; then
        echo -e "${RED}无法生成密钥。Xray 运行报错如下：${PLAIN}"
        echo "--------------------------------------"
        echo "$temp_output"
        echo "--------------------------------------"
        exit 1
    fi
}

# 3. 安装与配置
main() {
    # 安装必要工具
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl
    
    # 安装/更新 Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    # 生成密钥
    generate_keys

    # 随机参数
    PORT=$((RANDOM % 55536 + 10000))
    UUID=$(uuidgen)
    SNI="www.microsoft.com"
    SHORT_ID=$(openssl rand -hex 8)

    # 写入配置
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

    # 重启并保存
    systemctl restart xray
    cat <<EOF > /etc/xray_info
PORT=$PORT
UUID=$UUID
PUB_KEY=$PUB_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
EOF

    # 构建常用命令
    echo -e "source /etc/xray_info\nIP=\$(curl -s ifconfig.me)\necho -e \"\\\\n端口: \$PORT\\\\nUUID: \$UUID\\\\nPublicKey: \$PUB_KEY\\\\nShortID: \$SHORT_ID\"\necho \"vless://\$UUID@\$IP:\$PORT?security=reality&sni=\$SNI&fp=chrome&pbk=\$PUB_KEY&sid=\$SHORT_ID&flow=xtls-rprx-vision&type=tcp#Reality_Node\"" > /usr/bin/info
    
    echo -e "sysctl net.ipv4.tcp_congestion_control\nsysctl net.core.default_qdisc" > /usr/bin/bbr
    
    chmod +x /usr/bin/info /usr/bin/bbr

    echo -e "${GREEN}安装完成！${PLAIN}"
    info
}

main
