#!/usr/bin/env bash
# ================================================================
#  Xray VLESS-Reality 一键安装脚本 v2.0.0
#  支持系统: Ubuntu 20.04+ / Debian 10+ / CentOS 8+
# ================================================================

set -euo pipefail

# ════════════════════════════════════════
#  颜色定义
# ════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# ════════════════════════════════════════
#  全局常量
# ════════════════════════════════════════
readonly SCRIPT_VERSION="2.0.0"
readonly INSTALL_LOG="/var/log/xray_install.log"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF_DIR="/usr/local/etc/xray"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly BACKUP_DIR="/var/backup/xray_$(date +%Y%m%d_%H%M%S)"
readonly GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly GITHUB_DOWNLOAD="https://github.com/XTLS/Xray-core/releases/download"

# ════════════════════════════════════════
#  全局配置
# ════════════════════════════════════════
declare -A CFG=(
    [UUID]=""
    [PRIVATE_KEY]=""
    [PUBLIC_KEY]=""
    [SHORT_ID]=""
    [PORT]="443"
    [SNI]="www.microsoft.com"
    [BBR_AVAILABLE]="false"
    [QDISC]="fq"
    [OS]=""
    [OS_VER]=""
    [ARCH]=""
    [XRAY_VER]=""
)

declare -a INSTALL_STEPS=()

# ════════════════════════════════════════
#  日志与输出函数
# ════════════════════════════════════════
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$INSTALL_LOG"; }
info()    { echo -e "${CYAN}  [信息]${PLAIN} $*";    log "[INFO]  $*"; }
success() { echo -e "${GREEN}  [成功]${PLAIN} $*";   log "[OK]    $*"; }
warn()    { echo -e "${YELLOW}  [警告]${PLAIN} $*";  log "[WARN]  $*"; }
error()   { echo -e "${RED}  [错误]${PLAIN} $*" >&2; log "[ERROR] $*"; }

section() {
    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${PLAIN}"
    echo -e "${BOLD}${BLUE}  $*${PLAIN}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${PLAIN}"
    log "=== $* ==="
}

# ════════════════════════════════════════
#  Banner
# ════════════════════════════════════════
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║     Xray VLESS-Reality 安装脚本       ║"
    echo "  ║     版本: v${SCRIPT_VERSION}                    ║"
    echo "  ║     协议: VLESS + XTLS-Vision          ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${PLAIN}"
    echo -e "  安装日志: ${YELLOW}${INSTALL_LOG}${PLAIN}"
    echo ""
}

# ════════════════════════════════════════
#  执行任务（带状态显示）
# ════════════════════════════════════════
execute_task() {
    local cmd="$1"
    local desc="${2:-执行命令}"
    local allow_fail="${3:-false}"

    echo -ne "  ${CYAN}▶${PLAIN} ${desc}... "
    log "执行: $cmd"

    if eval "$cmd" >> "$INSTALL_LOG" 2>&1; then
        echo -e "${GREEN}✓${PLAIN}"
        log "成功: $desc"
        return 0
    else
        local exit_code=$?
        if [[ "$allow_fail" == "true" ]]; then
            echo -e "${YELLOW}⚠ (跳过)${PLAIN}"
            log "跳过: $desc"
            return 0
        else
            echo -e "${RED}✗${PLAIN}"
            error "$desc 失败"
            return $exit_code
        fi
    fi
}

# ════════════════════════════════════════
#  回滚函数
# ════════════════════════════════════════
rollback() {
    warn "检测到错误，开始回滚..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    # 关闭防火墙端口
    for step in "${INSTALL_STEPS[@]}"; do
        if [[ "$step" == "firewall_opened" ]]; then
            close_firewall_port "${CFG[PORT]}" 2>/dev/null || true
            break
        fi
    done

    # 恢复备份
    if [[ -d "$BACKUP_DIR" ]]; then
        [[ -f "$BACKUP_DIR/config.json" ]] && \
            cp "$BACKUP_DIR/config.json" "$XRAY_CONF_DIR/config.json"
        [[ -f "$BACKUP_DIR/xray.service" ]] && \
            cp "$BACKUP_DIR/xray.service" "$XRAY_SERVICE"
        systemctl daemon-reload 2>/dev/null || true
        success "已恢复备份"
    fi

    error "安装失败，已回滚。详细日志: ${INSTALL_LOG}"
}

# ════════════════════════════════════════
#  防火墙操作
# ════════════════════════════════════════
open_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        execute_task "ufw allow ${port}/${proto}" "UFW 开放端口 ${port}" "true"
    fi

    if command -v firewall-cmd &>/dev/null && \
       firewall-cmd --state &>/dev/null 2>&1; then
        execute_task \
            "firewall-cmd --permanent --add-port=${port}/${proto} && firewall-cmd --reload" \
            "Firewalld 开放端口 ${port}" "true"
    fi

    if command -v iptables &>/dev/null; then
        execute_task \
            "iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT" \
            "iptables 开放端口 ${port}" "true"
        # 持久化
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

