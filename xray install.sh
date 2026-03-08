#!/bin/bash

# ==========================================
# Xray 快速部署脚本 (修复新版 Xray 密钥格式解析)
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
KEY_FILE="${CONFIG_DIR}/public.key"
XRAY_BIN="/usr/local/bin/xray"
SCRIPT_PATH="${CONFIG_DIR}/xray_deploy.sh"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

install_tools() {
    echo -e "${YELLOW}正在安装必要工具...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl wget jq openssl uuid-runtime ufw unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget jq openssl util-linux firewalld unzip
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖。${PLAIN}"
        exit 1
    fi
}

install_xray() {
    echo -e "${YELLOW}正在从 GitHub 获取 Xray-core 最新版本...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        echo -e "${RED}获取 Xray 最新版本失败，请检查网络。${PLAIN}"
        exit 1
    fi
    
    echo -e "${GREEN}找到最新版本: ${LATEST_VERSION}${PLAIN}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-64.zip"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-arm64-v8a.zip"
    else
        echo -e "${RED}不支持的系统架构: $ARCH${PLAIN}"
        exit 1
    fi
    
    wget -O xray.zip "$ZIP_URL"
    if [[ ! -s xray.zip ]]; then
        echo -e "${RED}下载 Xray 失败！${PLAIN}"
        exit 1
    fi

    systemctl stop xray >/dev/null 2>&1
    
    unzip -o xray.zip xray -d /usr/local/bin/
    chmod +x $XRAY_BIN
    rm -f xray.zip

    if [[ ! -x "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray 解压或授权失败，找不到可执行文件！${PLAIN}"
        exit 1
    fi
}

generate_keys() {
    echo -e "${YELLOW}正在生成 UUID 和 X25519 密钥对...${PLAIN}"
    UUID=$(uuidgen)
    if [[ -z "$UUID" ]]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    SHORT_ID=$(openssl rand -hex 8)
    
    KEYS=$($XRAY_BIN x25519 2>/dev/null)
    
    # 兼容新旧版本的 Xray x25519 输出格式
    # 旧版: "Private key: ..." 和 "Public key: ..."
    # 新版: "PrivateKey: ..." 和 "Password: ..." (新版中 Password 实际上就是 Public Key)
    PRIVATE_KEY=$(echo "$KEYS" | grep -iE "Private key|PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -iE "Public key|PublicKey|Password" | awk '{print $NF}')
    
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}X25519 密钥生成或解析失败！${PLAIN}"
        echo -e "请检查 Xray 是否能正常运行。调试输出: \n$KEYS"
        exit 1
    fi
    
    echo "$PUBLIC_KEY" > $KEY_FILE
}

setup_firewall() {
    echo -e "${YELLOW}正在配置防火墙放行端口: $PORT_VISION 和 $PORT_XHTTP...${PLAIN}"
    if command -v ufw > /dev/null 2>&1; then
        ufw allow $PORT_VISION/tcp >/dev/null 2>&1
        ufw allow $PORT_XHTTP/tcp >/dev/null 2>&1
    elif command -v firewall-cmd > /dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=$PORT_VISION/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=$PORT_XHTTP/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT -p tcp --dport $PORT_VISION -j ACCEPT
        iptables -I INPUT -p tcp --dport $PORT_XHTTP -j ACCEPT
    fi
}

setup_shortcuts() {
    echo -e "${YELLOW}正在配置全局精简命令 (info, update, sni)...${PLAIN}"
    mkdir -p $CONFIG_DIR
    cp -f "$(readlink -f "$0")" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    cat > /usr/local/bin/info <<EOF
#!/bin/bash
$SCRIPT_PATH info "\$@"
EOF
    chmod +x /usr/local/bin/info

    cat > /usr/local/bin/update <<EOF
#!/bin/bash
$SCRIPT_PATH update "\$@"
EOF
    chmod +x /usr/local/bin/update

    cat > /usr/local/bin/sni <<EOF
#!/bin/bash
$SCRIPT_PATH sni "\$@"
EOF
    chmod +x /usr/local/bin/sni
}

install_all() {
    check_root
    install_tools
    mkdir -p $CONFIG_DIR
    install_xray
    generate_keys
    
    PORT_VISION=$(shuf -i 10000-65535 -n 1)
    PORT_XHTTP=$(shuf -i 10000-65535 -n 1)
    while [[ "$PORT_VISION" == "$PORT_XHTTP" ]]; do
        PORT_XHTTP=$(shuf -i 10000-65535 -n 1)
    done
    
    DEFAULT_SNI="www.microsoft.com"
    
    cat > $CONFIG_FILE <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT_VISION,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEFAULT_SNI}:443",
          "xver": 0,
          "serverNames": [ "${DEFAULT_SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      }
    },
    {
      "port": $PORT_XHTTP,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEFAULT_SNI}:443",
          "xver": 0,
          "serverNames": [ "${DEFAULT_SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        },
        "xhttpSettings": { "mode": "auto", "path": "/" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF

    setup_firewall
    
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl start xray
    
    setup_shortcuts
    
    echo -e "${GREEN}================================================${PLAIN}"
    echo -e "${GREEN}Xray 部署完成！已为您配置全局精简命令。${PLAIN}"
    echo -e "您现在可以在终端的任何地方直接输入以下命令："
    echo -e "  ${YELLOW}info${PLAIN}                 - 查看节点信息与分享链接"
    echo -e "  ${YELLOW}sni www.apple.com${PLAIN}    - 更改伪装域名"
    echo -e "  ${YELLOW}update${PLAIN}               - 升级 Xray 核心"
    echo -e "${GREEN}================================================${PLAIN}"
    
    show_info
}

show_info() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到配置文件，请先运行 install 命令。${PLAIN}"
        exit 1
    fi
    
    IP=$(curl -s ifconfig.me)
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
    PORT_VISION=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    PORT_XHTTP=$(jq -r '.inbounds[1].port' $CONFIG_FILE)
    SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
    PUBLIC_KEY=$(cat $KEY_FILE)
    
    LINK_VISION="vless://${UUID}@${IP}:${PORT_VISION}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Vision"
    LINK_XHTTP="vless://${UUID}@${IP}:${PORT_XHTTP}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#Xray-XHTTP"
    
    echo -e ""
    echo -e "${GREEN}================ Xray 节点信息 =================${PLAIN}"
    echo -e "服务器 IP: ${IP}"
    echo -e "UUID:      ${UUID}"
    echo -e "SNI 域名:  ${SNI}"
    echo -e "Public Key:${PUBLIC_KEY}"
    echo -e "Short ID:  ${SHORT_ID}"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}[节点 1] VLESS + Vision + Reality (端口: ${PORT_VISION})${PLAIN}"
    echo -e "${LINK_VISION}"
    echo -e "------------------------------------------------"
    echo -e "${YELLOW}[节点 2] VLESS + xhttp + Reality (端口: ${PORT_XHTTP})${PLAIN}"
    echo -e "${LINK_XHTTP}"
    echo -e "${GREEN}================================================${PLAIN}"
}

update_xray() {
    check_root
    install_xray
    systemctl restart xray
    echo -e "${GREEN}Xray 核心已更新并重启。当前版本：${PLAIN}"
    $XRAY_BIN version
}

change_sni() {
    check_root
    NEW_SNI=$1
    if [[ -z "$NEW_SNI" ]]; then
        echo -e "${RED}请提供新的 SNI 域名，例如: sni www.apple.com${PLAIN}"
        exit 1
    fi
    
    if jq --arg sni "$NEW_SNI" '
        .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443") |
        .inbounds[0].streamSettings.realitySettings.serverNames[0] = $sni |
        .inbounds[1].streamSettings.realitySettings.dest = ($sni + ":443") |
        .inbounds[1].streamSettings.realitySettings.serverNames[0] = $sni
    ' $CONFIG_FILE > ${CONFIG_FILE}.tmp; then
        mv ${CONFIG_FILE}.tmp $CONFIG_FILE
        systemctl restart xray
        echo -e "${GREEN}SNI 已成功更改为 $NEW_SNI 并重启服务。${PLAIN}"
        show_info
    else
        echo -e "${RED}修改配置文件失败！${PLAIN}"
        rm -f ${CONFIG_FILE}.tmp
    fi
}

case "$1" in
    install) install_all ;;
    info)    show_info ;;
    update)  update_xray ;;
    sni)     change_sni "$2" ;;
    *)
        echo -e "Xray 部署脚本使用说明:"
        echo -e "  ${GREEN}$0 install${PLAIN}      - 一键安装并配置 (安装后可使用下方精简命令)"
        echo -e "------------------------------------------------"
        echo -e "全局精简命令 (安装完成后可用):"
        echo -e "  ${GREEN}info${PLAIN}                 - 查看生成的节点信息与分享链接"
        echo -e "  ${GREEN}update${PLAIN}               - 升级 Xray 核心到最新版本"
        echo -e "  ${GREEN}sni <domain>${PLAIN}         - 更改 Reality 的 SNI 伪装域名"
        ;;
esac
