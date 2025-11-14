#!/usr/bin/env bash
set -e

# 直接覆盖配置版本（无变量，无交互）
# 支持 aarch64 / x86_64 / armv7 / i386

REPO="DNSCrypt/dnscrypt-proxy"
API="https://api.github.com/repos/${REPO}/releases/latest"
TMPDIR="$(mktemp -d)"
ARCH="$(uname -m)"

echo "Detected arch: $ARCH"
cd "$TMPDIR"

# install required tools
apt-get update -y
apt-get install -y curl wget jq tar

case "$ARCH" in
  x86_64|amd64)   ASSET_RE='linux_x86_64.*\.tar\.gz' ;;
  aarch64|arm64)  ASSET_RE='linux_aarch64.*\.tar\.gz' ;;
  armv7l|armv7)   ASSET_RE='linux_armv7.*\.tar\.gz' ;;
  i386|i686)      ASSET_RE='linux_x86_32.*\.tar\.gz' ;;
  *)
    echo "Unsupported arch: $ARCH"
    exit 1
    ;;
esac

echo "Fetching latest release info..."
ASSET_URL=$(curl -s "$API" | jq -r --arg re "$ASSET_RE" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n 1)

if [ -z "$ASSET_URL" ]; then
    echo "No matching release found for this architecture."
    exit 1
fi

echo "Downloading package..."
wget -q "$ASSET_URL" -O dnscrypt.tar.gz

echo "Extracting..."
tar -xzf dnscrypt.tar.gz

EXDIR=$(find . -maxdepth 1 -type d -name "dnscrypt-proxy*" | head -n1)

echo "Installing binary..."
install -m 755 "$EXDIR/dnscrypt-proxy" /usr/local/bin/dnscrypt-proxy

echo "Installing systemd unit..."
mkdir -p /etc/systemd/system
if [ -f "$EXDIR/linux-systemd/dnscrypt-proxy.service" ]; then
    cp "$EXDIR/linux-systemd/dnscrypt-proxy.service" /etc/systemd/system/dnscrypt-proxy.service
    cp "$EXDIR/linux-systemd/dnscrypt-proxy.socket" /etc/systemd/system/dnscrypt-proxy.socket 2>/dev/null || true
else
cat >/etc/systemd/system/dnscrypt-proxy.service <<EOF
[Unit]
Description=DNSCrypt client proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

echo "Writing config (overwrite)..."
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

echo "Reloading systemd..."
systemctl daemon-reload
systemctl enable --now dnscrypt-proxy

echo "Setting system DNS..."
chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<EOF
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "Cleaning..."
rm -rf "$TMPDIR"

echo "Done!"
echo "Test: dig @127.0.2.1 google.com"
