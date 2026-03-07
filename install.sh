#!/bin/bash

# ====================================================
# Project: Xray-Reality-Modular-Deploy
# Architecture: Core / Lib / Tools / Configs
# ====================================================

# --- 基础路径定义 ---
BASE_DIR="/usr/local/etc/xray-deploy"
XRAY_CONF="/usr/local/etc/xray/config.json"

# --- 0. 创建目录结构 ---
mkdir -p $BASE_DIR/{core,lib,tools,configs/templates}
mkdir -p /usr/local/etc/xray

# --- 1. 写入 lib/utils.sh (工具类) ---
cat <<'EOF' > $BASE_DIR/lib/utils.sh
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
OK="${GREEN}[OK]${PLAIN}"
INFO="${CYAN}[INFO]${PLAIN}"
ERR="${RED}[ERROR]${PLAIN}"

log_info() { echo -e "${INFO} $1"; }
log_error() { echo -e "${ERR} $1"; exit 1; }
EOF

# --- 2. 写入 core/xray.sh (安装模块) ---
cat <<'EOF' > $BASE_DIR/core/xray.sh
install_xray_core() {
    echo -e "${CYAN}--- 安装/更新 Xray 核心 ---${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}
EOF

# --- 3. 写入 core/config.sh (配置生成模块) ---
cat <<'EOF' > $BASE_DIR/core/config.sh
generate_xray_config() {
    source /usr/local/etc/xray-deploy/lib/utils.sh
    log_info "正在生成 Xray 配置文件..."

    XRAY_BIN="/usr/local/bin/xray"
    UUID=$("$XRAY_BIN" uuid)
    keys_output=$("$XRAY_BIN" x25519)
    PRIVATE_KEY=$(echo "$keys_output" | grep -iE "^PrivateKey:" | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo  "$keys_output" | grep -iE "^(PublicKey|Password):" | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
    SHORT_ID=$(openssl rand -hex 4)
    XHTTP_PATH="/$(openssl rand -hex 4)"
    SNI_HOST="www.icloud.com"

    cat > /usr/local/etc/xray/config.json <<EOC
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vision_node", "port": ${PORT_VISION:-443}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "show": false, "dest": "${SNI_HOST}:443", "serverNames": ["${SNI_HOST}"], "privateKey": "${PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"], "fingerprint": "chrome" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }
    },
    {
      "tag": "xhttp_node", "port": ${PORT_XHTTP:-8443}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "reality", "xhttpSettings": { "path": "${XHTTP_PATH}" },
        "realitySettings": { "show": false, "dest": "${SNI_HOST}:443", "serverNames": ["${SNI_HOST}"], "privateKey": "${PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"], "fingerprint": "chrome" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOC
    # 保存关键变量供 info 命令使用
    echo "UUID=$UUID" > $BASE_DIR/configs/current.info
    echo "PBK=$PUBLIC_KEY" >> $BASE_DIR/configs/current.info
    echo "SID=$SHORT_ID" >> $BASE_DIR/configs/current.info
    echo "XPATH=$XHTTP_PATH" >> $BASE_DIR/configs/current.info
}
EOF

# --- 4. 写入 tools/sni_finder.sh (SNI 优选模块) ---
cat <<'EOF' > $BASE_DIR/tools/sni_finder.sh
optimize_sni() {
    source /usr/local/etc/xray-deploy/lib/utils.sh
    log_info "开始优选 SNI 域名..."
    local domains=("www.icloud.com" "dl.google.com" "www.microsoft.com" "swdist.apple.com")
    local best_sni="www.icloud.com"
    local min_ms=999
    
    for d in "${domains[@]}"; do
        ms=$(ping -c 2 $d | tail -1 | awk -F '/' '{print $5}' | cut -d'.' -f1)
        [[ -n "$ms" && "$ms" -lt "$min_ms" ]] && min_ms=$ms && best_sni=$d
        echo -e "  - $d: ${ms}ms"
    done
    
    log_info "最优域名: $best_sni，正在应用..."
    sed -i "s/\"dest\": \".*\"/\"dest\": \"$best_sni:443\"/g" /usr/local/etc/xray/config.json
    sed -i "s/\"serverNames\": \[ \".*\" \]/\"serverNames\": [ \"$best_sni\" ]/g" /usr/local/etc/xray/config.json
    systemctl restart xray
}
EOF

# --- 5. 写入 tools/bbr.sh (BBR+CAKE 模块) ---
cat <<'EOF' > $BASE_DIR/tools/bbr.sh
apply_bbr_cake() {
    source /usr/local/etc/xray-deploy/lib/utils.sh
    log_info "配置 BBR + CAKE..."
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = cake" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p
}
EOF

# --- 6. 创建全局快捷命令 ---
create_shortcuts() {
    # info: 查看信息
    cat <<'EOC' > /usr/local/bin/info
#!/bin/bash
source /usr/local/etc/xray-deploy/lib/utils.sh
source /usr/local/etc/xray-deploy/configs/current.info
IP=$(curl -s https://api.ipify.org)
echo -e "${CYAN}--- Xray Reality 节点信息 ---${PLAIN}"
echo -e "${GREEN}Vision 链接:${PLAIN} vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.icloud.com&fp=chrome&pbk=$PBK&sid=$SID#Reality-Vision"
echo -e "${GREEN}xHTTP 链接:${PLAIN} vless://$UUID@$IP:8443?encryption=none&security=reality&sni=www.icloud.com&fp=chrome&pbk=$PBK&sid=$SID&type=xhttp&path=$XPATH#Reality-xHTTP"
EOC

    # bbr: 查看状态
    cat <<'EOC' > /usr/local/bin/bbr
#!/bin/bash
echo -e "TCP 拥塞控制算法: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo -e "队列调度算法: $(sysctl net.core.default_qdisc | awk '{print $3}')"
EOC

    # update: 更新内核
    cat <<'EOC' > /usr/local/bin/update
#!/bin/bash
source /usr/local/etc/xray-deploy/core/xray.sh
install_xray_core && systemctl restart xray && echo "更新成功"
EOC

    # sni: 修改域名
    cat <<'EOC' > /usr/local/bin/sni
#!/bin/bash
source /usr/local/etc/xray-deploy/tools/sni_finder.sh
if [ -z "$1" ]; then optimize_sni; else
    sed -i "s/\"dest\": \".*\"/\"dest\": \"$1:443\"/g" /usr/local/etc/xray/config.json
    sed -i "s/\"serverNames\": \[ \".*\" \]/\"serverNames\": [ \"$1\" ]/g" /usr/local/etc/xray/config.json
    systemctl restart xray && echo "SNI 已手动修改为 $1"
fi
EOC
    chmod +x /usr/local/bin/{info,bbr,update,sni}
}

# --- 7. 执行安装逻辑 ---
source $BASE_DIR/lib/utils.sh
source $BASE_DIR/core/xray.sh
source $BASE_DIR/core/config.sh
source $BASE_DIR/tools/bbr.sh

main() {
    log_info "开始系统初始化..."
    apt-get update && apt-get install -y curl openssl jq
    
    install_xray_core
    generate_xray_config
    apply_bbr_cake
    create_shortcuts
    
    systemctl enable xray && systemctl restart xray
    log_info "安装完成！"
    info # 运行 info 命令显示结果
}

main "$@"
