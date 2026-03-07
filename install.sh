#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#  Xray-Reality 一键全自动安装脚本 (深度优化版 v2.0)
#  优化项：安全校验 / 错误处理 / 兼容检测 / 回滚机制 / 防火墙
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── 颜色定义 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ─── 路径定义 ───
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"
INFO_PATH="/etc/xray_info"
INSTALL_LOG="/tmp/xray_install_$(date +%Y%m%d_%H%M%S).log"
GEO_UPDATE_LOG="/var/log/xray-geo.log"

# ─── 全局配置容器（替代裸全局变量）───
declare -A CFG
CFG[SNI]="www.microsoft.com"

# ─── 安装步骤追踪（用于回滚）───
declare -a INSTALL_STEPS=()

# ════════════════════════════════════════
#  工具函数区
# ════════════════════════════════════════

# 打印分隔标题
section() {
    echo -e "\n${CYAN}─── $1 ───${PLAIN}"
}

# 任务执行器（失败保留日志）
execute_task() {
    local cmd="$1"
    local desc="$2"
    local allow_fail="${3:-false}"   # 第三参数为 true 时允许失败不退出

    echo -ne "  [执行] ${desc}... "
    if eval "$cmd" >>"$INSTALL_LOG" 2>&1; then
        echo -e "${GREEN}✓ 成功${PLAIN}"
        return 0
    else
        local exit_code=$?
        echo -e "${RED}✗ 失败 (exit=$exit_code)${PLAIN}"
        echo -e "  ${YELLOW}→ 详细日志: $INSTALL_LOG${PLAIN}"
        if [[ "$allow_fail" == "true" ]]; then
            return 1
        else
            echo -e "${RED}致命错误，触发回滚...${PLAIN}"
            rollback
            exit "$exit_code"
        fi
    fi
}

# 打印带颜色的状态信息
info()    { echo -e "  ${CYAN}[INFO]${PLAIN}  $*"; }
success() { echo -e "  ${GREEN}[OK]${PLAIN}    $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${PLAIN}  $*"; }
error()   { echo -e "  ${RED}[ERROR]${PLAIN} $*"; }

# ════════════════════════════════════════
#  回滚机制
# ════════════════════════════════════════

rollback() {
    echo -e "\n${YELLOW}════ 开始回滚 ════${PLAIN}"

    # 逆序执行已记录的步骤
    local i
    for (( i=${#INSTALL_STEPS[@]}-1; i>=0; i-- )); do
        local step="${INSTALL_STEPS[$i]}"
        case "$step" in
            "service_started")
                systemctl stop xray 2>/dev/null && warn "已停止 xray 服务"
                ;;
            "service_enabled")
                systemctl disable xray 2>/dev/null && warn "已禁用 xray 服务"
                ;;
            "config_written")
                rm -f "$XRAY_CONF_DIR/config.json" && warn "已删除配置文件"
                ;;
            "xray_installed")
                warn "Xray 核心保留（手动卸载请执行: bash install-release.sh @ remove）"
                ;;
            "firewall_opened")
                close_firewall_port "${CFG[PORT]:-0}"
                ;;
            "cron_added")
                crontab -l 2>/dev/null | grep -v "xray-update-geo" | crontab - 2>/dev/null
                warn "已移除 cron 任务"
                ;;
            "cli_installed")
                rm -f /usr/local/bin/xray-info \
                      /usr/local/bin/xray-bbr \
                      /usr/local/bin/xray-update-geo \
                      /usr/local/bin/xray-uninstall
                warn "已移除 CLI 工具"
                ;;
        esac
    done

    echo -e "${YELLOW}回滚完成，安装日志保留于: $INSTALL_LOG${PLAIN}\n"
}

# 捕获意外退出
trap 'echo -e "\n${RED}脚本意外中断！${PLAIN}"; rollback' INT TERM

# ════════════════════════════════════════
#  0. 权限与系统兼容性检测
# ════════════════════════════════════════

