#!/bin/bash

# 检查是否以 root 运行
if [ "$(id -u)" != "0" ]; then
  echo "错误：请以 root 用户运行此脚本" >&2
  exit 1
fi

# 设置日志文件
LOG_FILE="init-vps.log"
touch "$LOG_FILE"
echo "开始 VPS 初始化，日志保存到 $LOG_FILE" | tee -a "$LOG_FILE"

# 函数：检查命令执行结果并输出到终端和日志
check_status() {
  if [ $? -eq 0 ]; then
    echo "✅ $1 成功" | tee -a "$LOG_FILE"
  else
    echo "❌ $1 失败，请检查 $LOG_FILE" | tee -a "$LOG_FILE"
    exit 1
  fi
}

# 1. 优化软件源（使用阿里云镜像，适合亚太地区）
echo "优化软件源（使用阿里云镜像）..." | tee -a "$LOG_FILE"
cat << EOF > /etc/apt/sources.list
deb http://mirrors.aliyun.com/debian bookworm main contrib non-free
deb http://mirrors.aliyun.com/debian bookworm-updates main contrib non-free
deb http://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free
EOF
apt-get update
check_status "软件源更新"

# 2. 安装常用工具
echo "安装常用工具（wget, curl, unzip, rsync, dnsutils）..." | tee -a "$LOG_FILE"
apt-get install -y --no-install-recommends wget curl unzip rsync apt-transport-https ca-certificates gnupg lsb-release dnsutils
check_status "常用工具安装"

# 3. 检查并安装 systemd-resolved（修复 DNS 问题）
echo "检查 systemd-resolved 是否存在..." | tee -a "$LOG_FILE"
if ! command -v systemd-resolve > /dev/null; then
  echo "安装 systemd-resolved..." | tee -a "$LOG_FILE"
  apt-get install -y systemd-resolved
  check_status "systemd-resolved 安装"
fi

# 配置 DNS（使用 Cloudflare DNS）
echo "配置 DNS（Cloudflare 1.1.1.1）..." | tee -a "$LOG_FILE"
# 确保 /etc/resolv.conf 可写
if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
  sudo chattr -i /etc/resolv.conf 2>/dev/null || true
  sudo rm -f /etc/resolv.conf
fi
sudo touch /etc/resolv.conf
echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf
check_status "临时 DNS 配置"

# 配置 systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
cat << EOF > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
EOF
systemctl restart systemd-resolved
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
cat /etc/resolv.conf | grep -q "1.1.1.1" && check_status "DNS 配置"

# 4. 安装 Docker CE 和 Docker Compose（兼容 arm64 和 x86）
echo "安装 Docker CE 和 Docker Compose..." | tee -a "$LOG_FILE"
ARCH=$(dpkg --print-architecture)
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
check_status "Docker GPG 密钥添加"
echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
check_status "Docker 软件源更新"
apt-get install -y docker-ce docker-ce-cli containerd.io
check_status "Docker CE 安装"
curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
docker-compose --version > /dev/null
check_status "Docker Compose 安装"

# 5. 配置 Docker 镜像加速器（适合新加坡）
echo "配置 Docker 镜像加速器..." | tee -a "$LOG_FILE"
mkdir -p /etc/docker
cat << EOF > /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://dockerhub.azk8s.cn",
    "https://mirror.ccs.tencentyun.com",
    "https://docker.mirrors.ustc.edu.cn"
  ]
}
EOF
systemctl daemon-reload
systemctl restart docker
systemctl enable docker
systemctl enable containerd
systemctl is-active docker > /dev/null
check_status "Docker 服务配置"

# 6. 配置网络（动态检测网络接口）
echo "配置网络..." | tee -a "$LOG_FILE"
INTERFACE=$(ip link | grep -o '^[0-9]: [a-z0-9]\+: ' | cut -d' ' -f2 | grep -v lo | head -n1)
if [ -n "$INTERFACE" ]; then
  dhclient -v "$INTERFACE"
  check_status "网络配置（接口: $INTERFACE）"
else
  echo "⚠️ 未找到网络接口，跳过 dhclient" | tee -a "$LOG_FILE"
fi

# 7. 配置 TCP 优化和 BBR
echo "配置 TCP 优化和 BBR..." | tee -a "$LOG_FILE"
# 检查内核是否支持 BBR
if lsmod | grep -q tcp_bbr; then
  echo "BBR 模块已加载" | tee -a "$LOG_FILE"
else
  modprobe tcp_bbr
  check_status "加载 BBR 模块"
fi

# 启用 BBR
cat << EOF >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# TCP 优化参数
net.core.somaxconn=1024
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_mtu_probing=1
EOF
sysctl -p
check_status "TCP 和 BBR 配置"

# 验证 BBR 是否启用
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "✅ BBR 已启用" | tee -a "$LOG_FILE"
else
  echo "❌ BBR 启用失败" | tee -a "$LOG_FILE"
fi

# 8. 设置时区为 Asia/Shanghai
echo "设置时区为 Asia/Shanghai..." | tee -a "$LOG_FILE"
timedatectl set-timezone Asia/Shanghai
timedatectl | grep -q "Asia/Shanghai" && check_status "时区设置"

# 9. 清理缓存
echo "清理 APT 缓存..." | tee -a "$LOG_FILE"
apt-get clean
apt-get autoremove -y
check_status "缓存清理"

# 10. 验证安装结果
echo "=== 验证初始化结果 ===" | tee -a "$LOG_FILE"
echo "1. Docker 版本:" | tee -a "$LOG_FILE"
docker --version || echo "❌ Docker 未安装" | tee -a "$LOG_FILE"
echo "2. Docker Compose 版本:" | tee -a "$LOG_FILE"
docker-compose --version || echo "❌ Docker Compose 未安装" | tee -a "$LOG_FILE"
echo "3. DNS 配置:" | tee -a "$LOG_FILE"
cat /etc/resolv.conf | tee -a "$LOG_FILE"
echo "4. 时区:" | tee -a "$LOG_FILE"
timedatectl | tee -a "$LOG_FILE"
echo "5. 网络接口:" | tee -a "$LOG_FILE"
ip addr show | tee -a "$LOG_FILE"
echo "6. 磁盘空间:" | tee -a "$LOG_FILE"
df -h / | tee -a "$LOG_FILE"
echo "7. BBR 状态:" | tee -a "$LOG_FILE"
sysctl net.ipv4.tcp_congestion_control | tee -a "$LOG_FILE"
lsmod | grep tcp_bbr | tee -a "$LOG_FILE"
echo "======================" | tee -a "$LOG_FILE"
echo "✅ VPS 初始化完成！日志已保存到 $LOG_FILE" | tee -a "$LOG_FILE"
