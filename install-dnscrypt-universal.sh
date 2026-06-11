#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-dnscrypt-universal.sh
# 作用：为 Debian 11/12/13 精简 VPS 自动安装并配置 dnscrypt-proxy。
# 设计目标：
# - 自动安装所需 apt 依赖，无需手动补包。
# - 不依赖 rsyslog、cron、NetworkManager 或 systemd-resolved。
# - 不假设 IPv6 可用，默认只监听 IPv4 回环地址，避免 IPv6 bind 报错。
# - 只有 dnscrypt-proxy 启动并通过解析测试后，才修改 /etc/resolv.conf。
# - 使用 systemd timer 做健康检查，不依赖 cron.weekly。
#
# 可选环境变量：
#   DNSCRYPT_LISTEN_IPV4=127.0.2.1       本地监听地址
#   DNSCRYPT_SERVERS=cloudflare,google   上游服务器名，逗号分隔
#   LOCK_RESOLV=1                        写入 /etc/resolv.conf 后使用 chattr +i 锁定

DNSCRYPT_LISTEN_IPV4="${DNSCRYPT_LISTEN_IPV4:-127.0.2.1}"
DNSCRYPT_SERVERS="${DNSCRYPT_SERVERS:-cloudflare,google}"
LOCK_RESOLV="${LOCK_RESOLV:-0}"
LOG_FILE="/var/log/dnscrypt-install.log"
BACKUP_DIR="/root/dnscrypt-backup-$(date +%Y%m%d-%H%M%S)"
TMP_DIR=""

CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"
COL_OK="${CSI}1;32m"
COL_WARN="${CSI}1;33m"
COL_ERR="${CSI}1;31m"

log_line() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
info() { printf '%b[INFO]%b %s\n' "$COL_INFO" "$COL_RESET" "$*"; log_line "[INFO] $*"; }
ok() { printf '%b[OK]%b %s\n' "$COL_OK" "$COL_RESET" "$*"; log_line "[OK] $*"; }
warn() { printf '%b[WARN]%b %s\n' "$COL_WARN" "$COL_RESET" "$*"; log_line "[WARN] $*"; }
err() { printf '%b[ERROR]%b %s\n' "$COL_ERR" "$COL_RESET" "$*" >&2; log_line "[ERROR] $*"; }

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行脚本，例如：curl -fsSL URL | bash" >&2
    exit 1
  fi
}

validate_listen_ipv4() {
  local IFS=.
  local -a octets
  local octet

  if [[ ! "$DNSCRYPT_LISTEN_IPV4" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    err "DNSCRYPT_LISTEN_IPV4 不是有效 IPv4 地址：$DNSCRYPT_LISTEN_IPV4"
    exit 1
  fi

  read -r -a octets <<< "$DNSCRYPT_LISTEN_IPV4"
  if [ "${#octets[@]}" -ne 4 ] || [ "${octets[0]}" != "127" ]; then
    err "DNSCRYPT_LISTEN_IPV4 必须使用 127.0.0.0/8 回环地址，当前为：$DNSCRYPT_LISTEN_IPV4"
    exit 1
  fi

  for octet in "${octets[@]}"; do
    if (( 10#$octet > 255 )); then
      err "DNSCRYPT_LISTEN_IPV4 包含无效段：$DNSCRYPT_LISTEN_IPV4"
      exit 1
    fi
  done
}

require_debian_systemd() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "未找到 apt-get。此脚本仅面向 Debian/Ubuntu 系系统。"
    exit 1
  fi

  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    err "当前系统未运行 systemd。Debian 11/12/13 VPS 通常默认使用 systemd。"
    exit 1
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu)
        info "检测到系统：${PRETTY_NAME:-$ID}"
        ;;
      *)
        warn "当前系统不是 Debian/Ubuntu：${PRETTY_NAME:-unknown}，继续尝试安装。"
        ;;
    esac
  fi
}

backup_existing_files() {
  mkdir -p "$BACKUP_DIR"

  for item in \
    /etc/dnscrypt-proxy \
    /etc/systemd/system/dnscrypt-proxy.service \
    /etc/systemd/system/dnscrypt-proxy.socket \
    /etc/systemd/system/dnscrypt-proxy-healthcheck.service \
    /etc/systemd/system/dnscrypt-proxy-healthcheck.timer \
    /usr/local/bin/dnscrypt-proxy \
    /usr/local/sbin/dnscrypt-proxy-healthcheck \
    /etc/resolv.conf; do
    if [ -e "$item" ] || [ -L "$item" ]; then
      cp -a "$item" "$BACKUP_DIR/" 2>/dev/null || true
    fi
  done

  ok "已备份现有 DNSCrypt/DNS 配置到：$BACKUP_DIR"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive

  info "更新 apt 软件源"
  apt-get update -y

  info "安装 Debian 精简系统所需依赖"
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    tar \
    gzip \
    iproute2 \
    bind9-dnsutils \
    procps \
    coreutils \
    grep \
    sed \
    findutils \
    e2fsprogs

  ok "依赖安装完成"
}

asset_regex_for_arch() {
  local arch="$1"
  case "$arch" in
    x86_64|amd64)
      printf '%s\n' '^dnscrypt-proxy-linux_x86_64-[0-9].*\.tar\.gz$'
      ;;
    aarch64|arm64)
      printf '%s\n' '^dnscrypt-proxy-linux_arm64-[0-9].*\.tar\.gz$'
      ;;
    armv7l|armv6l|armhf|arm)
      printf '%s\n' '^dnscrypt-proxy-linux_arm-[0-9].*\.tar\.gz$'
      ;;
    i386|i686)
      printf '%s\n' '^dnscrypt-proxy-linux_i386-[0-9].*\.tar\.gz$|^dnscrypt-proxy-linux_x86-[0-9].*\.tar\.gz$'
      ;;
    *)
      printf '%s\n' ''
      ;;
  esac
}

