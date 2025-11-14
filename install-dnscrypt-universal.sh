#!/usr/bin/env bash
set -euo pipefail

# ===================================================================
# install-dnscrypt-auto.sh
# 完整自动化脚本（非交互），会：
#  - 检测发行版并选择 apt 或 GitHub Releases 安装 dnscrypt-proxy
#  - 如果存在 dnsmasq，则直接卸载 (no backup) 并停止服务
#  - 自动下载 v3 列表/.minisig 和 minisign.pub，提取 minisign_key 并写入配置
#  - 处理端口占用（优先停止常见占用者，否则切换到备用回环地址）
#  - 覆盖 /etc/resolv.conf 指向本地 dnscrypt，尝试写保护（chattr +i）
#  - 安装每周维护脚本（/etc/cron.weekly），每周自动更新 v3 列表与签名
#  - 完全无交互，可重复运行（幂等设计）
#
# 注意：脚本会覆盖 /etc/dnscrypt-proxy/dnscrypt-proxy.toml 与 /etc/resolv.conf。
# ===================================================================

# ------------------------ 配色与日志 ------------------------
CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"   # 蓝
COL_OK="${CSI}1;32m"     # 绿
COL_WARN="${CSI}1;33m"   # 黄
COL_ERR="${CSI}1;31m"    # 红

logfile="/var/log/dnscrypt-install.log"
exec 3>&1 4>&2
# 同时输出到 stdout/stderr 与日志
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile" >&3; }
info() { printf '%b %s%b\n' "$COL_INFO" "$*" "$COL_RESET" | tee -a "$logfile" >&3; }
ok()   { printf '%b %s%b\n' "$COL_OK" "[OK] $*" "$COL_RESET" | tee -a "$logfile" >&3; }
warn() { printf '%b %s%b\n' "$COL_WARN" "[WARN] $*" "$COL_RESET" | tee -a "$logfile" >&3; }
err()  { printf '%b %s%b\n' "$COL_ERR" "[ERROR] $*" "$COL_RESET" | tee -a "$logfile" >&4; }

# 以非交互方式运行（非 root 会退出）
if [ "$(id -u)" -ne 0 ]; then
  err "脚本必须以 root 用户运行"
  exit 1
fi

info "开始：dnscrypt 自动安装脚本（无交互模式）"
log "日志文件：$logfile"

