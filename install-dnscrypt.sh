#!/bin/bash
set -e

echo "=== 安装 dnscrypt-proxy ==="
apt update
apt install -y dnscrypt-proxy

CONFIG=/etc/dnscrypt-proxy/dnscrypt-proxy.toml

echo "=== 配置 dnscrypt-proxy ==="

sed -i "s/^#*server_names =.*/server_names = ['cloudflare','google']/" $CONFIG
sed -i "s/^#*cache =.*/cache = true/" $CONFIG
sed -i "s/^#*cache_size =.*/cache_size = 2048/" $CONFIG
sed -i "s/^#*cache_min_ttl =.*/cache_min_ttl = 600/" $CONFIG
sed -i "s/^#*cache_max_ttl =.*/cache_max_ttl = 86400/" $CONFIG
sed -i "s/^#*require_dnssec =.*/require_dnssec = true/" $CONFIG

echo "=== 重启 dnscrypt-proxy ==="
systemctl restart dnscrypt-proxy
systemctl enable dnscrypt-proxy

echo "=== 配置系统 DNS ==="
if [[ -L /etc/resolv.conf ]] && [[ "$(readlink /etc/resolv.conf)" == *"systemd"* ]]; then
    echo "systemd-resolved 模式"
    sed -i "s/^#*DNS=.*/DNS=127.0.2.1/" /etc/systemd/resolved.conf
    sed -i "s/^#*FallbackDNS=.*/FallbackDNS=1.1.1.1 8.8.8.8/" /etc/systemd/resolved.conf
    sed -i "s/^#*DNSStubListener=.*/DNSStubListener=no/" /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
else
    echo "普通 resolv.conf 模式"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.2.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf
fi

echo "=== 安装完成，测试命令： dig @127.0.2.1 google.com ==="