install_dnscrypt_from_github() {
  local repo="DNSCrypt/dnscrypt-proxy"
  local api="https://api.github.com/repos/${repo}/releases/latest"
  local arch re download_url archive bin_path example_path version

  arch="$(uname -m)"
  re="$(asset_regex_for_arch "$arch")"
  if [ -z "$re" ]; then
    err "不支持的 CPU 架构：$arch"
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  archive="$TMP_DIR/dnscrypt-proxy.tar.gz"

  info "从 GitHub Releases 获取 dnscrypt-proxy 最新版本信息"
  download_url="$(curl -fsSL "$api" | jq -r --arg re "$re" '.assets[] | select(.name | test($re; "i")) | .browser_download_url' | head -n 1 || true)"
  if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
    err "未找到匹配当前架构的 dnscrypt-proxy Release 包，架构：$arch，匹配规则：$re"
    exit 1
  fi

  info "下载：$download_url"
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$archive" "$download_url"

  info "解压 dnscrypt-proxy"
  tar -xzf "$archive" -C "$TMP_DIR"

  bin_path="$(find "$TMP_DIR" -type f -name dnscrypt-proxy -perm -111 -print -quit || true)"
  if [ -z "$bin_path" ]; then
    bin_path="$(find "$TMP_DIR" -type f -name dnscrypt-proxy -print -quit || true)"
  fi
  if [ -z "$bin_path" ]; then
    err "Release 包中未找到 dnscrypt-proxy 可执行文件。"
    exit 1
  fi

  install -m 0755 "$bin_path" /usr/local/bin/dnscrypt-proxy
  version="$(/usr/local/bin/dnscrypt-proxy -version 2>/dev/null || true)"
  ok "已安装 /usr/local/bin/dnscrypt-proxy ${version:+($version)}"

  mkdir -p /etc/dnscrypt-proxy
  example_path="$(find "$TMP_DIR" -type f -name example-dnscrypt-proxy.toml -print -quit || true)"
  if [ -z "$example_path" ]; then
    err "Release 包中未找到 example-dnscrypt-proxy.toml，无法生成可靠配置。"
    exit 1
  fi

  cp -f "$example_path" /etc/dnscrypt-proxy/example-dnscrypt-proxy.toml
  ok "已保存官方示例配置：/etc/dnscrypt-proxy/example-dnscrypt-proxy.toml"
}

