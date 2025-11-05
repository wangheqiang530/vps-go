#!/bin/bash

# VPS 环境一键安装/升级脚本
# 假设运行在 Debian/Ubuntu 系统上
# 用法: sudo bash install_vps_env.sh

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 获取版本函数
get_version() {
    local pkg=$1
    case $pkg in
        "docker")
            docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//' || echo "未安装"
            ;;
        "Fail2Ban")
            fail2ban-client --version 2>/dev/null | head -1 | awk '{print $2}' || echo "未安装"
            ;;
        *)
            dpkg -l 2>/dev/null | grep "^ii  $pkg " | awk '{print $3}' | head -1 || echo "未安装"
            ;;
    esac
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    error "此脚本需 root 权限运行: sudo bash $0"
    exit 1
fi

# 初始化结果数组
declare -A RESULTS  # key: 项目名, value: "状态|旧版本|新版本"

# 第一步: 更新系统包列表并升级
log "更新系统包列表并升级..."
old_system="N/A"
apt update -qq && apt upgrade -yqq || { RESULTS["系统升级"]="失败|$old_system|apt 命令失败"; error "系统升级失败"; }
RESULTS["系统升级"]="升级|$old_system|已完成"
log "系统升级完成"

# 第二步: 设置时区为 Asia/Shanghai
log "设置时区为 Asia/Shanghai..."
old_tz=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3 $4}' | sed 's/ //g' || echo "未知")
timedatectl set-timezone Asia/Shanghai 2>/dev/null || warn "时区设置可能失败（某些系统不支持 timedatectl）"
if [[ "$old_tz" == "Asia/Shanghai" ]]; then
    RESULTS["时区设置"]="已设置|$old_tz|Asia/Shanghai"
else
    RESULTS["时区设置"]="设置|$old_tz|Asia/Shanghai"
fi

# 第三步: 安装/升级基本工具（sudo, curl, wget, bash, unzip, rsync, htop）
# 补充: git (版本控制), vim (编辑器), ca-certificates (证书), gnupg (GPG)
BASIC_PKGS="sudo curl wget unzip rsync htop git vim ca-certificates gnupg"
log "安装/升级基本工具: $BASIC_PKGS"
for pkg in $BASIC_PKGS; do
    old_version=$(get_version $pkg)
    if apt install -y $pkg 2>/dev/null; then
        new_version=$(get_version $pkg)
        if [[ "$old_version" == "未安装" || "$old_version" == "N/A" || "$old_version" == "未知" ]]; then
            action="安装"
        else
            action="升级"
        fi
        RESULTS[$pkg]="$action|$old_version|$new_version"
        log "$pkg $action 成功 (从 $old_version 到 $new_version)"
    else
        RESULTS[$pkg]="失败|$old_version|失败"
        warn "$pkg 安装失败"
    fi
done

# 第四步: 安装/升级系统服务（rsyslog, nftables）
SYS_PKGS="rsyslog nftables"
log "安装/升级系统服务: $SYS_PKGS"
for pkg in $SYS_PKGS; do
    old_version=$(get_version $pkg)
    if apt install -y $pkg 2>/dev/null; then
        new_version=$(get_version $pkg)
        if [[ "$old_version" == "未安装" || "$old_version" == "N/A" || "$old_version" == "未知" ]]; then
            action="安装"
        else
            action="升级"
        fi
        RESULTS[$pkg]="$action|$old_version|$new_version"
        log "$pkg $action 成功 (从 $old_version 到 $new_version)"
        # 启动服务（如果适用）
        systemctl enable $pkg 2>/dev/null || true
        systemctl start $pkg 2>/dev/null || true
    else
        RESULTS[$pkg]="失败|$old_version|失败"
        warn "$pkg 安装失败"
    fi
done

# 第五步: 安装/升级 Fail2Ban
log "安装/升级 Fail2Ban..."
old_f2b=$(get_version Fail2Ban)
if apt install -y fail2ban 2>/dev/null; then
    new_f2b=$(get_version Fail2Ban)
    if [[ "$old_f2b" == "未安装" || "$old_f2b" == "N/A" || "$old_f2b" == "未知" ]]; then
        action="安装"
    else
        action="升级"
    fi
    RESULTS["Fail2Ban"]="$action|$old_f2b|$new_f2b"
    log "Fail2Ban $action 成功 (从 $old_f2b 到 $new_f2b)"
    # 配置 Fail2Ban 以兼容 nftables
    log "配置 Fail2Ban 使用 nftables 后端..."
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
backend = nftables
bantime = 3600
findtime = 600
maxretry = 5
EOF
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    RESULTS["Fail2Ban 配置"]="配置|N/A|nftables 后端 + 默认参数"
else
    RESULTS["Fail2Ban"]="失败|$old_f2b|失败"
    warn "Fail2Ban 安装失败"
fi

# 第六步: 安装/升级 Docker
log "安装/升级 Docker..."
old_docker=$(get_version docker)
# 在卸载前检查是否有运行容器
if command -v docker >/dev/null 2>&1 && docker ps -q | grep -q .; then
    warn "检测到运行中的Docker容器，正在停止它们..."
    docker stop $(docker ps -q) 2>/dev/null || true
