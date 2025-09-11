#!/bin/bash

# 避免外部干扰，静默处理非预期的输出
exec > >(tee -a init-vps.log) 2>&1

# 检查是否以 root 运行
if [ "$(id -u)" != "0" ]; then
  echo "错误：请以 root 用户运行此脚本" >&2
  exit 1
fi

# 设置日志文件
LOG_FILE="init-vps.log"
touch "$LOG_FILE" || { echo "无法创建日志文件 $LOG_FILE"; exit 1; }
echo "开始 VPS 初始化，日志保存到 $LOG_FILE"

# 函数：检查命令执行结果
check_status() {
  if [ $? -eq 0 ]; then
    echo "✅ $1 成功"
  else
    echo "❌ $1 失败，请检查 $LOG_FILE"
    exit 1
  fi
}

# 1. 优化软件源（使用阿里云镜像）
echo "优化软件源（使用阿里云镜像）..."
cat << EOF > /etc/apt/sources.list
deb http://mirrors.aliyun.com/debian bookworm main contrib non-free
deb http://mirrors.aliyun.com/debian bookworm-updates main contrib non-free
deb http://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free
EOF
apt-get update || { echo "软件源更新失败"; exit 1; }
check_status "软件源更新"

# 2. 安装常用工具
echo "安装常用工具（wget, curl, unzip, rsync, dnsutils）..."
apt-get install -y --no-install-recommends wget curl unzip rsync apt-transport-https ca-certificates gnupg lsb-release dnsutils || { echo "工具安装失败"; exit 1; }
check_status "常用工具安装"

# 3. 检查并安装 systemd-resolved
echo "检查 systemd-resolved 是否存在..."
if ! command -v systemd-resolve > /dev/null; then
  echo "安装 systemd-resolved..."
  apt-get install -y systemd-resolved || { echo "systemd-resolved 安装失败"; exit 1; }
  check_status "systemd-resolved 安装"
fi

# 配置 DNS
echo "配置 DNS（Cloudflare 1.1.1.1）..."
if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
fi
touch /etc/resolv.conf || { echo "无法创建 /etc/resolv.conf"; exit 1; }
echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf
mkdir -p /etc/systemd/resolved.conf.d
cat << EOF > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
EOF
systemctl restart systemd-resolved || { echo "systemd-resolved 重启失败"; exit 1; }
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
grep -q "1.1.1.1" /etc/resolv.conf && check_status "DNS 配置"

# 4. 安装 Docker CE 和 Docker Compose
echo "安装 Docker CE 和 Docker Compose..."
ARCH=$(dpkg --print-architecture)
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || { echo "Docker GPG 密钥添加失败"; exit 1; }
echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update || { echo "Docker 源更新失败"; exit 1; }
apt-get install -y docker-ce docker-ce-cli containerd.io || { echo "Docker CE 安装失败"; exit 1; }
curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || { echo "Docker Compose 下载失败"; exit 1; }
chmod +x /usr/local/bin/docker-compose
docker-compose --version > /dev/null && check_status "Docker Compose 安装"

# 5. 配置 Docker 镜像加速器
echo "配置 Docker 镜像加速器..."
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
systemctl restart docker || { echo "Docker 服务重启失败"; exit 1; }
systemctl enable docker
systemctl enable containerd
systemctl is-active docker > /dev/null && check_status "Docker 服务配置"

# 6. 配置网络接口
echo "配置网络..."
INTERFACE=$(ip link | grep -o '^[0-9]: [a-z0-9]\+: ' | cut -d' ' -f2 | grep -v lo | head -n1)
if [ -n "$INTERFACE" ]; then
  dhclient -v "$INTERFACE" || { echo "网络配置失败"; exit 1; }
  check_status "网络配置（接口: $INTERFACE）"
else
  echo "⚠️ 未找到网络接口，跳过 dhclient"
fi

# 7. 配置 TCP 优化和 BBR
echo "配置 TCP 优化和 BBR..."
if lsmod | grep -q tcp_bbr; then
  echo "BBR 模块已加载"
else
  modprobe tcp_bbr || { echo "加载 BBR 模块失败"; exit 1; }
  check_status "加载 BBR 模块"
fi
cat << EOF >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
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
sysctl -p || { echo "应用 sysctl 配置失败"; exit 1; }
check_status "TCP 和 BBR 配置"
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "✅ BBR 已启用"
else
  echo "❌ BBR 启用失败"
fi

# 8. 设置时区为 Asia/Shanghai
echo "设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai || { echo "时区设置失败"; exit 1; }
timedatectl | grep -q "Asia/Shanghai" && check_status "时区设置"

# 9. 清理缓存
echo "清理 APT 缓存..."
apt-get clean
apt-get autoremove -y || { echo "缓存清理失败"; exit 1; }
check_status "缓存清理"

# 10. 验证结果
echo "=== 验证初始化结果 ==="
echo "1. Docker 版本:"
docker --version || echo "❌ Docker 未安装"
echo "2. Docker Compose 版本:"
docker-compose --version || echo "❌ Docker Compose 未安装"
echo "3. DNS 配置:"
cat /etc/resolv.conf
echo "4. 时区:"
timedatectl
echo "5. 网络接口:"
ip addr show
echo "6. 磁盘空间:"
df -h /
echo "7. BBR 状态:"
sysctl net.ipv4.tcp_congestion_control
lsmod | grep tcp_bbr
echo "======================"
echo "✅ VPS 初始化完成！日志已保存到 $LOG_FILE"