close_firewall_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if command -v ufw &>/dev/null; then
        ufw delete allow "${port}/${proto}" 2>/dev/null || true
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

# ════════════════════════════════════════
#  1. 环境检测
# ════════════════════════════════════════
check_environment() {
    section "1. 环境检测"

    # Root 权限
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本"
        exit 1
    fi
    success "Root 权限检查通过"

    # 初始化日志
    mkdir -p "$(dirname "$INSTALL_LOG")"
    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"
    log "=== 安装开始 $(date) | 脚本版本: $SCRIPT_VERSION ==="

    # 系统检测
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        CFG[OS]="${ID:-unknown}"
        CFG[OS_VER]="${VERSION_ID:-unknown}"
    else
        error "无法识别操作系统"
        exit 1
    fi

    local ver_major
    ver_major=$(echo "${CFG[OS_VER]}" | cut -d. -f1)

    case "${CFG[OS]}" in
        ubuntu)
            [[ $ver_major -lt 20 ]] && { error "需要 Ubuntu 20.04+"; exit 1; }
            ;;
        debian)
            [[ $ver_major -lt 10 ]] && { error "需要 Debian 10+"; exit 1; }
            ;;
        centos|rhel|rocky|almalinux)
            [[ $ver_major -lt 8 ]] && { error "需要 CentOS/RHEL 8+"; exit 1; }
            ;;
        *)
            warn "未经测试的系统: ${CFG[OS]}，继续安装..."
            ;;
    esac
    success "操作系统: ${CFG[OS]} ${CFG[OS_VER]}"

    # 架构检测
    case "$(uname -m)" in
        x86_64)         CFG[ARCH]="64" ;;
        aarch64|arm64)  CFG[ARCH]="arm64-v8a" ;;
        armv7l)         CFG[ARCH]="arm32-v7a" ;;
        s390x)          CFG[ARCH]="s390x" ;;
        *)
            error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
    success "系统架构: $(uname -m) → ${CFG[ARCH]}"

    # 内核版本 & BBR 检测
    local kernel_ver kernel_major kernel_minor
    kernel_ver=$(uname -r)
    kernel_major=$(echo "$kernel_ver" | cut -d. -f1)
    kernel_minor=$(echo "$kernel_ver" | cut -d. -f2)
    success "内核版本: $kernel_ver"

    if [[ $kernel_major -gt 4 ]] || \
       [[ $kernel_major -eq 4 && $kernel_minor -ge 9 ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            CFG[BBR_AVAILABLE]="true"
            # 检测 fq 队列调度器
            if tc qdisc add dev lo root fq 2>/dev/null; then
                tc qdisc del dev lo root 2>/dev/null || true
                CFG[QDISC]="fq"
            else
                CFG[QDISC]="fq_codel"
            fi
            success "BBR 支持: 可用 (队列调度: ${CFG[QDISC]})"
        else
            warn "BBR 模块不可用，将跳过 BBR 配置"
        fi
    else
        warn "内核 $kernel_ver 过低 (需要 4.9+)，跳过 BBR"
    fi

    # 网络连通性
    echo -ne "  ${CYAN}▶${PLAIN} 检测网络连通性... "
    local net_ok=false
    for host in "github.com" "api.github.com"; do
        if timeout 5 bash -c "echo >/dev/tcp/$host/443" 2>/dev/null; then
            net_ok=true
            break
        fi
    done
    if $net_ok; then
        echo -e "${GREEN}✓${PLAIN}"
    else
        echo -e "${RED}✗${PLAIN}"
        error "无法连接 GitHub，请检查网络"
        exit 1
    fi

    # 磁盘空间（≥200MB）
    local free_mb
    free_mb=$(df /usr/local --output=avail -BM 2>/dev/null | tail -1 | tr -d 'M' || echo "999")
    [[ $free_mb -lt 200 ]] && { error "磁盘空间不足 (需要 200MB，当前 ${free_mb}MB)"; exit 1; }
    success "磁盘空间: ${free_mb}MB 可用"

    # 内存（≥128MB 警告）
    local free_mem
    free_mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "999")
    [[ $free_mem -lt 128 ]] && warn "可用内存较低: ${free_mem}MB"
    success "可用内存: ${free_mem}MB"
}

# ════════════════════════════════════════
#  2. 安装依赖
# ════════════════════════════════════════
install_dependencies() {
    section "2. 安装依赖"

    local pkgs="curl wget unzip openssl lsof ca-certificates"

    case "${CFG[OS]}" in
        ubuntu|debian)
            execute_task "apt-get update -qq" "更新软件包列表"
            execute_task "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs" \
                "安装依赖包"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                execute_task "dnf install -y -q $pkgs" "安装依赖包(dnf)"
            else
                execute_task "yum install -y -q $pkgs" "安装依赖包(yum)"
            fi
            ;;
        *)
            warn "尝试通用方式安装依赖..."
            execute_task "apt-get install -y -qq $pkgs" "安装
