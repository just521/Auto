#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_PATH="/usr/local/etc/xray/config.json"
SCRIPT_PATH="$(readlink -f "$0")"

install_all() {
    echo -e "${YELLOW}正在同步系统时间与更新基础环境...${NC}"
    apt-get update
    apt-get install -y curl gpg lsb-release wget jq ca-certificates
    update-ca-certificates

    # 安装 WARP
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${YELLOW}正在安装 Cloudflare WARP...${NC}"
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        OS_CODENAME=$(lsb_release -cs)
        # 兼容 trixie/sid
        [[ "$OS_CODENAME" == "trixie" || "$OS_CODENAME" == "sid" ]] && OS_CODENAME="bookworm"
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $OS_CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    fi

    echo -e "${YELLOW}正在初始化 WARP 配置...${NC}"
    systemctl enable --now warp-svc
    sleep 2
    
    # 修正点：使用正确的首字母大写 WireGuard
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos tunnel protocol set WireGuard
    warp-cli --accept-tos connect
    
    # 等待连接就绪
    echo -e "${YELLOW}等待 WARP 建立连接...${NC}"
    sleep 5

    # 安装 Xray
    if ! command -v xray &> /dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    init_config
    set_global_command
    echo -e "${GREEN}安装与配置完成！${NC}"
    check_status
}

# ... (其余函数保持不变) ...

# 修正后的状态检查函数
check_status() {
    echo -e "\n${BLUE}--- 当前状态检查 ---${NC}"
    # 这里的 awk 提取逻辑做了增强
    warp_s=$(warp-cli status | grep "Status update:" | awk '{print $NF}')
    [[ -z "$warp_s" ]] && warp_s=$(warp-cli status | grep "Status:" | awk '{print $NF}')
    
    echo -ne "WARP 状态: "
    if [[ "$warp_s" == "Connected" ]]; then
        echo -e "${GREEN}$warp_s${NC}"
    else
        echo -e "${RED}$warp_s (尝试执行 'warp-cli connect')${NC}"
    fi

    xray_s=$(systemctl is-active xray)
    echo -e "Xray 状态: ${GREEN}${xray_s}${NC}"
    echo -e "--------------------"
}

# 脚本入口保持不变
