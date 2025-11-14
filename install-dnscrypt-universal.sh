#!/usr/bin/env bash
set -euo pipefail

# ======================================================================================
# install-dnscrypt-complete.sh
# 一键安装 dnscrypt-proxy（优先 apt，其次从 GitHub Releases 下载）
# 并自动完成 v3 列表 / minisign_key 的下载与配置（包含故障时的应急回退）
#
# 说明（行为会覆盖配置）：
#  - 覆盖 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
#  - 下载并放置 /etc/dnscrypt-proxy/public-resolvers.md(.minisig) 以及 relays.md(.minisig)
#  - 下载并保存 /etc/dnscrypt-proxy/minisign.pub（并从中提取 minisign_key 写入配置）
#  - 安装 systemd 单元并启用服务
#  - 覆盖 /etc/resolv.conf 指向 127.0.2.1（并写保护，若系统支持 chattr）
#
# 运行方式（推荐先保存再执行以便检查）：
#   wget -O install-dnscrypt-complete.sh '...'
#   chmod +x install-dnscrypt-complete.sh
#   sudo ./install-dnscrypt-complete.sh
#
# ======================================================================================

# --------- helper functions ----------
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
err() { echo >&2 "ERROR: $*"; }

# 检查并安装必需工具（curl/wget/jq/tar等）
ensure_tools() {
  local need=(curl wget jq tar)
  local to_install=()
  for cmd in "${need[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      to_install+=("$cmd")
    fi
  done
  if [ ${#to_install[@]} -gt 0 ]; then
    log "缺少工具 ${to_install[*]}，尝试 apt-get 安装（需要 sudo 权限）"
    apt-get update -y
    apt-get install -y "${to_install[@]}"
  fi
}

# 根据 uname -m 选择 release 资产匹配正则
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

# 尝试 apt 安装 dnscrypt-proxy，如果成功返回 0，否则返回非 0
try_apt_install() {
  log "尝试通过 apt 安装 dnscrypt-proxy（若仓库存在）"
  apt-get update -y || true
  if apt-get install -y dnscrypt-proxy; then
    log "apt 安装 dnscrypt-proxy 成功"
    return 0
  else
    log "apt 安装失败或包不存在，准备用 GitHub Releases 方式安装"
    return 1
  fi
}

# 从 GitHub Releases 下载适配架构的包并安装二进制
install_from_github() {
  log "从 GitHub Releases 下载并安装 dnscrypt-proxy 二进制（自动识别架构）"
  local REPO="DNSCrypt/dnscrypt-proxy"
  local API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
  local TMP="$(mktemp -d)"
  cd "$TMP"
  local ARCH="$(uname -m)"
  local ASSET_RE
  ASSET_RE="$(asset_regex_for_arch "$ARCH")"
  if [ -z "$ASSET_RE" ]; then
    err "不支持的架构：$ARCH"
    return 2
  fi

  # 确保工具
  ensure_tools

  # 获取第一个匹配 asset url（case-insensitive）
  local ASSET_URL
  ASSET_URL=$(curl -sSf "${API_LATEST}" | jq -r --arg re "$ASSET_RE" '.assets[] | select(.name | test($re; "i")) | .browser_download_url' | head -n1 || true)
  if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    err "在 GitHub release 中未找到匹配的资产（regex=${ASSET_RE}）"
    cd /; rm -rf "$TMP"
    return 3
  fi

  log "下载资产：$ASSET_URL"
  local FNAME="dnscrypt-release.tar.gz"
  wget -qO "$FNAME" "$ASSET_URL"

  log "解压..."
  tar -xzf "$FNAME"

  # 在任意子目录中查找 dnscrypt-proxy 可执行文件（更鲁棒）
  log "在解压目录中查找 dnscrypt-proxy 可执行文件..."
  local BINPATH
  BINPATH=$(find . -type f -name dnscrypt-proxy -perm /111 -print -quit || true)
  if [ -z "$BINPATH" ]; then
    BINPATH=$(find . -type f -name dnscrypt-proxy -print -quit || true)
  fi
  if [ -z "$BINPATH" ]; then
    err "在 release 包中未找到 dnscrypt-proxy 二进制，解压目录如下："
    find . -maxdepth 3 -type f -print | sed -n '1,200p'
    cd /; rm -rf "$TMP"
    return 4
  fi

  log "安装二进制到 /usr/local/bin ..."
  install -m 0755 "$BINPATH" /usr/local/bin/dnscrypt-proxy

  # 尝试安装 systemd unit（若 release 提供）
  if [ -d "linux-systemd" ] && [ -f "linux-systemd/dnscrypt-proxy.service" ]; then
    log "安装 release 提供的 systemd unit"
    cp -f linux-systemd/dnscrypt-proxy.service /etc/systemd/system/dnscrypt-proxy.service
    if [ -f linux-systemd/dnscrypt-proxy.socket ]; then
      cp -f linux-systemd/dnscrypt-proxy.socket /etc/systemd/system/dnscrypt-proxy.socket 2>/dev/null || true
    fi
  else
    log "未找到 release 中的 systemd 单元，创建默认 unit"
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
  log "github 安装完成"
  return 0
}

# 写入应急回退配置（纯粹保证本机有 DNS）
write_emergency_config() {
  log "写入应急回退配置（fallback_resolvers），以保证系统有解析能力"
  mkdir -p /etc/dnscrypt-proxy
  cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# Emergency fallback config — ensures dnscrypt-proxy runs even if sources fail
listen_addresses = ['127.0.2.1:53']
server_names = []
# fallback_resolvers: plain DNS IPs (not encrypted), used if no server_names are available
fallback_resolvers = ['1.1.1.1:53','8.8.8.8:53']
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
EOF
  systemctl daemon-reload || true
  systemctl restart dnscrypt-proxy || true
}

# 下载 v3 列表、minisig、minisign.pub（尽量使用 download.dnscrypt.info 镜像）
download_v3_and_minisign() {
  log "尝试下载 v3 列表与签名文件（public-resolvers / relays），以及 minisign.pub"
  mkdir -p /etc/dnscrypt-proxy
  local base="https://download.dnscrypt.info/dnscrypt-resolvers/v3"
  # 列表与 minisig
  for f in public-resolvers relays; do
    if curl -fsSL -o /etc/dnscrypt-proxy/${f}.md "${base}/${f}.md"; then
      log "下载 /etc/dnscrypt-proxy/${f}.md 成功"
    else
      log "下载 ${f}.md 失败（网络？），继续但可能需要离线修复"
    fi
    if curl -fsSL -o /etc/dnscrypt-proxy/${f}.md.minisig "${base}/${f}.md.minisig"; then
      log "下载 /etc/dnscrypt-proxy/${f}.md.minisig 成功"
    else
      log "下载 ${f}.md.minisig 失败（网络？），继续"
    fi
  done

  # minisign 公钥（官方）
  local minisign_url="https://download.dnscrypt.info/dnscrypt-resolvers/v3/minisign.pub"
  if curl -fsSL -o /etc/dnscrypt-proxy/minisign.pub "$minisign_url"; then
    log "下载 /etc/dnscrypt-proxy/minisign.pub 成功"
  else
    log "下载 minisign.pub 失败（网络受限？）"
  fi

  chmod 644 /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
  chown root:root /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
}

# 从 minisign.pub 中提取 minisign_key（base64-like 字符串）
extract_minisign_key() {
  local file="/etc/dnscrypt-proxy/minisign.pub"
  if [ ! -f "$file" ]; then
    return 1
  fi
  # 提取看起来像 base64 的长串作为 key
  local key
  key=$(grep -Eo '[A-Za-z0-9+/=]{20,}' "$file" | head -n1 || true)
  if [ -z "$key" ]; then
    return 2
  fi
  printf '%s' "$key"
  return 0
}

# 覆盖写入正式的 v3 配置（包含 minisign_key）
write_v3_config_with_key() {
  local key="$1"
  log "写入最终配置（v3 sources + minisign_key），minisign_key=$key"
  cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<EOF
# v3 config with minisign_key
listen_addresses = ['127.0.2.1:53', '[::1]:53']

# 默认使用 cloudflare + google（可按需修改，名字必须在 public-resolvers.md 中）
server_names = ['cloudflare','google']

doh_servers = true
require_dnssec = true

# 缓存调优
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400

# v3 sources，显式使用 download.dnscrypt.info 镜像路径（更稳定）
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
}

# 设置系统 DNS（覆盖 /etc/resolv.conf）并尝试加锁
configure_system_resolv() {
  log "覆盖 /etc/resolv.conf 指向本地 127.0.2.1，并保留 1.1.1.1 / 8.8.8.8 作为后备"
  # 先取消 immutable（以免写入失败）
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  cp /etc/resolv.conf /etc/resolv.conf.preset-backup.$(date +%s) 2>/dev/null || true
  cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.2.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  # 尝试锁定文件避免 dhclient 等覆盖（可选）
  if command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf 2>/dev/null || true
  fi
  log "/etc/resolv.conf 已覆盖（如需恢复请运行: chattr -i /etc/resolv.conf 然后恢复备份）"
}

# 主流程开始
log "== dnscrypt 一键安装脚本开始 =="

# 1) 尝试 apt 安装（优先）
if try_apt_install; then
  log "使用 apt 安装的 dnscrypt-proxy；继续进行配置（v3/sources/minisign 等）"
else
  # 如果 apt 安装失败则走 GitHub Releases 安装
  log "apt 安装不可用，改用 GitHub Releases 下载安装"
  ensure_tools
  install_from_github
fi

# 2) 确保 /etc/dnscrypt-proxy 目录存在
mkdir -p /etc/dnscrypt-proxy
chmod 755 /etc/dnscrypt-proxy

# 3) 写入应急配置并启动服务，保证系统能解析（若服务无法启动也继续尝试下载签名）
write_emergency_config

# 检查本地服务是否响应（重试一次）
sleep 1
if dig @127.0.2.1 google.com +short >/dev/null 2>&1; then
  log "应急模式：本地 dnscrypt-proxy 已可用（回退解析）"
else
  log "应急模式未能立即响应（可能 systemd unit 未就绪），但继续尝试下载 v3 列表与签名"
fi

# 4) 下载 v3 列表、minisig、minisign.pub
download_v3_and_minisign

# 5) 尝试从 minisign.pub 中提取 minisign_key 并写入配置
KEY=""
if KEY=$(extract_minisign_key); then
  log "从 /etc/dnscrypt-proxy/minisign.pub 成功提取 minisign_key: $KEY"
  write_v3_config_with_key "$KEY"
  # 重启并观察
  systemctl daemon-reload || true
  systemctl restart dnscrypt-proxy || true
  sleep 1
else
  log "无法从 minisign.pub 提取 key（网络或文件问题）。将保留应急回退配置，下面会尝试离线修复方案。"
fi

# 6) 检查服务是否 active，如果不是，给予提示并提供备用离线修复步骤
if systemctl is-active --quiet dnscrypt-proxy; then
  log "dnscrypt-proxy 服务已激活（active）。进行系统 DNS 指向与最终检查。"
  configure_system_resolv
  log "安装并配置完成。请用：dig @127.0.2.1 google.com 测试解析，两次查询以验证缓存命中。"
  log "查看日志：journalctl -u dnscrypt-proxy -n 200 -o cat"
  exit 0
fi

# 到这里服务仍未激活 -> 可能是 minisign / signature 校验或网络问题
log "dnscrypt-proxy 服务未能使用 v3 正式模式启动。查看最近 120 行日志："
journalctl -u dnscrypt-proxy -n 120 -o cat || true

# 离线紧急修复：将 cloudflare 的 minimal stamp 条目追加到本地 public-resolvers.md（当网络受限时可用）
# 说明：这个操作会让 'cloudflare' 可用（在极端网络限制时有用），但不做强制，提示用户是否需要
cat <<'EOF'

===============================================================================
注意：当前 dnscrypt-proxy 尚未以 v3 签名验证模式启动。可能原因：
 - 无法从 download.dnscrypt.info 刷新 v3 列表或 minisign.pub（网络问题）
 - minisign.pub 无法提取或签名验证失败

脚本已启用“回退解析”保障系统可用（使用 1.1.1.1 / 8.8.8.8）。
如果你希望脚本**离线追加 Cloudflare 条目**（在无网络环境下也能让 server_names = ['cloudflare'] 可用），
请在 shell 中运行下面的命令（脚本不会自动执行此步骤，避免未经你同意修改解析来源）：

# 以下命令会把 cloudflare 的 sdns stamp 追加到 /etc/dnscrypt-proxy/public-resolvers.md
# 并把配置改为 server_names = ['cloudflare']（开启 DoH）
# 若需要请复制粘贴执行：
cat >/etc/dnscrypt-proxy/public-resolvers.md <<'CLOUDFLARE_MINIMAL'
## cloudflare
Cloudflare DNS (DoH) minimal entry for offline usage
sdns://AgcAAAAAAAAADzE1Mi4xMDkuMjQyLjIwOQovZG9oL2NlcnQ
CLOUDFLARE_MINIMAL

cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'CLOUDFLARE_CONF'
listen_addresses = ['127.0.2.1:53']
server_names = ['cloudflare']
doh_servers = true
require_dnssec = true
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
EOF

echo
log "脚本执行结束：dnscrypt-proxy 当前未处于 active（v3 签名）模式。你可以："
echo "  1) 检查 /etc/dnscrypt-proxy/minisign.pub 与 /etc/dnscrypt-proxy/*.md 是否完整"
echo "  2) 查看日志以获得错误详情： journalctl -u dnscrypt-proxy -n 200 -o cat"
echo "  3) 如需要，我可以生成一段命令把 cloudflare 的离线条目写入并启用（见上面说明）"
echo "==============================================================================="

exit 0