check_prerequisites() {
    section "0. 前置检查"

    # Root 权限
    [[ $EUID -ne 0 ]] && error "必须使用 root 用户运行！" && exit 1
    success "Root 权限确认"

    # 操作系统检测
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-0}"
    else
        error "无法识别操作系统，仅支持 Debian/Ubuntu"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu)
            local major_ver
            major_ver=$(echo "$OS_VER" | cut -d. -f1)
            if [[ $major_ver -lt 20 ]]; then
                error "Ubuntu 版本过低（最低要求 20.04），当前: $OS_VER"
                exit 1
            fi
            ;;
        debian)
            if [[ ${OS_VER%%.*} -lt 10 ]]; then
                error "Debian 版本过低（最低要求 10），当前: $OS_VER"
                exit 1
            fi
            ;;
        *)
            error "不支持的操作系统: $OS_ID（仅支持 Debian/Ubuntu）"
            exit 1
            ;;
    esac
    success "操作系统: $OS_ID $OS_VER"

    # CPU 架构检测
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)          CFG[ARCH]="64"           ;;
        aarch64|arm64)   CFG[ARCH]="arm64-v8a"    ;;
        armv7l)          CFG[ARCH]="arm32-v7a"    ;;
        *)
            error "不支持的 CPU 架构: $arch"
            exit 1
            ;;
    esac
    success "CPU 架构: $arch → ${CFG[ARCH]}"

    # 内核版本检测（BBR 需要 4.9+，CAKE 需要 4.19+）
    local kernel_ver
    kernel_ver=$(uname -r)
    local k_major k_minor
    k_major=$(echo "$kernel_ver" | cut -d. -f1)
    k_minor=$(echo "$kernel_ver" | cut -d. -f2)
    local k_num=$(( k_major * 100 + k_minor ))

    if [[ $k_num -ge 419 ]]; then
        CFG[QDISC]="cake"
        CFG[BBR_AVAILABLE]="true"
    elif [[ $k_num -ge 409 ]]; then
        CFG[QDISC]="fq"
        CFG[BBR_AVAILABLE]="true"
        warn "内核 $kernel_ver: BBR 可用，但 CAKE 队列需要 4.19+，降级使用 fq"
    else
        CFG[QDISC]="fq"
        CFG[BBR_AVAILABLE]="false"
        warn "内核 $kernel_ver 过低，BBR 不可用，使用默认拥塞控制"
    fi
    success "内核版本: $kernel_ver (队列算法: ${CFG[QDISC]})"

    # 网络连通性检测
    echo -ne "  [执行] 检测网络连通性... "
    if curl -sSf --max-time 10 https://github.com -o /dev/null 2>/dev/null; then
        echo -e "${GREEN}✓ 成功${PLAIN}"
    else
        echo -e "${RED}✗ 失败${PLAIN}"
        error "无法连接 GitHub，请检查网络或 DNS 配置"
        exit 1
    fi

    # 初始化日志文件
    mkdir -p "$(dirname "$INSTALL_LOG")"
    echo "=== Xray 安装日志 $(date) ===" > "$INSTALL_LOG"
    success "日志文件: $INSTALL_LOG"
}

# ════════════════════════════════════════
#  1. 环境清理与依赖安装
# ════════════════════════════════════════

prepare_env() {
    section "1. 环境准备"

    # 清理 apt 锁（带超时等待）
    local lock_wait=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [[ $lock_wait -ge 60 ]]; then
            error "等待 apt 锁超时（60s），请检查是否有其他包管理器在运行"
            exit 1
        fi
        warn "apt 被锁定，等待释放... (${lock_wait}s)"
        sleep 5
        (( lock_wait += 5 ))
    done
    rm -f /var/lib/apt/lists/lock \
          /var/cache/apt/archives/lock \
          /var/lib/dpkg/lock \
          /var/lib/dpkg/lock-frontend

    # 停止旧服务（允许失败）
    systemctl stop xray 2>/dev/null || true

    # 安装依赖
    export DEBIAN_FRONTEND=noninteractive
    execute_task \
        "apt-get update -qq && apt-get install -y -qq \
         curl wget tar unzip openssl jq \
         ca-certificates chrony lsof \
         ufw iptables" \
        "安装系统依赖"

    # 时间同步（Reality 对时间精度敏感）
    execute_task "systemctl enable --now chrony" "启动时间同步服务" "true"
    execute_task "chronyc makestep" "立即同步系统时间" "true"

    local time_offset
    time_offset=$(chronyc tracking 2>/dev/null | awk '/System time/{print $4}' || echo "unknown")
    info "当前时间偏差: ${time_offset} 秒"
}

