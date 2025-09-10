#!/bin/bash

# 检查是否以 root 运行
if [ "$(id -u)" != "0" ]; then
  echo "请以 root 用户运行此脚本" >&2
  exit 1
fi

# 设置日志输出
exec > init-vps.log 2>&1

# 1. 优化软件源（使用阿里云镜像，适合亚太地区）
echo "优化软件源（使用阿里云镜像）..."
cat << EOF > /etc/apt/sources.list
deb https://mirrors.aliyun.com/debian bookworm main contrib non-free
deb https://mirrors.aliyun.com/debian bookworm-updates main contrib non-free
deb https://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free
EOF
apt-get update

# 2. 安装常用工具（避免重复安装 sudo 和 bash）
echo "安装常用工具..."
apt-get install -y --no-install-recommends wget curl unzip rsync apt-transport-https ca-certificates gnupg lsb-release

# 3. 配置 DNS（使用 Cloudflare DNS）
echo "配置 DNS（Cloudflare 1.1.1.1）..."
mkdir -p /etc/systemd/resolved.conf.d
cat << EOF > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
EOF
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# 4. 安装 Docker CE 和 Docker Compose（arm64）
echo "安装 Docker CE 和 Docker Compose..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io
curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 5. 配置 Docker 镜像加速器（适合新加坡）
echo "配置 Docker 镜像加速器..."
mkdir -p /etc/docker
cat << EOF > /etc/docker/daemon.json
{
  "registry-mirrors": ["https://dockerhub.azk8s.cn", "https://mirror.ccs.tencentyun.com"]
}
EOF
systemctl daemon-reload
systemctl restart docker
systemctl enable docker
systemctl enable containerd

# 6. 配置网络（动态检测网络接口，兼容 IPv4/IPv6）
echo "配置网络..."
INTERFACE=$(ip link | grep -o '^[0-9]: [a-z0-9]\+: ' | cut -d' ' -f2 | grep -v lo | head -n1)
if [ -n "$INTERFACE" ]; then
  dhclient -v "$INTERFACE"
else
  echo "未找到网络接口，跳过 dhclient" >&2
fi

# 7. 设置时区为 Asia/Shanghai
echo "设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 8. 清理缓存
echo "清理 APT 缓存..."
apt-get clean
apt-get autoremove -y

# 9. 验证安装
echo "验证安装..."
echo "Docker 版本:"
docker --version
echo "Docker Compose 版本:"
docker-compose --version
echo "DNS 配置:"
cat /etc/resolv.conf
echo "时区:"
timedatectl
echo "网络接口:"
ip addr show

echo "VPS 初始化完成！"
