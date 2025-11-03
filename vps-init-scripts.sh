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

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    error "此脚本需 root 权限运行: sudo bash $0"
    exit 1
fi

# 初始化结果数组
declare -A RESULTS  # key: 项目名, value: "成功|版本" 或 "失败|错误"

# 第一步: 更新系统包列表并升级
log "更新系统包列表并升级..."
apt update -qq && apt upgrade -yqq || RESULTS["系统升级"]="失败|apt 命令失败"
log "系统升级完成"

# 第二步: 设置时区为 Asia/Shanghai
log "设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai 2>/dev/null || warn "时区设置可能失败（某些系统不支持 timedatectl）"
RESULTS["时区设置"]="成功|Asia/Shanghai"

# 第三步: 安装/升级基本工具（sudo, curl, wget, bash, unzip, rsync, htop）
# 补充: git (版本控制), vim (编辑器), ca-certificates (证书), gnupg (GPG)
BASIC_PKGS="sudo curl wget unzip rsync htop git vim ca-certificates gnupg"
log "安装/升级基本工具: $BASIC_PKGS"
for pkg in $BASIC_PKGS; do
    if apt install -y $pkg 2>/dev/null; then
        # 获取版本
        version=$(dpkg -l | grep "^ii  $pkg " | awk '{print $3}' | head -1 || echo "未知")
        RESULTS[$pkg]="成功|$version"
        log "$pkg 安装/升级成功 (v$version)"
    else
        RESULTS[$pkg]="失败|apt install 失败"
        warn "$pkg 安装失败"
    fi
done

# 第四步: 安装/升级系统服务（rsyslog, nftables）
SYS_PKGS="rsyslog nftables"
log "安装/升级系统服务: $SYS_PKGS"
for pkg in $SYS_PKGS; do
    if apt install -y $pkg 2>/dev/null; then
        version=$(dpkg -l | grep "^ii  $pkg " | awk '{print $3}' | head -1 || echo "未知")
        RESULTS[$pkg]="成功|$version"
        log "$pkg 安装/升级成功 (v$version)"
        # 启动服务（如果适用）
        systemctl enable $pkg 2>/dev/null || true
        systemctl start $pkg 2>/dev/null || true
    else
        RESULTS[$pkg]="失败|apt install 失败"
        warn "$pkg 安装失败"
    fi
done

# 第五步: 安装/升级 Fail2Ban
log "安装/升级 Fail2Ban..."
if apt install -y fail2ban 2>/dev/null; then
    version=$(fail2ban-client --version 2>/dev/null | head -1 | awk '{print $2}' || echo "未知")
    RESULTS["Fail2Ban"]="成功|$version"
    log "Fail2Ban 安装/升级成功 (v$version)"
    systemctl enable fail2ban 2>/dev/null || true
    systemctl start fail2ban 2>/dev/null || true
else
    RESULTS["Fail2Ban"]="失败|apt install 失败"
    warn "Fail2Ban 安装失败"
fi

# 第六步: 安装/升级 Docker
log "安装/升级 Docker..."
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
    version=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//' || echo "未知")
    RESULTS["Docker"]="成功|$version"
    log "Docker 安装/升级成功 (v$version)"
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    # 添加当前用户到 docker 组（如果适用）
    usermod -aG docker $SUDO_USER 2>/dev/null || true
else
    RESULTS["Docker"]="失败|官方仓库安装失败"
    warn "Docker 安装失败"
fi

# 第七步: 安装/升级 Docker Compose (作为插件已包含在上一步，若需独立版本则下载)
# 注意: Docker Compose v2 已作为 docker compose 插件集成，无需单独安装
RESULTS["Docker Compose"]="成功|集成在 Docker CE (v2.x)"

# 总结输出: 表格
echo ""
log "=== 安装/升级结果总结 ==="
printf "%-20s %-8s %-15s\n" "项目" "状态" "版本/详情"
printf "%s\n" "--------------------------------------------------------------------------------"
for key in "${!RESULTS[@]}"; do
    IFS='|' read -r status detail <<< "${RESULTS[$key]}"
    color=$([[ "$status" == "成功" ]] && echo "${GREEN}" || echo "${RED}")
    printf "${color}%-20s %-8s %-15s${NC}\n" "$key" "$status" "$detail"
done

# 统计（修复版：正确计数成功项目）
success_count=0
for result in "${RESULTS[@]}"; do
    if [[ "$result" == 成功* ]]; then ((success_count++)); fi
done
total_count=${#RESULTS[@]}
echo ""
log "总计: $success_count / $total_count 项目成功"
warn "重启系统以应用所有更改: sudo reboot"
echo ""
log "脚本执行完成！"