# ------------------------ 基础工具检测并安装 ------------------------
ensure_tools() {
  local need=(curl wget jq tar ss systemctl grep sed awk)
  local toinstall=()
  for c in "${need[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      toinstall+=("$c")
    fi
  done
  if [ ${#toinstall[@]} -gt 0 ]; then
    info "检测到缺少工具：${toinstall[*]}，使用 apt 非交互安装..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${toinstall[@]}"
  else
    ok "必要工具已存在：${need[*]}"
  fi
}

# ------------------------ 识别系统 ------------------------
detect_distro() {
  local id ver
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    id="$ID" || id="unknown"
    ver="$VERSION_ID" || ver="unknown"
  else
    id="unknown"; ver="unknown"
  fi
  printf '%s|%s' "$id" "$ver"
}

# ------------------------ apt 安装尝试 ------------------------
try_apt_install() {
  info "尝试 apt 非交互安装 dnscrypt-proxy（若仓库提供）..."
  apt-get update -y || true
  if DEBIAN_FRONTEND=noninteractive apt-get install -y dnscrypt-proxy; then
    ok "apt 安装 dnscrypt-proxy 成功"
    return 0
  else
    warn "apt 无法安装 dnscrypt-proxy（包缺失或安装失败），将改用 GitHub Releases"
    return 1
  fi
}

# ------------------------ GitHub Releases 安装 ------------------------
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
  info "从 GitHub Releases 下载并安装 dnscrypt-proxy（自动识别架构）"
  local REPO="DNSCrypt/dnscrypt-proxy"
  local API="https://api.github.com/repos/${REPO}/releases/latest"
  local TMP
  TMP=$(mktemp -d)
  local ARCH
  ARCH="$(uname -m)"
  local RE
  RE=$(asset_regex_for_arch "$ARCH")
  if [ -z "$RE" ]; then
    err "不支持的架构：$ARCH"
    return 2
  fi

  # 获取 asset url
  local ASSET_URL
  ASSET_URL=$(curl -sSf "$API" | jq -r --arg re "$RE" '.assets[] | select(.name|test($re; "i")) | .browser_download_url' | head -n1 || true)
  if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    err "在 GitHub release 中未找到匹配的资产（regex=${RE}）"
    rm -rf "$TMP" || true
    return 3
  fi

  info "下载资产：$ASSET_URL"
  wget -qO "$TMP"/dnscrypt-release.tar.gz "$ASSET_URL"
  info "解压资产..."
  tar -xzf "$TMP"/dnscrypt-release.tar.gz -C "$TMP"
  info "查找 dnscrypt-proxy 可执行文件..."
  local BINPATH
  BINPATH=$(find "$TMP" -type f -name dnscrypt-proxy -perm /111 -print -quit || true)
  if [ -z "$BINPATH" ]; then
    BINPATH=$(find "$TMP" -type f -name dnscrypt-proxy -print -quit || true)
  fi
  if [ -z "$BINPATH" ]; then
    err "release 包中未找到 dnscrypt-proxy 二进制"
    find "$TMP" -maxdepth 3 -type f -print | sed -n '1,200p' >> "$logfile" || true
    rm -rf "$TMP" || true
    return 4
  fi

  install -m 0755 "$BINPATH" /usr/local/bin/dnscrypt-proxy
  ok "已安装 /usr/local/bin/dnscrypt-proxy"

  # systemd unit：优先使用 release 中的 unit，如果没有则创建默认 unit
  if [ -d "$TMP/linux-systemd" ] && [ -f "$TMP/linux-systemd/dnscrypt-proxy.service" ]; then
    cp -f "$TMP/linux-systemd/dnscrypt-proxy.service" /etc/systemd/system/dnscrypt-proxy.service
    [ -f "$TMP/linux-systemd/dnscrypt-proxy.socket" ] && cp -f "$TMP/linux-systemd/dnscrypt-proxy.socket" /etc/systemd/system/dnscrypt-proxy.socket 2>/dev/null || true
    ok "已安装 release 提供的 systemd unit"
  else
    info "创建默认 systemd unit"
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
    ok "已创建默认 systemd unit"
  fi

  systemctl daemon-reload || true
  rm -rf "$TMP" || true
  return 0
}

# ------------------------ dnsmasq 检测并卸载 ------------------------
remove_dnsmasq_if_exists() {
  if dpkg -s dnsmasq >/dev/null 2>&1 || command -v dnsmasq >/dev/null 2>&1; then
    info "检测到 dnsmasq，正在卸载（无备份）..."
    # 停止并卸载
    systemctl stop dnsmasq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y dnsmasq || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge || true
    ok "dnsmasq 已卸载（若之前未安装则忽略）"
  else
    ok "未检测到 dnsmasq"
  fi
}

# ------------------------ v3 列表与 minisign 下载 ------------------------
download_v3_files() {
  info "下载 v3 列表、.minisig 文件与 minisign.pub（优先使用 download.dnscrypt.info 镜像）"
  mkdir -p /etc/dnscrypt-proxy
  local base="https://download.dnscrypt.info/dnscrypt-resolvers/v3"
  local curl_opts="--retry 3 --connect-timeout 8 --max-time 30 -fsSL"
  for f in public-resolvers relays; do
    if curl $curl_opts -o /etc/dnscrypt-proxy/${f}.md "${base}/${f}.md"; then
      ok "下载 /etc/dnscrypt-proxy/${f}.md"
    else
      warn "下载 ${f}.md 失败（尝试回退到 GitHub raw）"
      if curl $curl_opts -o /etc/dnscrypt-proxy/${f}.md "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/${f}.md"; then
        ok "回退下载成功：/etc/dnscrypt-proxy/${f}.md"
      else
        warn "回退下载 ${f}.md 也失败，继续（后续可能使用回退解析）"
      fi
    fi
    # minisig
    if curl $curl_opts -o /etc/dnscrypt-proxy/${f}.md.minisig "${base}/${f}.md.minisig"; then
      ok "下载 /etc/dnscrypt-proxy/${f}.md.minisig"
    else
      warn "下载 ${f}.md.minisig 失败（非致命）"
    fi
  done

  if curl $curl_opts -o /etc/dnscrypt-proxy/minisign.pub "${base}/minisign.pub"; then
    ok "下载 /etc/dnscrypt-proxy/minisign.pub"
  else
    warn "下载 minisign.pub 失败（可能网络受限）"
  fi

  chmod 644 /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
  chown root:root /etc/dnscrypt-proxy/*.md* /etc/dnscrypt-proxy/minisign.pub 2>/dev/null || true
}

# ------------------------ 提取 minisign_key 并写配置 ------------------------
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
  info "写入 v3 配置并设置 minisign_key（覆盖 /etc/dnscrypt-proxy/dnscrypt-proxy.toml）"
  # 原子写入
  tmpf="$(mktemp)"
  cat >"$tmpf" <<EOF
# 自动生成的 dnscrypt-proxy v3 配置（可按需修改）
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
  mv "$tmpf" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
  chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
  ok "配置已写入 /etc/dnscrypt-proxy/dnscrypt-proxy.toml"
}

# ------------------------ 应急回退配置（无签名时使用） ------------------------
write_emergency_config() {
  info "写入应急回退配置（fallback_resolvers），确保系统始终能解析"
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
  ok "应急回退配置已写入"
}

# ------------------------ 端口冲突处理 ------------------------
handle_port_conflict_or_start() {
  # 尝试启动 service 并查看是否 active，如果因端口冲突失败，尝试停止常见服务；若不能释放端口，改用备用地址
  systemctl daemon-reload || true
  systemctl enable --now dnscrypt-proxy || true
  sleep 1

  if systemctl is-active --quiet dnscrypt-proxy; then
    ok "dnscrypt-proxy 服务已启动"
    return 0
  fi

  # 检查 journal 中是否包含 bind error / address already in use
  if journalctl -u dnscrypt-proxy -n 40 -o cat | grep -qi 'bind: address already in use'; then
    warn "dnscrypt-proxy 启动失败：端口 127.0.2.1:53 被占用，尝试找出占用进程并停止（常见者：dnsmasq, systemd-resolved, unbound, bind9）"
    # 使用 ss 查找占用进程（UDP/TCP）
    local occ
    occ=$(ss -ltnup 2>/dev/null | grep -E ':53\b' -n || true)
    log "占用 53 的进程信息："
    log "$occ"
    # 尝试停止常见服务
    local services=(dnsmasq systemd-resolved unbound bind9 named)
    for s in "${services[@]}"; do
      if systemctl is-active --quiet "$s" 2>/dev/null || systemctl is-enabled --quiet "$s" 2>/dev/null; then
        warn "检测到并尝试停止 $s"
        systemctl stop "$s" 2>/dev/null || true
        sleep 1
      fi
    done

    # 再次尝试启动 dnscrypt-proxy
    systemctl restart dnscrypt-proxy || true
    sleep 1
    if systemctl is-active --quiet dnscrypt-proxy; then
      ok "停止冲突服务后 dnscrypt-proxy 已成功启动"
      return 0
    fi

    # 如果仍然没有启动，改用备用回环地址 127.0.3.1:53 并重写配置
    warn "仍然无法释放端口，改用备用回环地址 127.0.3.1:53 并重启 dnscrypt-proxy"
    # 备份旧配置并原子替换 listen_addresses
    if [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]; then
      cp -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml.bak.$(date +%s) || true
    fi
    tmpf=$(mktemp)
    # 将 listen_addresses 替换为备用地址（简单方式：生成 new minimal config preserving server_names）
    # 尝试从旧配置读取 server_names，否则使用 cloudflare,google
    local sn
    sn=$(grep -E "^server_names" -n /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null | head -n1 | sed -E "s/.*=//" | tr -d "[:space:]" || true)
    if [ -z "$sn" ]; then sn="['cloudflare','google']"; fi
    cat >"$tmpf" <<EOF
# 自动切换到备用回环地址，因为 127.0.2.1:53 被占用
listen_addresses = ['127.0.3.1:53', '[::1]:53']
server_names = $sn
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
# 如果有 minisign_key，脚本会在后面尝试添加
EOF
    mv "$tmpf" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    systemctl daemon-reload || true
    systemctl restart dnscrypt-proxy || true
    sleep 1
    if systemctl is-active --quiet dnscrypt-proxy; then
      ok "dnscrypt-proxy 已监听在 127.0.3.1:53"
      # 切换 resolv 指向 127.0.3.1
      set_resolv_to_local "127.0.3.1"
      return 0
    else
      err "即使切换到备用地址 dnscrypt-proxy 仍未能启动，请查看日志：journalctl -u dnscrypt-proxy -n 200 -o cat"
      return 1
    fi
  else
    # 不是端口占用问题，输出日志帮助诊断
    err "dnscrypt-proxy 无法启动，请查看日志以获取详细原因"
    journalctl -u dnscrypt-proxy -n 200 -o cat | tee -a "$logfile"
    return 1
  fi
}

# ------------------------ 修改 /etc/resolv.conf 指向本地并尝试写保护 ------------------------
set_resolv_to_local() {
  local addr="$1"
  info "覆盖 /etc/resolv.conf 指向本地 DNS: $addr"
  # 取消 immutable（以免写入被阻止）
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s) 2>/dev/null || true
  cat >/etc/resolv.conf <<EOF
nameserver $addr
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
  # 仅当系统似乎不使用 NetworkManager 或 systemd-resolved 来写 resolv.conf 时才锁定
  if ! (systemctl is-active --quiet NetworkManager 2>/dev/null || systemctl is-active --quiet systemd-resolved 2>/dev/null); then
    if command -v chattr >/dev/null 2>&1; then
      chattr +i /etc/resolv.conf 2>/dev/null || true
      ok "/etc/resolv.conf 已覆盖并尝试写保护 (chattr +i)"
    else
      warn "系统没有 chattr 命令，已覆盖 /etc/resolv.conf 但无法写保护"
    fi
  else
    warn "检测到 NetworkManager 或 systemd-resolved 正在运行，已覆盖 /etc/resolv.conf 但未尝试写保护（以避免冲突）"
  fi
}

# ------------------------ 每周维护脚本安装 ------------------------
install_weekly_maintenance() {
  info "安装每周维护脚本到 /etc/cron.weekly/（每周更新 v3 列表与签名）"
  cat >/usr/local/bin/dnscrypt-maint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG=/var/log/dnscrypt-maint.log
echo "$(date '+%F %T') dnscrypt-maint: 开始" >>"$LOG"
base="https://download.dnscrypt.info/dnscrypt-resolvers/v3"
tmpdir=$(mktemp -d)
cd "$tmpdir"
for f in public-resolvers relays; do
  curl -fsSL -o "${f}.md.new" "${base}/${f}.md" || continue
  curl -fsSL -o "${f}.md.new.minisig" "${base}/${f}.md.minisig" || true
  if [ -f "${f}.md.new" ]; then
    if ! cmp -s "${f}.md.new" "/etc/dnscrypt-proxy/${f}.md" 2>/dev/null; then
      mv "${f}.md.new" "/etc/dnscrypt-proxy/${f}.md"
      mv "${f}.md.new.minisig" "/etc/dnscrypt-proxy/${f}.md.minisig" 2>/dev/null || true
      echo "$(date '+%F %T') dnscrypt-maint: 更新 ${f}.md" >>"$LOG"
      updated=1
    else
      echo "$(date '+%F %T') dnscrypt-maint: ${f}.md 无变化" >>"$LOG"
    fi
  fi
done
# 更新 minisign.pub
curl -fsSL -o /etc/dnscrypt-proxy/minisign.pub "${base}/minisign.pub" || true
# 如果有更新则重启服务
if [ "${updated:-0}" -eq 1 ]; then
  systemctl restart dnscrypt-proxy || true
  echo "$(date '+%F %T') dnscrypt-maint: dnscrypt-proxy 已重启" >>"$LOG"
fi
rm -rf "$tmpdir"
echo "$(date '+%F %T') dnscrypt-maint: 结束" >>"$LOG"
EOF
  chmod 0755 /usr/local/bin/dnscrypt-maint.sh
  # 放到 cron.weekly（覆盖幂等）
  cat >/etc/cron.weekly/dnscrypt-maint <<'EOF'
#!/bin/sh
/usr/local/bin/dnscrypt-maint.sh >/dev/null 2>&1
EOF
  chmod 0755 /etc/cron.weekly/dnscrypt-maint
  ok "每周维护脚本已安装（/etc/cron.weekly/dnscrypt-maint）"
}

# ------------------------ 主流程 ------------------------
ensure_tools

DIST_INFO=$(detect_distro)
DIST_ID=${DIST_INFO%%|*}
DIST_VER=${DIST_INFO##*|}
info "检测到发行版: id=${DIST_ID}, version=${DIST_VER}"

# 决定是否尝试 apt
use_apt=0
if [ "$DIST_ID" = "debian" ]; then
  if [ "$DIST_VER" = "13" ] || echo "$DIST_VER" | grep -qi 'trixie' 2>/dev/null; then
    use_apt=1
    info "Debian 13 (trixie) 将优先使用 apt 安装 dnscrypt-proxy"
  else
    use_apt=0
    info "Debian ${DIST_VER} 跳过 apt，使用 GitHub Releases 安装 dnscrypt-proxy"
  fi
elif [ "$DIST_ID" = "ubuntu" ]; then
  use_apt=1
  info "Ubuntu 系统：先尝试 apt，失败则回退为 GitHub Releases"
else
  use_apt=0
  info "非 Debian/Ubuntu 系统：使用 GitHub Releases 安装 dnscrypt-proxy"
fi

# 卸载 dnsmasq（按你指定，直接卸载、不备份）
remove_dnsmasq_if_exists

# 安装 dnscrypt-proxy（apt 或 github）
installed_via_apt=0
if [ "$use_apt" -eq 1 ]; then
  if try_apt_install; then
    installed_via_apt=1
  else
    install_from_github
  fi
else
  install_from_github
fi

# 确保 /etc/dnscrypt-proxy 目录
mkdir -p /etc/dnscrypt-proxy
chmod 755 /etc/dnscrypt-proxy

# 先写应急配置以保证解析不中断（会被后续更完善配置覆盖）
write_emergency_config

# 下载 v3 列表与 minisign
download_v3_files

# 尝试提取 minisign_key
MINISIGN_KEY=""
if MINISIGN_KEY=$(extract_minisign_key); then
  ok "已提取 minisign_key: $MINISIGN_KEY"
  write_v3_config_with_key "$MINISIGN_KEY"
else
  warn "未能提取 minisign_key（网络或文件问题）。将保留应急回退配置并尝试离线恢复方案"
  # 尝试写入 minimal cloudflare 条目以使 server_names 可用（离线方案，不做签名校验）
  cat >/etc/dnscrypt-proxy/public-resolvers.md <<'EOF'
## cloudflare
Cloudflare DNS (DoH) minimal offline entry
sdns://AgcAAAAAAAAADzE1Mi4xMDkuMjQyLjIwOQovZG9oL2NlcnQ
EOF
  warn "已写入离线 cloudflare minimal 条目到 /etc/dnscrypt-proxy/public-resolvers.md"
  # 覆盖 config 指向 cloudflare
  cat >/etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
listen_addresses = ['127.0.2.1:53']
server_names = ['cloudflare']
doh_servers = true
require_dnssec = true
cache = true
cache_size = 2048
cache_min_ttl = 600
cache_max_ttl = 86400
EOF
  warn "已写入离线配置，dnscrypt-proxy 将以 cloudflare（离线）工作"
fi

# 启动并处理端口冲突
if handle_port_conflict_or_start; then
  ok "dnscrypt-proxy 已部署并尝试启动"
else
  err "dnscrypt-proxy 未能成功启动，请查阅日志：journalctl -u dnscrypt-proxy -n 200 -o cat"
fi

# 设置系统解析为本地 dnscrypt（优先 127.0.2.1；如果脚本切换为 127.0.3.1 则 handle_port_conflict_or_start 已设置）
# 若 dnscrypt-proxy 在 127.0.3.1 上监听则检测并使用
if ss -ltnup 2>/dev/null | grep -q '127.0.3.1:53'; then
  set_resolv_to_local "127.0.3.1"
else
  set_resolv_to_local "127.0.2.1"
fi

# 安装每周维护脚本
install_weekly_maintenance

# 最后输出状态与日志片段
systemctl status dnscrypt-proxy --no-pager -l || true
journalctl -u dnscrypt-proxy -n 120 -o cat | sed -n '1,200p' >> "$logfile" || true

if systemctl is-active --quiet dnscrypt-proxy; then
  ok "全部完成：dnscrypt-proxy 已运行 (active)。建议观察 24 小时以确认稳定性。"
  ok "每周维护脚本已安装到 /etc/cron.weekly/dnscrypt-maint（每周运行一次）"
  ok "日志文件：$logfile"
  exit 0
else
  err "安装完成但 dnscrypt-proxy 未处于 active。请查看日志：journalctl -u dnscrypt-proxy -n 200 -o cat"
  err "日志文件：$logfile"
  exit 1
fi
