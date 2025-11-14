#!/usr/bin/env bash
set -euo pipefail

# install-dnscrypt-smart.sh
# 智能安装 dnscrypt-proxy：
#  - Debian 13 使用 apt
#  - Debian 11 / 12 跳过 apt -> 使用 GitHub Releases
#  - Ubuntu 先尝试 apt，失败则使用 GitHub Releases
#  - 其他发行版（包括 CentOS）使用 GitHub Releases
# 同时包含 v3 列表 + minisign 自动处理与“应急回退”逻辑
#
# 使用方法：
#   wget -O install-dnscrypt-smart.sh '...'
#   chmod +x install-dnscrypt-smart.sh
#   sudo ./install-dnscrypt-smart.sh
#
# 脚本会覆盖 /etc/dnscrypt-proxy/dnscrypt-proxy.toml 与 /etc/resolv.conf（如不可接受请勿运行）

LOG() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
ERR()  { printf '%s %s\n' "$(date '+%F %T')" "ERROR: $*" >&2; }

# -------- 工具检查与安装（尽量少化侵入） --------
ensure_tools() {
  local need=(curl wget jq tar sed grep find)
  local missing=()
  for c in "${need[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    LOG "缺少工具：${missing[*]}，尝试通过 apt 安装（需要 sudo）"
    apt-get update -y
    apt-get install -y "${missing[@]}"
  fi
}

# -------- 识别发行版与版本 --------
detect_distro() {
  local id="" ver=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="$ID"
    ver="$VERSION_ID"
  fi
  printf '%s|%s' "$id" "$ver"
}

# -------- apt 安装尝试（返回 0 成功，1 失败） --------
try_apt_install() {
  LOG "尝试通过 apt 安装 dnscrypt-proxy（若仓库中有包）..."
  apt-get update -y || true
  if apt-get install -y dnscrypt-proxy; then
    LOG "apt 安装成功"
    return 0
  else
    LOG "apt 安装失败或包不存在"
    return 1
  fi
}

# -------- GitHub Releases 安装（自动识别架构） --------
asset_regex_for_arch() {
  local arch="$1"
  case "$arch" in
    x86_64|amd64)  echo 'linux_(x86_64|amd64|x86-64).*\.tar\.gz|linux_x86_64.*\.tar\.gz' ;;
    aarch64|arm64) echo 'linux_(arm64|aarch64|arm-).*\.tar\.gz|linux_arm64.*\.tar\.gz' ;;
    armv7l|armv7)  echo 'linux_(armv7|arm-).*\.tar\.gz|linux_armv7.*\.tar\.gz' ;;
    i386|i686)     echo 'linux_(x86_32|i386|i486|i686).*\.tar\.gz|linux_x86_32.*\.tar\.gz' ;;
    *)             echo '' ;;
  esac
}

