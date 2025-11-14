#!/usr/bin/env bash
set -euo pipefail

# install-dnscrypt-universal.sh (robust extraction)
# - 自动检测架构（amd64/arm64/armv7/i386）
# - 从 GitHub Releases 下载合适 asset
# - 解压后在任何子目录中寻找 dnscrypt-proxy 可执行文件并安装
# - 覆盖 /etc/dnscrypt-proxy/dnscrypt-proxy.toml，并启用 systemd 服务
# - 强制写 /etc/resolv.conf 指向 127.0.2.1
REPO="DNSCrypt/dnscrypt-proxy"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMPDIR="$(mktemp -d)"
ARCH="$(uname -m)"

echo "Detected architecture: ${ARCH}"
echo "Tempdir: ${TMPDIR}"
cd "${TMPDIR}"

apt-get update -y
apt-get install -y curl wget jq tar

# choose asset regex
case "${ARCH}" in
  x86_64|amd64) ASSET_RE='linux_(x86_64|amd64|x86-64).*\.tar\.gz|linux_x86_64.*\.tar\.gz' ;;
  aarch64|arm64) ASSET_RE='linux_(arm64|aarch64|arm-.*).*\.tar\.gz|linux_arm64.*\.tar\.gz' ;;
  armv7l|armv7) ASSET_RE='linux_armv7.*\.tar\.gz|linux_arm-.*\.tar\.gz' ;;
  i386|i686) ASSET_RE='linux_(x86_32|i386|i486|i686).*\.tar\.gz|linux_x86_32.*\.tar\.gz' ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

echo "Querying GitHub API..."
ASSET_URL=$(curl -sSf "${API_URL}" | jq -r --arg re "${ASSET_RE}" '.assets[] | select(.name | test($re; "i")) | .browser_download_url' | head -n1)
if [ -z "${ASSET_URL}" ] || [ "${ASSET_URL}" = "null" ]; then
  echo "No matching asset found. Available assets:"
  curl -sSf "${API_URL}" | jq -r '.assets[].name + " -> " + .browser_download_url'
  exit 1
fi

echo "Downloading: ${ASSET_URL}"
FNAME="dnscrypt-release.tar.gz"
wget -qO "${FNAME}" "${ASSET_URL}"

echo "Extracting..."
tar -xzf "${FNAME}"

# robust search: find the dnscrypt-proxy binary anywhere under TMPDIR
echo "Searching for dnscrypt-proxy binary..."
BINARY_PATH=$(find . -type f -name dnscrypt-proxy -perm /111 -print -quit || true)

if [ -z "${BINARY_PATH}" ]; then
  # sometimes binary may not be executable in archive; try without exec bit
  BINARY_PATH=$(find . -type f -name dnscrypt-proxy -print -quit || true)
fi

if [ -z "${BINARY_PATH}" ]; then
  echo "Unable to find dnscrypt-proxy binary in archive. Listing tree for debugging:"
  find . -maxdepth 3 -type f -printf '%p\n' | sed -n '1,200p'
  exit 1
fi

echo "Found binary at: ${BINARY_PATH}"
install -m 0755 "${BINARY_PATH}" /usr/local/bin/dnscrypt-proxy
echo "Installed /usr/local/bin/dnscrypt-proxy"

# write config (overwrite)
mkdir -p /etc/dnscrypt-proxy
cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
server_names = ['cloudflare', 'google']
listen_addresses = ['127.0.2.1:53', '[::1]:53']
doh_servers = true
require_dnssec = true
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
EOF
echo "Wrote /etc/dnscrypt-proxy/dnscrypt-proxy.toml"

# install systemd unit if present; otherwise create one
UNIT_DIR=""
if [ -d "./linux-systemd" ]; then UNIT_DIR="./linux-systemd"; fi
if [ -d "./${EXDIR:-}" ] && [ -d "./${EXDIR}/linux-systemd" ]; then UNIT_DIR="./${EXDIR}/linux-systemd"; fi

if [ -n "${UNIT_DIR}" ] && [ -f "${UNIT_DIR}/dnscrypt-proxy.service" ]; then
  mkdir -p /etc/systemd/system
  cp -f "${UNIT_DIR}/dnscrypt-proxy.service" /etc/systemd/system/dnscrypt-proxy.service
  cp -f "${UNIT_DIR}/dnscrypt-proxy.socket" /etc/systemd/system/dnscrypt-proxy.socket 2>/dev/null || true
else
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

systemctl daemon-reload || true
systemctl enable --now dnscrypt-proxy || true
sleep 1
systemctl status dnscrypt-proxy --no-pager -l || true

# override resolv.conf
cp /etc/resolv.conf /etc/resolv.conf.dnscrypt-backup.$(date +%s) 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
if command -v chattr >/dev/null 2>&1; then chattr +i /etc/resolv.conf 2>/dev/null || true; fi

# cleanup
cd /
rm -rf "${TMPDIR}"

echo "安装完成！连续两次查询来检查缓存是否生效： dig @127.0.2.1 google.com"