ipv6_available() {
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
    return 1
  fi

  if command -v ip >/dev/null 2>&1 && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

toml_server_names() {
  local input="$1"
  local result=""
  local name

  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      if [ -z "$result" ]; then
        result="'$name'"
      else
        result="$result, '$name'"
      fi
    elif [ -n "$name" ]; then
      warn "忽略非法 DNSCrypt server 名称：$name" >&2
    fi
  done < <(printf '%s\n' "$input" | tr ',' '\n')

  if [ -z "$result" ]; then
    warn "未解析到有效 DNSCrypt server 名称，回退到 cloudflare,google" >&2
    result="'cloudflare', 'google'"
  fi

  printf '[%s]\n' "$result"
}

set_top_level_toml() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN {
      done = 0
      in_top_level = 1
      key_re = "^[[:space:]]*" key "[[:space:]]*="
    }

    in_top_level && /^[[:space:]]*\[/ {
      if (!done) {
        print key " = " value
        done = 1
      }
      in_top_level = 0
      print
      next
    }

    in_top_level && $0 ~ key_re {
      if (!done) {
        print key " = " value
        done = 1
      }
      next
    }

    { print }

    END {
      if (!done) {
        print key " = " value
      }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_dnscrypt_config() {
  local config="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  local listen_toml servers_toml ipv6_bool

  cp -f /etc/dnscrypt-proxy/example-dnscrypt-proxy.toml "$config"

  # VPS 本机只需要 IPv4 回环监听。AAAA 查询仍可通过 IPv4 上游返回。
  listen_toml="['${DNSCRYPT_LISTEN_IPV4}:53']"
  servers_toml="$(toml_server_names "$DNSCRYPT_SERVERS")"

  if ipv6_available; then
    ipv6_bool="true"
    info "检测到系统 IPv6 可用：允许 dnscrypt-proxy 选择 IPv6 上游服务器"
  else
    ipv6_bool="false"
    info "未检测到可用 IPv6：禁用 IPv6 上游服务器，避免精简 VPS 报错"
  fi

  set_top_level_toml "$config" "listen_addresses" "$listen_toml"
  set_top_level_toml "$config" "server_names" "$servers_toml"
  set_top_level_toml "$config" "ipv4_servers" "true"
  set_top_level_toml "$config" "ipv6_servers" "$ipv6_bool"
  set_top_level_toml "$config" "dnscrypt_servers" "true"
  set_top_level_toml "$config" "doh_servers" "true"
  set_top_level_toml "$config" "odoh_servers" "false"
  set_top_level_toml "$config" "require_dnssec" "true"
  set_top_level_toml "$config" "require_nolog" "false"
  set_top_level_toml "$config" "require_nofilter" "false"
  set_top_level_toml "$config" "cache" "true"
  set_top_level_toml "$config" "cache_size" "2048"
  set_top_level_toml "$config" "cache_min_ttl" "600"
  set_top_level_toml "$config" "cache_max_ttl" "86400"
  set_top_level_toml "$config" "bootstrap_resolvers" "['1.1.1.1:53', '8.8.8.8:53', '9.9.9.9:53']"
  set_top_level_toml "$config" "ignore_system_dns" "true"
  set_top_level_toml "$config" "netprobe_timeout" "30"
  set_top_level_toml "$config" "log_level" "2"
  set_top_level_toml "$config" "use_syslog" "true"

  chmod 0644 "$config"
  ok "已生成配置：$config"
}

write_systemd_unit() {
  systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
  systemctl stop dnscrypt-proxy >/dev/null 2>&1 || true

  cat > /etc/systemd/system/dnscrypt-proxy.service <<'EOF'
[Unit]
Description=DNSCrypt client proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/dnscrypt-proxy
ExecStart=/usr/local/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "已写入 systemd unit：/etc/systemd/system/dnscrypt-proxy.service"
}

service_logs() {
  journalctl -u dnscrypt-proxy --no-pager -n 120 -o cat 2>/dev/null || true
}

start_and_test_dnscrypt() {
  local attempt

  info "启动 dnscrypt-proxy"
  systemctl enable dnscrypt-proxy >/dev/null 2>&1
  systemctl restart dnscrypt-proxy || true
  sleep 4

  if ! systemctl is-active --quiet dnscrypt-proxy; then
    warn "首次启动失败，检查是否为端口冲突"
    service_logs | tail -n 80 >&2 || true

    if service_logs | grep -Eqi 'address already in use|bind'; then
      warn "检测到端口绑定失败，切换监听地址到 127.0.3.1 后重试"
      DNSCRYPT_LISTEN_IPV4="127.0.3.1"
      write_dnscrypt_config
      systemctl restart dnscrypt-proxy || true
      sleep 4
    fi
  fi

  if ! systemctl is-active --quiet dnscrypt-proxy; then
    err "dnscrypt-proxy 未能启动。未修改 /etc/resolv.conf。最近日志如下："
    service_logs >&2 || true
    exit 1
  fi

  info "测试本地 DNSCrypt 解析"
  for attempt in 1 2 3; do
    if dig @"$DNSCRYPT_LISTEN_IPV4" debian.org A +time=5 +tries=1 +short | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      ok "本地 DNSCrypt 解析测试通过：@$DNSCRYPT_LISTEN_IPV4"
      return 0
    fi
    warn "解析测试第 ${attempt} 次失败，等待后重试"
    sleep 3
    systemctl restart dnscrypt-proxy || true
    sleep 3
  done

  err "dnscrypt-proxy 已启动，但解析测试失败。未修改 /etc/resolv.conf。最近日志如下："
  service_logs >&2 || true
  exit 1
}

write_resolv_conf() {
  local resolv="/etc/resolv.conf"

  info "写入系统 DNS：$resolv -> $DNSCRYPT_LISTEN_IPV4"

  if command -v chattr >/dev/null 2>&1; then
    chattr -i "$resolv" 2>/dev/null || true
  fi

  cp -a "$resolv" "$BACKUP_DIR/resolv.conf.before-dnscrypt" 2>/dev/null || true

  if [ -L "$resolv" ]; then
    rm -f "$resolv"
  fi

  cat > "$resolv" <<EOF
nameserver $DNSCRYPT_LISTEN_IPV4
options timeout:2 attempts:2
EOF

  chmod 0644 "$resolv"

  if [ "$LOCK_RESOLV" = "1" ]; then
    if command -v chattr >/dev/null 2>&1; then
      chattr +i "$resolv" 2>/dev/null || warn "尝试 chattr +i $resolv 失败，可能是文件系统不支持。"
      ok "已尝试锁定 $resolv"
    else
      warn "未找到 chattr，无法锁定 $resolv"
    fi
  fi

  ok "系统 DNS 已指向本地 dnscrypt-proxy"
}

final_system_dns_test() {
  info "测试系统默认 DNS 解析"

  if getent ahostsv4 debian.org >/dev/null 2>&1; then
    ok "系统默认 DNS 解析正常"
  else
    err "系统默认 DNS 解析失败。尝试恢复安装前 resolv.conf。"
    if [ -f "$BACKUP_DIR/resolv.conf.before-dnscrypt" ]; then
      if command -v chattr >/dev/null 2>&1; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
      fi
      cp -a "$BACKUP_DIR/resolv.conf.before-dnscrypt" /etc/resolv.conf
      warn "已恢复旧 /etc/resolv.conf：$BACKUP_DIR/resolv.conf.before-dnscrypt"
    fi
    exit 1
  fi
}

install_healthcheck_timer() {
  cat > /usr/local/sbin/dnscrypt-proxy-healthcheck <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/dnscrypt-healthcheck.log
LISTEN_ADDR="$(awk '/^nameserver[[:space:]]+127\./ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.2.1}"

if dig @"$LISTEN_ADDR" debian.org A +time=5 +tries=1 +short >/dev/null 2>&1; then
  echo "$(date '+%F %T') ok @$LISTEN_ADDR" >> "$LOG"
  exit 0
fi

echo "$(date '+%F %T') restart dnscrypt-proxy; healthcheck failed @$LISTEN_ADDR" >> "$LOG"
systemctl restart dnscrypt-proxy || true
sleep 5
if dig @"$LISTEN_ADDR" debian.org A +time=5 +tries=1 +short >/dev/null 2>&1; then
  echo "$(date '+%F %T') ok after restart @$LISTEN_ADDR" >> "$LOG"
else
  echo "$(date '+%F %T') still failed @$LISTEN_ADDR" >> "$LOG"
  exit 1
fi
EOF
  chmod 0755 /usr/local/sbin/dnscrypt-proxy-healthcheck

  cat > /etc/systemd/system/dnscrypt-proxy-healthcheck.service <<'EOF'
[Unit]
Description=DNSCrypt proxy health check
After=dnscrypt-proxy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dnscrypt-proxy-healthcheck
EOF

  cat > /etc/systemd/system/dnscrypt-proxy-healthcheck.timer <<'EOF'
[Unit]
Description=Run DNSCrypt proxy health check daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now dnscrypt-proxy-healthcheck.timer >/dev/null 2>&1 || warn "健康检查 timer 启用失败，不影响 dnscrypt-proxy 主服务。"
  ok "已安装 systemd 健康检查 timer"
}

print_summary() {
  echo
  ok "dnscrypt-proxy 安装完成"
  echo "监听地址：$DNSCRYPT_LISTEN_IPV4:53"
  echo "上游服务器：$DNSCRYPT_SERVERS"
  echo "配置文件：/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  echo "备份目录：$BACKUP_DIR"
  echo "安装日志：$LOG_FILE"
  echo
  echo "常用命令："
  echo "  systemctl status dnscrypt-proxy --no-pager -l"
  echo "  journalctl -u dnscrypt-proxy -n 100 -o cat"
  echo "  dig @$DNSCRYPT_LISTEN_IPV4 debian.org A +short"
  echo
  echo "如需锁定 /etc/resolv.conf，可重新运行："
  echo "  LOCK_RESOLV=1 bash install-dnscrypt-universal.sh"
}

main() {
  require_root
  touch "$LOG_FILE"
  validate_listen_ipv4
  require_debian_systemd
  backup_existing_files
  install_dependencies
  install_dnscrypt_from_github
  write_dnscrypt_config
  write_systemd_unit
  start_and_test_dnscrypt
  write_resolv_conf
  final_system_dns_test
  install_healthcheck_timer
  print_summary
}

main "$@"