fi
# 卸载旧版（如果存在）
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
# 添加 Docker 官方仓库
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null || true
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update -qq
if apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null; then
    new_docker=$(get_version docker)
    if [[ "$old_docker" == "未安装" || "$old_docker" == "N/A" || "$old_docker" == "未知" ]]; then
        action="安装"
    else
        action="升级"
    fi
    RESULTS["Docker"]="$action|$old_docker|$new_docker"
    log "Docker $action 成功 (从 $old_docker 到 $new_docker)"
    # 配置 Docker 使用 nftables（避免 iptables 冲突）
    cat > /etc/docker/daemon.json << 'EOF'
{
  "iptables": false,
  "ip6tables": false,
  "dns": ["8.8.8.8", "114.114.114.114"]
}
EOF
    log "配置 Docker daemon.json 以兼容 nftables + DNS 优化"
    # 添加 Docker nftables 兼容规则
    log "配置 nftables 以支持 Docker..."
    WAN_IFACE=$(ip route show default | awk '/default/ {print $5; exit}' | head -1)
    if [[ -n "$WAN_IFACE" ]]; then
        cat >> /etc/nftables.conf << EOF

# Docker 兼容规则（由 vps-init-scripts.sh 生成）
table inet filter {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ct state established,related accept
        ct state invalid drop;
        iifname "docker0" oifname "$WAN_IFACE" accept
        iifname "$WAN_IFACE" oifname "docker0" accept
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$WAN_IFACE" masquerade;
    }
}
EOF
        if nft -f /etc/nftables.conf 2>/dev/null; then
            systemctl restart nftables 2>/dev/null || true
            RESULTS["Docker nftables"]="配置|N/A|已添加 (接口: $WAN_IFACE)"
            log "nftables Docker 规则已加载成功 (接口: $WAN_IFACE)"
        else
            RESULTS["Docker nftables"]="部分配置|N/A|规则生成但加载失败 (手动检查 /etc/nftables.conf)"
            warn "nftables 规则生成成功，但加载失败。请手动运行: sudo nft -f /etc/nftables.conf"
        fi
    else
        RESULTS["Docker nftables"]="跳过|N/A|未检测到 WAN 接口"
        warn "未检测到 WAN 接口，跳过 nftables Docker 配置"
    fi
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker  # 重启以应用配置
    # 添加当前用户到 docker 组（如果适用）
    usermod -aG docker $SUDO_USER 2>/dev/null || true
else
    RESULTS["Docker"]="失败|$old_docker|失败"
    warn "Docker 安装失败"
fi

# 第七步: 安装/升级 Docker Compose (作为插件已包含在上一步，若需独立版本则下载)
# 注意: Docker Compose v2 已作为 docker compose 插件集成，无需单独安装
old_compose="N/A"
new_compose="集成在 Docker CE (v2.x)"
RESULTS["Docker Compose"]="安装|$old_compose|$new_compose"

# 第八步: 系统清理（清理依赖、垃圾文件、过时组件）
log "执行系统清理..."
old_space=$(df / | awk 'NR==2 {print $4}')  # 可用空间（KB）
clean_cmds=(
    "apt autoremove -y"  # 移除不再需要的依赖
    "apt autoclean"     # 清理旧包缓存
    "apt clean"         # 清空包缓存
)
if command -v docker >/dev/null 2>&1; then
    clean_cmds+=("docker image prune -f")  # 清理未使用的镜像
    clean_cmds+=("docker builder prune -f")  # 清理构建缓存
fi
clean_cmds+=(
    "journalctl --vacuum-time=2weeks"  # 清理系统日志（保留2周）
    "rm -rf /tmp/* /var/tmp/*"         # 清理临时文件
)
cleanup_success=true
for cmd in "${clean_cmds[@]}"; do
    if eval "$cmd" 2>/dev/null; then
        log "$cmd 清理成功"
    else
        warn "$cmd 清理失败或无变化"
        cleanup_success=false
    fi
done
new_space=$(df / | awk 'NR==2 {print $4}')
space_freed_kb=$((new_space - old_space))
if [[ $space_freed_kb -lt 0 ]]; then space_freed_kb=0; fi
space_freed_mb=$((space_freed_kb / 1024))
space_freed_remainder=$((space_freed_kb % 1024))
if [[ $space_freed_mb -gt 0 ]]; then
    space_detail="${space_freed_mb}MB"
    [[ $space_freed_remainder -gt 0 ]] && space_detail+="+${space_freed_remainder}KB"
else
    space_detail="${space_freed_kb}KB"
fi
RESULTS["系统清理"]=$([[ "$cleanup_success" == true ]] && echo "清理|N/A|释放 $space_detail" || echo "部分清理|N/A|释放 $space_detail")

# 总结输出: 表格
echo ""
log "=== 安装/升级结果总结 ==="
printf "%-20s %-5s %-25s %-25s\n" "项目" "状态" "之前版本" "现在版本"
printf "%s\n" "------------------------------------------------------------------------------------------"
for key in "${!RESULTS[@]}"; do
    IFS='|' read -r status old new <<< "${RESULTS[$key]}"
    if [[ "$status" == "失败" ]]; then
        color="${RED}"
        new_color="${RED}"
    else
        color="${GREEN}"
        # 检查是否版本无变动（绿色）或有变动（黄色）
        if [[ "$status" == "升级" && "$old" == "$new" ]] || [[ "$status" == "已设置" ]]; then
            new_color="${GREEN}"
        else
            new_color="${YELLOW}"
        fi
    fi
    printf "${color}%-20s %-5s %-25s${NC}" "$key" "$status" "$old"
    printf "${new_color}%-25s${NC}\n" "$new"
done

# 统计（修复版：正确计数成功项目）
success_count=0
for result in "${RESULTS[@]}"; do
    if [[ "$result" != 失败* ]]; then ((success_count++)); fi
done
total_count=${#RESULTS[@]}
echo ""
log "总计: $success_count / $total_count 项目成功"
warn "重启系统以应用所有更改: sudo reboot"
echo ""
log "脚本执行完成！"
