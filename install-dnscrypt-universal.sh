#!/usr/bin/env bash
set -euo pipefail

# install-dnscrypt-universal.sh
# 直接覆盖配置版本（无交互、无备份保留）
# 支持架构： x86_64 (amd64), aarch64 (arm64), armv7, i386
# 说明：需以 root 运行（sudo）。脚本会：
#  - 从 GitHub Releases 下载适配架构的 dnscrypt-proxy 二进制包
#  - 安装二进制到 /usr/local/bin/dnscrypt-proxy
#  - 写入固定配置到 /etc/dnscrypt-proxy/dnscrypt-proxy.toml（覆盖）
#  - 安装/创建 systemd unit 并启用服务
#  - 覆盖 /etc/resolv.conf 指向 127.0.2.1 并尝试写保护

REPO="DNSCrypt/dnscrypt-proxy"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMPDIR="$(mktemp -d)"
ARCH="$(uname -m)"

echo "Detected architecture: ${ARCH}"
echo "Using temporary directory: ${TMPDIR}"
cd "${TMPDIR}"

# Install minimal tooling
apt-get update -y
apt-get install -y curl wget jq tar

# Determine asset regex by arch (broader matching to handle variant naming)
case "${ARCH}" in
  x86_64|amd64)
    ASSET_RE='linux_(x86_64|amd64|x86-64).*\.tar\.gz|linux_x86_64.*\.tar\.gz'
    ;;
  aarch64|arm64)
    # match linux_arm64, linux_aarch64, linux_arm-* (some older builds)
    ASSET_RE='linux_(arm64|aarch64|arm-.*).*\.tar\.gz|linux_arm64.*\.tar\.gz'
    ;;
  armv7l|armv7)
    ASSET_RE='linux_armv7.*\.tar\.gz|linux_arm-.*\.tar\.gz'
    ;;
  i386|i686)
    ASSET_RE='linux_(x86_32|i386|i486|i686).*\.tar\.gz|linux_x86_32.*\.tar\.gz'
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

echo "Querying GitHub API for latest dnscrypt-proxy release..."
ASSET_URL=$(curl -sSf "${API_URL}" | jq -r --arg re "${ASSET_RE}" '.assets[] | select(.name | test($re; "i")) | .browser_download_url' | head -n1)

if [ -z "${ASSET_URL}" ] || [ "${ASSET_URL}" = "null" ]; then
  echo "No matching release asset found for arch ${ARCH}."
  echo "Available assets:"
  curl -sSf "${API_URL}" | jq -r '.assets[].name + " -> " + .browser_download_url'
  exit 1
fi

echo "Found asset: ${ASSET_URL}"
FNAME="dnscrypt-release.tar.gz"
echo "Downloading..."
wget -qO "${FNAME}" "${ASSET_URL}"

echo "Extracting..."
tar -xzf "${FNAME}"

# locate extracted directory
EXDIR="$(find . -maxdepth 2 -type d -name 'dnscrypt-proxy*' | head -n1 || true)"
if [ -z "${EXDIR}" ]; then
  # fallback: maybe extraction created a single directory with name matching pattern
  EXDIR="$(ls -d */ | grep -E '^dnscrypt-proxy' | head -n1 || true)"
fi

if [ -z "${EXDIR}" ]; then
  echo "Failed to find extracted directory. Listing current dir:"
  ls -la
  exit 1
fi

echo "Using extracted directory: ${EXDIR}"

# find binary inside extracted dir
BINARY_PATH="$(find "${EXDIR}" -type f -name dnscrypt-proxy -print -quit || true)"
if [ -z "${BINARY_PATH}" ]; then
  echo "dnscrypt-proxy binary not found inside the archive."
  exit 1
fi

echo "Installing binary to /usr/local/bin..."
install -m 0755 "${BINARY_PATH}" /usr/local/bin/dnscrypt-proxy

# ensure config dir exists and overwrite config
echo "Writing configuration to /etc/dnscrypt-proxy/dnscrypt-proxy.toml (overwrite)..."
mkdir -p /etc/dnscrypt-proxy
cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# dnscrypt-proxy minimal recommended config (overwritten by script)
server_names = ['cloudflare', 'google']
listen_addresses = ['127.0.2.1:53', '[::1]:53']
doh_servers = true
require_dnssec = true
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
# Add additional options below if desired
EOF

# Install or copy systemd unit if provided
if [ -d "${EXDIR}/linux-systemd" ] && [ -f "${EXDIR}/linux-systemd/dnscrypt-proxy.service" ]; then
  echo "Installing systemd unit files from release..."
  mkdir -p /etc/systemd/system
  cp -f "${EXDIR}/linux-systemd/dnscrypt-proxy.service" /etc/systemd/system/dnscrypt-proxy.service
  if [ -f "${EXDIR}/linux-systemd/dnscrypt-proxy.socket" ]; then
    cp -f "${EXDIR}/linux-systemd/dnscrypt-proxy.socket" /etc/systemd/system/dnscrypt-proxy.socket
  fi
else
  echo "Creating a simple systemd service unit..."
  cat >/etc/systemd/system/dnscrypt-proxy.service <<'EOF'
[Unit]
Description=DNSCrypt client proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

echo "Reloading systemd and enabling service..."
systemctl daemon-reload || true
systemctl enable --now dnscrypt-proxy || true
sleep 1

echo "Overwriting /etc/resolv.conf to use local dnscrypt-proxy..."
# remove immutable flag if present
if command -v chattr >/dev/null 2>&1; then
  chattr -i /etc/resolv.conf 2>/dev/null || true
fi

cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# attempt to protect resolv.conf
if command -v chattr >/dev/null 2>&1; then
  chattr +i /etc/resolv.conf 2>/dev/null || true
fi

# cleanup
cd /
rm -rf "${TMPDIR}"

echo "Installation complete."
echo "Check service status: systemctl status dnscrypt-proxy --no-pager -l"
echo "Test resolution: dig @127.0.2.1 google.com"