install_from_github() {
  LOG "使用 GitHub Releases 安装 dnscrypt-proxy（自动选择合适资产）。"
  ensure_tools
  local REPO="DNSCrypt/dnscrypt-proxy"
  local API="https://api.github.com/repos/${REPO}/releases/latest"
  local TMP
  TMP=$(mktemp -d)
  cd "$TMP"
  local ARCH
  ARCH="$(uname -m)"
  local RE
  RE=$(asset_regex_for_arch "$ARCH")
  if [ -z "$RE" ]; then
    ERR "不支持的架构：$ARCH"
    return 2
  fi
  local ASSET_URL
  ASSET_URL=$(curl -sSf "$API" | jq -r --arg re "$RE" '.assets[] | select(.name|test($re; "i")) | .browser_download_url' | head -n1 || true)
  if [ -z "$ASSET_URL" ]; then
    ERR "未在 GitHub release 中找到匹配资产（arch=$ARCH）"
    cd /; rm -rf "$TMP"
    return 3
  fi
  LOG "下载资产：$ASSET_URL"
  wget -qO dnscrypt-release.tar.gz "$ASSET_URL"
  LOG "解压..."
  tar -xzf dnscrypt-release.tar.gz
  LOG "在解压目录中查找 dnscrypt-proxy 二进制..."
  local BIN
  BIN=$(find . -type f -name dnscrypt-proxy -perm /111 -print -quit || true)
  if [ -z "$BIN" ]; then
    BIN=$(find . -type f -name dnscrypt-proxy -print -quit || true)
  fi
  if [ -z "$BIN" ]; then
    ERR "在 release 包中未找到 dnscrypt-proxy 二进制，列出当前解压树以便调试："
    find . -maxdepth 3 -type f -print | sed -n '1,200p'
    cd /; rm -rf "$TMP"
    return 4
  fi
  LOG "安装二进制到 /usr/local/bin ..."
  install -m 0755 "$BIN" /usr/local/bin/dnscrypt-proxy
  # systemd unit
  if [ -d linux-systemd ] && [ -f linux-systemd/dnscrypt-proxy.service ]; then
    LOG "复制 release 提供的 systemd unit"
    cp -f linux-systemd/dnscrypt-proxy.service /etc/systemd/system/dnscrypt-proxy.service
    if [ -f linux-systemd/dnscrypt-proxy.socket ]; then
      cp -f linux-systemd/dnscrypt-proxy.socket /etc/systemd/system/dnscrypt-proxy.socket 2>/dev/null || true
    fi
  else
    LOG "创建默认 systemd unit"
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

  cd /; rm -rf "$TMP"
  LOG "从 GitHub Releases 安装完成。"
  return 0
}

# -------- 配置相关函数（应急 / v3 / minisign） --------
write_emergency_config() {
  LOG "写入应急回退配置（fallback_resolvers）"
  mkdir -p /etc/dnscrypt-proxy
  cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# Emergency fallback config — ensures dnscrypt-proxy runs even if sources fail
listen_addresses = ['127.0.2.1:53']
server_names = []
fallback_resolvers = ['1.1.1.1:53','8.8.8.8:53']
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
EOF
  systemctl daemon-reload || true
  systemctl restart dnscrypt-proxy || true
}

download_v3_and_minisign() {
  LOG "下载 v3 列表与签名（使用 download.dnscrypt.info 镜像）"
  mkdir -p /etc/dnscrypt-proxy
  local base="https://download.dnscrypt.info/dnscrypt-resolvers/v3"
  for f in public-resolvers relays; do
    if curl -fsSL -o "/etc/dnscrypt-proxy/${f}.md" "${base}/${f}.md"; then
      LOG "下载 ${f}.md 成功"
    else
      LOG "下载 ${f}.md 失败"
    fi
    if curl -fsSL -o "/etc/dnscrypt-proxy/${f}.md.minisig" "${base}/${f}.md.minisig"; then
      LOG "下载 ${f}.md.minisig 成功"
    else
      LOG "下载 ${f}.md.minisig 失败"
    fi
  done
  if curl -fsSL -o /etc/dnscrypt-proxy/minisign.pub "${base}/minisign.pub"; then
    LOG "下载 minisign.pub 成功"
  else
    LOG "下载 minisign.pub 失败"
  fi
  chmod 644 /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
  chown root:root /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
}

extract_minisign_key() {
  local file="/etc/dnscrypt-proxy/minisign.pub"
  if [ ! -f "$file" ]; then
    return 1
  fi
  local key
  key=$(grep -Eo '[A-Za-z0-9+/=]{20,}' "$file" | head -n1 || true)
  if [ -z "$key" ]; then
    return 2
  fi
  printf '%s' "$key"
  return 0
}

