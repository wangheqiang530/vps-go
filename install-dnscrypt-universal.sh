#!/usr/bin/env bash
set -euo pipefail

REPO="DNSCrypt/dnscrypt-proxy"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMPDIR="$(mktemp -d)"
ARCH="$(uname -m)"
echo "arch=${ARCH} tmp=${TMPDIR}"
cd "${TMPDIR}"

apt-get update -y
apt-get install -y curl wget jq tar

# broad asset match to handle various naming conventions
ASSET_URL=$(curl -s "${API_URL}" | jq -r '.assets[].browser_download_url | select(test("linux_.*(arm64|aarch64|arm-|x86_64|x86-64|x86_32|i386)"))' | head -n1)
if [ -z "$ASSET_URL" ]; then
  echo "no asset found; listing assets for debugging:"
  curl -s "${API_URL}" | jq -r '.assets[] | "\(.name) -> \(.browser_download_url)"'
  exit 1
fi

wget -qO release.tar.gz "$ASSET_URL"
tar -xzf release.tar.gz

# find binary anywhere
BINARY=$(find . -type f -name dnscrypt-proxy -perm /111 -print -quit || true)
if [ -z "$BINARY" ]; then
  BINARY=$(find . -type f -name dnscrypt-proxy -print -quit || true)
fi
if [ -z "$BINARY" ]; then
  echo "binary not found; dump tree for debugging:"; find . -maxdepth 3 -type f -print | sed -n '1,200p'; exit 1
fi

install -m 0755 "$BINARY" /usr/local/bin/dnscrypt-proxy

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

# systemd unit
UNIT=$(find . -type f -path '*/linux-systemd/dnscrypt-proxy.service' -print -quit || true)
if [ -n "$UNIT" ]; then
  cp -f "$UNIT" /etc/systemd/system/dnscrypt-proxy.service
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

cp /etc/resolv.conf /etc/resolv.conf.dnscrypt-backup.$(date +%s) 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
if command -v chattr >/dev/null 2>&1; then chattr +i /etc/resolv.conf 2>/dev/null || true; fi

cd /; rm -rf "${TMPDIR}"
echo "done. check: systemctl status dnscrypt-proxy ; dig @127.0.2.1 google.com"
