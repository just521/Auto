#!/bin/bash

# 颜色与权限
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

cleanup() {
    echo -e "${YELLOW}正在清理旧环境...${PLAIN}"
    systemctl stop xray 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/xray_info /usr/bin/info /usr/bin/bbr /usr/bin/update
}

install_all() {
    echo -e "${YELLOW}正在安装依赖与 Xray 核心...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget uuid-runtime openssl
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 核心函数修复：采用物理文件扫描法
generate_keys() {
    echo -e "${YELLOW}正在生成 Reality 密钥对...${PLAIN}"
    XRAY_BIN="/usr/local/bin/xray"
    
    # 将输出重定向到临时文件
    $XRAY_BIN x25519 > /tmp/xray_gen_keys.txt 2>&1
    
    # 从文件中精准提取内容
    # 针对 Private key: 和 PrivateKey: 两种可能的格式做兼容
    PRIV_KEY=$(grep -i "Private" /tmp/xray_gen_keys.txt | cut -d: -f2 | tr -d '[:space:]')
    PUB_KEY=$(grep -i "Public" /tmp/xray_gen_keys.txt | cut -d: -f2 | tr -d '[:space:]')

    # 打印调试（仅在你失败时会看到）
    if [ -z "$PUB_KEY" ] || [ -z "$PRIV_KEY" ]; then
        echo -e "${RED}提取失败！Xray 的原始输出如下：${PLAIN}"
        cat /tmp/xray_gen_keys.txt
        exit 1
    fi
    
    echo -e "${GREEN}密钥生成成功！${PLAIN}"
    rm -f /tmp/xray_gen_keys.txt
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
    # 构建 info 命令
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

    # 构建 bbr 命令
    echo -e "echo -n '拥塞算法: ' && sysctl net.ipv4.tcp_congestion_control | awk '{print \$3}'\necho -n '队列算法: ' && sysctl net.core.default_qdisc | awk '{print \$3}'" > /usr/bin/bbr
    
    chmod +x /usr/bin/info /usr/bin/bbr
}

main() {
    cleanup
    install_all
    generate_keys
    config_xray
    build_cli
    echo -e "${GREEN}所有配置已完成！${PLAIN}"
    info
}

main