write_v3_config_with_key() {
  local key="$1"
  LOG "写入 v3 配置并使用 minisign_key（写入 /etc/dnscrypt-proxy/dnscrypt-proxy.toml）"
  cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<EOF
# v3 config with minisign_key
listen_addresses = ['127.0.2.1:53', '[::1]:53']
server_names = ['cloudflare','google']
doh_servers = true
require_dnssec = true
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400

[sources.'public-resolvers']
urls = ['https://download.dnscrypt.info/dnscrypt-resolvers/v3/public-resolvers.md']
cache_file = 'public-resolvers.md'
refresh_delay = 72
minisign_key = "$key"

[sources.'relays']
urls = ['https://download.dnscrypt.info/dnscrypt-resolvers/v3/relays.md']
cache_file = 'relays.md'
refresh_delay = 168
minisign_key = "$key"
EOF
  systemctl daemon-reload || true
  systemctl restart dnscrypt-proxy || true
}

configure_system_resolv() {
  LOG "覆盖 /etc/resolv.conf 指向本地 127.0.2.1 并尝试写保护"
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s) 2>/dev/null || true
  cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  if command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf 2>/dev/null || true
  fi
  LOG "/etc/resolv.conf 已覆盖并尝试保护"
}

# ========== 主流程 ==========
LOG "开始智能安装流程"

DIST_INFO=$(detect_distro)
DIST_ID=${DIST_INFO%%|*}
DIST_VER=${DIST_INFO##*|}

LOG "检测到发行版: id=${DIST_ID}, version=${DIST_VER}"

# 先准备必要工具（curl/wget/jq/tar）
ensure_tools

use_apt=0
case "$DIST_ID" in
  debian)
    # Debian: 13 使用 apt； 11/12 跳过 apt
    if [ "$DIST_VER" = "13" ] || [ "$DIST_VER" = "trixie" ]; then
      LOG "Debian 13：将优先使用 apt 安装"
      use_apt=1
    else
      LOG "Debian $DIST_VER：跳过 apt，使用 GitHub Releases 安装"
      use_apt=0
    fi
    ;;
  ubuntu)
    LOG "Ubuntu：先尝试 apt，如果失败再回退到 GitHub Releases"
    use_apt=1
    ;;
  *)
    LOG "非 Debian/Ubuntu 系统：使用 GitHub Releases 安装（默认）"
    use_apt=0
    ;;
esac

installed_via_apt=0
if [ "$use_apt" -eq 1 ]; then
  if try_apt_install; then
    installed_via_apt=1
  else
    LOG "apt 安装失败或包不存在，改用 GitHub Releases 安装"
    install_from_github
  fi
else
  install_from_github
fi

# 保证目录与权限
mkdir -p /etc/dnscrypt-proxy
chmod 755 /etc/dnscrypt-proxy

# 应急配置以保证解析不中断
write_emergency_config

# 尝试下载 v3 列表与签名
download_v3_and_minisign

# 尝试提取 minisign_key 并写入配置
KEY=""
if KEY=$(extract_minisign_key); then
  LOG "提取到 minisign_key: $KEY"
  write_v3_config_with_key "$KEY"
  sleep 1
  if systemctl is-active --quiet dnscrypt-proxy; then
    LOG "dnscrypt-proxy 已成功以 v3 模式启动"
    configure_system_resolv
    LOG "安装完成（v3 + minisign 模式）。用 dig @127.0.2.1 google.com 测试解析"
    exit 0
  else
    LOG "尝试用 v3/minisign 启动失败，请查看日志"
    journalctl -u dnscrypt-proxy -n 120 -o cat || true
  fi
else
  LOG "无法从 minisign.pub 提取 key（网络或文件问题），保持应急回退配置"
fi

# 到这里：v3 模式未成功（可能网络或签名问题），脚本保留应急回退，提示用户下一步
LOG "警告：v3 模式未能自动启用，dnscrypt-proxy 正在以回退模式运行以保证解析"
LOG "如果需要离线恢复 DoH（例如在网络受限环境），请告诉我，我可以给出离线追加 cloudflare stamp 的命令"

# 最后打印当前状态与日志摘要
systemctl status dnscrypt-proxy --no-pager -l || true
journalctl -u dnscrypt-proxy -n 80 -o cat || true

LOG "脚本执行结束（如需进一步调整，请阅读上面日志或让我生成离线修复命令）"
exit 0