# ════════════════════════════════════════
#  2. Xray 核心安装
# ════════════════════════════════════════

install_core() {
    section "2. 核心安装"

    # 下载安装脚本到本地再执行（避免管道执行无法检测错误）
    local installer="/tmp/xray_install_release.sh"
    execute_task \
        "curl --tlsv1.2 --max-time 120 -fsSL \
         https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
         -o $installer && chmod +x $installer" \
        "下载 Xray 安装脚本"

    # 验证脚本非空
    if [[ ! -s "$installer" ]]; then
        error "安装脚本下载为空，终止"
        exit 1
    fi

    execute_task \
        "bash $installer @ install --without-geodata" \
        "安装 Xray Core"
    rm -f "$installer"
    INSTALL_STEPS+=("xray_installed")

    # 验证二进制存在且可执行
    if [[ ! -x "$XRAY_BIN" ]]; then
        error "Xray 二进制文件不存在或不可执行: $XRAY_BIN"
        rollback; exit 1
    fi

    local xray_ver
    xray_ver=$("$XRAY_BIN" version 2>/dev/null | head -1 || echo "unknown")
    success "Xray 版本: $xray_ver"

    # 下载 GeoData（带完整性验证）
    mkdir -p "$XRAY_SHARE_DIR"
    local geo_base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

    for geo_file in geoip.dat geosite.dat; do
        local tmp_file="$XRAY_SHARE_DIR/${geo_file}.tmp"
        execute_task \
            "curl --tlsv1.2 --max-time 120 -fsSL \
             ${geo_base}/${geo_file} -o ${tmp_file}" \
            "下载 ${geo_file}"

        # 验证文件大小（geoip > 2MB，geosite > 1MB）
        local min_size=1024
        [[ "$geo_file" == "geoip.dat" ]] && min_size=2048
        local actual_size
        actual_size=$(du -k "$tmp_file" 2>/dev/null | awk '{print $1}')

        if [[ ${actual_size:-0} -lt $min_size ]]; then
            error "${geo_file} 文件异常（大小: ${actual_size}KB，期望 > ${min_size}KB）"
            rm -f "$tmp_file"
            rollback; exit 1
        fi

        mv "$tmp_file" "$XRAY_SHARE_DIR/$geo_file"
        success "${geo_file} 验证通过 (${actual_size}KB)"
    done

    chmod 644 "$XRAY_SHARE_DIR"/*.dat
}

# ════════════════════════════════════════
#  3. 密钥生成（带严格校验）
# ════════════════════════════════════════

cat >> install_fixed.sh << 'SCRIPT_EOF'

generate_reality_keys() {
    section "3. 密钥生成"

    # 生成 Reality 密钥对
    local key_output
    key_output=$("$XRAY_BIN" x25519 2>/dev/null) || {
        error "密钥生成失败，请检查 Xray 是否正确安装"
        rollback; exit 1
    }

    CFG[PRIVATE_KEY]=$(echo "$key_output" | awk '/Private key/{print $3}')
    CFG[PUBLIC_KEY]=$(echo "$key_output"  | awk '/Public key/{print $3}')

    # 严格校验密钥格式（Base64url，43或44字符）
    local key_regex='^[A-Za-z0-9_-]{43,44}$'
    if [[ ! "${CFG[PRIVATE_KEY]}" =~ $key_regex ]]; then
        error "私钥格式异常: ${CFG[PRIVATE_KEY]}"
        rollback; exit 1
    fi
    if [[ ! "${CFG[PUBLIC_KEY]}" =~ $key_regex ]]; then
        error "公钥格式异常: ${CFG[PUBLIC_KEY]}"
        rollback; exit 1
    fi

    # 生成 ShortID（8字节随机十六进制）
    CFG[SHORT_ID]=$(openssl rand -hex 8)
    [[ -z "${CFG[SHORT_ID]}" ]] && { error "ShortID 生成失败"; rollback; exit 1; }

    # 生成 UUID
    CFG[UUID]=$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if [[ ! "${CFG[UUID]}" =~ $uuid_regex ]]; then
        error "UUID 格式异常: ${CFG[UUID]}"
        rollback; exit 1
    fi

    success "UUID:        ${CFG[UUID]}"
    success "私钥:        ${CFG[PRIVATE_KEY]}"
    success "公钥:        ${CFG[PUBLIC_KEY]}"
    success "ShortID:     ${CFG[SHORT_ID]}"
}

# ════════════════════════════════════════
#  4. 端口选择与防火墙
# ════════════════════════════════════════

open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/${proto}" >> "$INSTALL_LOG" 2>&1 && \
            info "ufw: 已放行 ${port}/${proto}"
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
        info "iptables: 已放行 ${port}/${proto}"
    fi

    # ip6tables
    if command -v ip6tables &>/dev/null; then
        ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
            ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
        info "ip6tables: 已放行 ${port}/${proto}"
    fi
}

close_firewall_port() {
    local port="$1"
    [[ "$port" -eq 0 ]] && return

    command -v ufw &>/dev/null && ufw delete allow "${port}/tcp" 2>/dev/null || true
    iptables  -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    warn "防火墙: 已关闭端口 $port"
}

select_port() {
    section "4. 端口配置"

    while true; do
        read -rp "  请输入监听端口 [1-65535，默认 443]: " input_port
        input_port="${input_port:-443}"

        # 纯数字校验
        if ! [[ "$input_port" =~ ^[0-9]+$ ]]; then
            warn "端口必须为纯数字，请重新输入"
            continue
        fi

        # 范围校验
        if [[ $input_port -lt 1 || $input_port -gt 65535 ]]; then
            warn "端口范围 1-65535，请重新输入"
            continue
        fi

        # 占用检测
        if lsof -iTCP:"$input_port" -sTCP:LISTEN -n -P &>/dev/null; then
            local occupier
            occupier=$(lsof -iTCP:"$input_port" -sTCP:LISTEN -n -P 2>/dev/null \
                       | awk 'NR==2{print $1}')
            warn "端口 $input_port 已被 ${occupier:-未知进程} 占用，请换一个"
            continue
        fi

        CFG[PORT]="$input_port"
        break
    done

    success "监听端口: ${CFG[PORT]}"
    open_firewall_port "${CFG[PORT]}" "tcp"
    INSTALL_STEPS+=("firewall_opened")
}

# ════════════════════════════════════════
#  5. SNI 目标配置
# ════════════════════════════════════════

select_sni() {
    section "5. SNI 目标配置"

    local presets=(
        "www.microsoft.com"
        "www.apple.com"
        "www.amazon.com"
        "www.cloudflare.com"
        "自定义输入"
    )

    echo ""
    local i
    for i in "${!presets[@]}"; do
        echo "    $((i+1)). ${presets[$i]}"
    done
    echo ""

    while true; do
        read -rp "  请选择 SNI [1-${#presets[@]}，默认 1]: " sni_choice
        sni_choice="${sni_choice:-1}"

        if ! [[ "$sni_choice" =~ ^[0-9]+$ ]] || \
           [[ $sni_choice -lt 1 || $sni_choice -gt ${#presets[@]} ]]; then
            warn "无效选择，请输入 1-${#presets[@]}"
            continue
        fi

        if [[ $sni_choice -eq ${#presets[@]} ]]; then
            read -rp "  请输入自定义 SNI 域名: " custom_sni
            if [[ -z "$custom_sni" ]]; then
                warn "SNI 不能为空"
                continue
            fi
            CFG[SNI]="$custom_sni"
        else
            CFG[SNI]="${presets[$((sni_choice-1))]}"
        fi
        break
    done

    # 连通性测试
    echo -ne "  [测试] 连接 ${CFG[SNI]}:443... "
    if timeout 5 bash -c "echo >/dev/tcp/${CFG[SNI]}/443" 2>/dev/null; then
        echo -e "${GREEN}✓ 可达${PLAIN}"
    else
        echo -e "${YELLOW}⚠ 不可达（继续安装，但客户端可能无法握手）${PLAIN}"
    fi

    success "SNI 目标: ${CFG[SNI]}"
}

# ════════════════════════════════════════
#  6. 写入 Xray 配置文件
# ════════════════════════════════════════

write_config() {
    section "6. 写入配置"

    mkdir -p "$XRAY_CONF_DIR"

    cat > "$XRAY_CONF_DIR/config.json" << JSON_EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${CFG[PORT]},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CFG[UUID]}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${CFG[SNI]}:443",
          "xver": 0,
          "serverNames": ["${CFG[SNI]}"],
          "privateKey": "${CFG[PRIVATE_KEY]}",
          "shortIds": ["${CFG[SHORT_ID]}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  }
}
JSON_EOF

    INSTALL_STEPS+=("config_written")

    # 配置文件语法验证
    if ! "$XRAY_BIN" -test -config "$XRAY_CONF_DIR/config.json" >> "$INSTALL_LOG" 2>&1; then
        error "配置文件语法验证失败！"
        cat "$XRAY_CONF_DIR/config.json"
        rollback; exit 1
    fi
    success "配置文件语法验证通过"

    # 创建日志目录
    mkdir -p /var/log/xray
    chmod 755 /var/log/xray
}

# ════════════════════════════════════════
#  7. BBR 加速
# ════════════════════════════════════════

enable_bbr() {
    section "7. BBR 加速"

    if [[ "${CFG[BBR_AVAILABLE]}" != "true" ]]; then
        warn "内核不支持 BBR，跳过"
        return 0
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    if [[ "$current_cc" == "bbr" ]]; then
        success "BBR 已启用（当前: $current_cc），跳过"
        return 0
    fi

    # 写入 sysctl 配置
    local sysctl_conf="/etc/sysctl.d/99-xray-bbr.conf"
    cat > "$sysctl_conf" << SYSCTL_EOF
# Xray BBR 加速配置
net.core.default_qdisc = ${CFG[QDISC]}
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
SYSCTL_EOF

    execute_task "sysctl -p $sysctl_conf" "应用 BBR 内核参数" "true"

    # 验证 BBR 是否生效
    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$new_cc" == "bbr" ]]; then
        success "BBR 已成功启用 (队列: ${CFG[QDISC]})"
    else
        warn "BBR 启用可能未生效（当前: $new_cc），不影响 Xray 运行"
    fi
}

# ════════════════════════════════════════
#  8. 服务启动与健康检查
# ════════════════════════════════════════

start_service() {
    section "8. 服务启动"

    execute_task "systemctl daemon-reload" "重载 systemd"
    execute_task "systemctl enable xray"  "设置开机自启"
    INSTALL_STEPS+=("service_enabled")

    execute_task "systemctl restart xray" "启动 Xray 服务"
    INSTALL_STEPS+=("service_started")

    # 等待服务稳定
    sleep 2

    # 健康检查
    local retry=0
    while [[ $retry -lt 5 ]]; do
        if systemctl is-active --quiet xray; then
            success "Xray 服务运行正常"
            break
        fi
        (( retry++ ))
        warn "服务未就绪，等待重试 ($retry/5)..."
        sleep 2
    done

    if ! systemctl is-active --quiet xray; then
        error "Xray 服务启动失败！"
        echo -e "\n${YELLOW}=== 服务日志 ===${PLAIN}"
        journalctl -u xray -n 30 --no-pager
        rollback; exit 1

