#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-timesyncd-lite.sh
# 作用：为 Debian 11/12/13 精简 VPS 配置轻量级长期时间同步。
# 说明：由旧版 install-ntpdate-daily.sh 重构而来；当前实现使用 systemd-timesyncd，不再使用 ntpdate daily timer。
# 设计目标：
# - 全自动运行，无交互提示。
# - 优先使用 systemd-timesyncd，长期轻量防止时间漂移。
# - 默认海外权威 NTP 优先，国内公网 NTP 作为后备。
# - 不依赖 cron/cron.daily，不安装 chrony/ntpd 等较重守护进程。
# - 自动清理本脚本旧版创建的 ntpdate-sync timer/service。
#
# 可选环境变量：
#   TIMEZONE=Asia/Shanghai
#   NTP_PROFILE=global        可选：global / aliyun / tencent / google / custom
#   NTP_SERVERS="..."         custom 或覆盖默认主 NTP，支持空格/逗号分隔
#   FALLBACK_NTP_SERVERS="..." 覆盖默认后备 NTP，支持空格/逗号分隔；非 google profile 会追加到 NTP= 后段
#   POLL_INTERVAL_MIN_SEC=64
#   POLL_INTERVAL_MAX_SEC=2048
#   WAIT_SYNC_SECONDS=90      等待首次同步状态的时间；0 表示不等待
#   STRICT_VERIFY=0           1 表示首次同步未完成时返回失败
#   REPLACE_TIME_DAEMON=1     允许 apt 自动替换 chrony/ntp 等 time-daemon 包

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
NTP_PROFILE="${NTP_PROFILE:-global}"
NTP_SERVERS="${NTP_SERVERS:-}"
FALLBACK_NTP_SERVERS="${FALLBACK_NTP_SERVERS:-}"
POLL_INTERVAL_MIN_SEC="${POLL_INTERVAL_MIN_SEC:-64}"
POLL_INTERVAL_MAX_SEC="${POLL_INTERVAL_MAX_SEC:-2048}"
WAIT_SYNC_SECONDS="${WAIT_SYNC_SECONDS:-90}"
STRICT_VERIFY="${STRICT_VERIFY:-0}"
REPLACE_TIME_DAEMON="${REPLACE_TIME_DAEMON:-1}"

MAIN_LOG="/var/log/timesyncd-install.log"
BACKUP_DIR="/root/timesyncd-backup-$(date +%Y%m%d-%H%M%S)"
TIMESYNCD_DROPIN_DIR="/etc/systemd/timesyncd.conf.d"
TIMESYNCD_CONF="$TIMESYNCD_DROPIN_DIR/99-vps-go.conf"

LEGACY_SYNC_SCRIPT="/usr/local/sbin/ntpdate-sync"
LEGACY_SERVICE_FILE="/etc/systemd/system/ntpdate-sync.service"
LEGACY_TIMER_FILE="/etc/systemd/system/ntpdate-sync.timer"
LEGACY_SYNC_LOG="/var/log/ntpdate-sync.log"
LEGACY_MAIN_LOG="/var/log/ntpdate-install.log"

PRIMARY_SERVERS=""
FALLBACK_SERVERS=""

CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"
COL_OK="${CSI}1;32m"
COL_WARN="${CSI}1;33m"
COL_ERR="${CSI}1;31m"

log_line() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$MAIN_LOG"; }
info() { printf '%b[INFO]%b %s\n' "$COL_INFO" "$COL_RESET" "$*"; log_line "[INFO] $*"; }
ok() { printf '%b[OK]%b %s\n' "$COL_OK" "$COL_RESET" "$*"; log_line "[OK] $*"; }
warn() { printf '%b[WARN]%b %s\n' "$COL_WARN" "$COL_RESET" "$*"; log_line "[WARN] $*"; }
err() { printf '%b[ERROR]%b %s\n' "$COL_ERR" "$COL_RESET" "$*" >&2; log_line "[ERROR] $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行脚本，例如：curl -fsSL URL | bash" >&2
    exit 1
  fi
}

require_debian_systemd() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "未找到 apt-get。此脚本面向 Debian/Ubuntu 系系统。"
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
    /etc/systemd/timesyncd.conf \
    "$TIMESYNCD_DROPIN_DIR" \
    "$LEGACY_SYNC_SCRIPT" \
    "$LEGACY_SERVICE_FILE" \
    "$LEGACY_TIMER_FILE" \
    "$LEGACY_SYNC_LOG" \
    "$LEGACY_MAIN_LOG" \
    /etc/cron.daily/ntpdate-sync \
    /etc/timezone \
    /etc/localtime; do
    if [ -e "$item" ] || [ -L "$item" ]; then
      cp -a "$item" "$BACKUP_DIR/" 2>/dev/null || true
    fi
  done

  ok "已备份现有时间同步配置到：$BACKUP_DIR"
}

install_dependencies() {
  local apt_opts

  export DEBIAN_FRONTEND=noninteractive
  apt_opts=(-y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  info "更新 apt 软件源"
  apt-get update

  info "安装轻量时间同步组件 systemd-timesyncd"
  if apt-get "${apt_opts[@]}" --no-remove install \
    ca-certificates \
    tzdata \
    systemd-timesyncd; then
    ok "已安装 systemd-timesyncd"
    return 0
  fi

  if [ "$REPLACE_TIME_DAEMON" != "1" ]; then
    err "安装 systemd-timesyncd 失败。可能已有 chrony/ntp 等 time-daemon 包；如需自动替换，可设置 REPLACE_TIME_DAEMON=1。"
    exit 1
  fi

  warn "无移除模式安装失败，允许 apt 自动替换已有 time-daemon 后重试"
  apt-get "${apt_opts[@]}" install \
    ca-certificates \
    tzdata \
    systemd-timesyncd

  ok "已安装 systemd-timesyncd"
}

validate_uint() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    err "$name 必须是非负整数，当前为：$value"
    exit 1
  fi
}

normalize_poll_intervals() {
  validate_uint "POLL_INTERVAL_MIN_SEC" "$POLL_INTERVAL_MIN_SEC"
  validate_uint "POLL_INTERVAL_MAX_SEC" "$POLL_INTERVAL_MAX_SEC"
  validate_uint "WAIT_SYNC_SECONDS" "$WAIT_SYNC_SECONDS"

  if (( POLL_INTERVAL_MIN_SEC < 16 )); then
    warn "POLL_INTERVAL_MIN_SEC 小于 16，已自动调整为 16"
    POLL_INTERVAL_MIN_SEC=16
  fi

  if (( POLL_INTERVAL_MAX_SEC <= POLL_INTERVAL_MIN_SEC )); then
    POLL_INTERVAL_MAX_SEC=$((POLL_INTERVAL_MIN_SEC * 2))
    warn "POLL_INTERVAL_MAX_SEC 必须大于最小轮询间隔，已自动调整为 $POLL_INTERVAL_MAX_SEC"
  fi
}

is_valid_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets
  local octet

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

is_valid_ntp_server() {
  local server="$1"

  if is_valid_ipv4 "$server"; then
    return 0
  fi

  if [[ "$server" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    return 1
  fi

  [[ "$server" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$ ]] || return 1
  [[ "$server" != *..* ]] || return 1
  [[ "$server" == *.* ]] || return 1
}

normalize_server_list() {
  local input="$1"
  local result=""
  local server

  while IFS= read -r server; do
    [ -n "$server" ] || continue
    if is_valid_ntp_server "$server"; then
      if [ -z "$result" ]; then
        result="$server"
      else
        result="$result $server"
      fi
    else
      warn "忽略非法 NTP 服务器名称：$server" >&2
    fi
  done < <(printf '%s\n' "$input" | awk 'BEGIN { RS="[[:space:],]+" } NF { print }')

  printf '%s\n' "$result"
}

defaults_for_profile() {
  case "$NTP_PROFILE" in
    global)
      PRIMARY_SERVERS="time.cloudflare.com 0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org"
      FALLBACK_SERVERS="ntp.aliyun.com ntp1.aliyun.com ntp2.aliyun.com ntp.tencent.com ntp1.tencent.com ntp2.tencent.com"
      ;;
    aliyun)
      PRIMARY_SERVERS="ntp.cloud.aliyuncs.com ntp7.cloud.aliyuncs.com ntp8.cloud.aliyuncs.com ntp9.cloud.aliyuncs.com ntp10.cloud.aliyuncs.com ntp11.cloud.aliyuncs.com ntp12.cloud.aliyuncs.com"
      FALLBACK_SERVERS="ntp.aliyun.com ntp1.aliyun.com ntp2.aliyun.com time.cloudflare.com 0.pool.ntp.org"
      ;;
    tencent)
      PRIMARY_SERVERS="time1.tencentyun.com time2.tencentyun.com time3.tencentyun.com time4.tencentyun.com time5.tencentyun.com"
      FALLBACK_SERVERS="ntp.tencent.com ntp1.tencent.com ntp2.tencent.com ntp3.tencent.com ntp4.tencent.com ntp5.tencent.com time.cloudflare.com 0.pool.ntp.org"
      ;;
    google)
      PRIMARY_SERVERS=""
      FALLBACK_SERVERS="time.google.com"
      ;;
    custom)
      PRIMARY_SERVERS=""
      FALLBACK_SERVERS=""
      ;;
    *)
      err "未知 NTP_PROFILE：$NTP_PROFILE。可选：global / aliyun / tencent / google / custom"
      exit 1
      ;;
  esac
}

build_server_lists() {
  defaults_for_profile

  if [ -n "$NTP_SERVERS" ]; then
    PRIMARY_SERVERS="$NTP_SERVERS"
  fi
  if [ -n "$FALLBACK_NTP_SERVERS" ]; then
    FALLBACK_SERVERS="$FALLBACK_NTP_SERVERS"
  fi

  PRIMARY_SERVERS="$(normalize_server_list "$PRIMARY_SERVERS")"
  FALLBACK_SERVERS="$(normalize_server_list "$FALLBACK_SERVERS")"

  if [ -z "$PRIMARY_SERVERS" ] && [ "$NTP_PROFILE" != "google" ]; then
    err "没有可用的主 NTP 服务器。请检查 NTP_PROFILE 或 NTP_SERVERS。"
    exit 1
  fi

  if [ "$NTP_PROFILE" = "google" ] && [ -z "$FALLBACK_SERVERS" ]; then
    err "google profile 需要至少一个 Google FallbackNTP 服务器。"
    exit 1
  fi

  if [ "$NTP_PROFILE" = "google" ]; then
    warn "Google Public NTP 使用 leap smear；google profile 会写入空 NTP= 并仅使用 Google FallbackNTP。"
  fi
}

set_timezone() {
  if [ -z "$TIMEZONE" ]; then
    warn "TIMEZONE 为空，跳过时区设置。"
    return 0
  fi

  if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    err "系统中不存在时区文件：/usr/share/zoneinfo/$TIMEZONE"
    exit 1
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    local current
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [ "$current" = "$TIMEZONE" ]; then
      ok "时区已是 $TIMEZONE"
      return 0
    fi

    info "设置时区为 $TIMEZONE"
    if timedatectl set-timezone "$TIMEZONE"; then
      ok "时区已设置为 $TIMEZONE"
      return 0
    fi
    warn "timedatectl 设置时区失败，尝试使用 /etc/localtime 方式设置"
  fi

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  printf '%s\n' "$TIMEZONE" > /etc/timezone
  ok "时区已设置为 $TIMEZONE"
}

cleanup_legacy_ntpdate_units() {
  info "清理旧版 ntpdate daily timer 残留"

  systemctl disable --now ntpdate-sync.timer >/dev/null 2>&1 || true
  systemctl stop ntpdate-sync.service >/dev/null 2>&1 || true

  rm -f "$LEGACY_SERVICE_FILE" "$LEGACY_TIMER_FILE" "$LEGACY_SYNC_SCRIPT" /etc/cron.daily/ntpdate-sync
  systemctl daemon-reload

  ok "旧版 ntpdate timer/service 已清理"
}

disable_conflicting_time_daemons() {
  local unit

  for unit in chrony.service chronyd.service ntp.service ntpd.service ntpsec.service openntpd.service; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        warn "禁用可能冲突的时间同步服务：$unit"
        systemctl disable --now "$unit" >/dev/null 2>&1 || warn "禁用 $unit 失败，继续配置 systemd-timesyncd。"
      fi
    fi
  done
}

write_timesyncd_config() {
  local effective_ntp

  mkdir -p "$TIMESYNCD_DROPIN_DIR"

  cat > "$TIMESYNCD_CONF" <<EOF
# Managed by install-timesyncd-lite.sh from vps-go.
# Profile: $NTP_PROFILE

[Time]
EOF

  if [ "$NTP_PROFILE" = "google" ] && [ -z "$PRIMARY_SERVERS" ]; then
    # Google Public NTP uses leap smear; keep NTP= empty so non-smeared sources are not mixed in.
    printf 'NTP=\n' >> "$TIMESYNCD_CONF"
    printf 'FallbackNTP=%s\n' "$FALLBACK_SERVERS" >> "$TIMESYNCD_CONF"
  else
    effective_ntp="$PRIMARY_SERVERS"
    if [ -n "$FALLBACK_SERVERS" ]; then
      effective_ntp="$effective_ntp $FALLBACK_SERVERS"
    fi
    {
      printf '# Secondary servers are appended to NTP= so they are actually tried if earlier servers are unreachable.\n'
      printf '# systemd-timesyncd only uses FallbackNTP= when no NTP= server information is known.\n'
      printf 'NTP=%s\n' "$effective_ntp"
    } >> "$TIMESYNCD_CONF"
  fi

  cat >> "$TIMESYNCD_CONF" <<EOF
PollIntervalMinSec=$POLL_INTERVAL_MIN_SEC
PollIntervalMaxSec=$POLL_INTERVAL_MAX_SEC
EOF

  chmod 0644 "$TIMESYNCD_CONF"
  ok "已写入 timesyncd 配置：$TIMESYNCD_CONF"
}

enable_timesyncd() {
  info "启用 systemd-timesyncd"

  systemctl unmask systemd-timesyncd.service >/dev/null 2>&1 || true
  systemctl daemon-reload
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1
  systemctl restart systemd-timesyncd.service

  if ! systemctl is-active --quiet systemd-timesyncd.service; then
    err "systemd-timesyncd 未能启动，最近日志如下："
    journalctl -u systemd-timesyncd.service -n 80 --no-pager -o cat >&2 || true
    exit 1
  fi

  ok "systemd-timesyncd 已启动"
}

wait_for_initial_sync() {
  local deadline
  local status

  if (( WAIT_SYNC_SECONDS == 0 )); then
    warn "WAIT_SYNC_SECONDS=0，跳过首次同步等待。"
    return 0
  fi

  info "等待首次时间同步，最多 ${WAIT_SYNC_SECONDS} 秒"
  deadline=$((SECONDS + WAIT_SYNC_SECONDS))

  while (( SECONDS < deadline )); do
    status="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [ "$status" = "yes" ]; then
      ok "系统已报告 NTP synchronized=yes"
      return 0
    fi
    sleep 3
  done

  warn "等待结束后系统尚未报告 NTP synchronized=yes。服务已运行，可能需要更久或 UDP/123 被阻断。"
  journalctl -u systemd-timesyncd.service -n 80 --no-pager -o cat >&2 || true

  if [ "$STRICT_VERIFY" = "1" ]; then
    err "STRICT_VERIFY=1，首次同步未完成，返回失败。"
    exit 1
  fi
}

show_status() {
  echo
  info "当前时间状态"
  timedatectl status 2>/dev/null | sed -n '1,120p' || true

  echo
  info "timesyncd 状态"
  timedatectl timesync-status 2>/dev/null | sed -n '1,120p' || true

  echo
  ok "配置完成"
  echo "同步方案：systemd-timesyncd"
  echo "NTP profile：$NTP_PROFILE"
  echo "主 NTP：$PRIMARY_SERVERS"
  echo "后备 NTP：${FALLBACK_SERVERS:-未设置}${FALLBACK_SERVERS:+（已追加到 NTP= 后段，google profile 除外）}"
  echo "配置文件：$TIMESYNCD_CONF"
  echo "安装日志：$MAIN_LOG"
  echo "备份目录：$BACKUP_DIR"
  echo
  echo "常用命令："
  echo "  timedatectl status"
  echo "  timedatectl timesync-status"
  echo "  systemctl status systemd-timesyncd --no-pager -l"
  echo "  journalctl -u systemd-timesyncd -n 100 -o cat"
}

main() {
  require_root
  touch "$MAIN_LOG"
  require_debian_systemd
  normalize_poll_intervals
  build_server_lists
  backup_existing_files
  install_dependencies
  set_timezone
  cleanup_legacy_ntpdate_units
  disable_conflicting_time_daemons
  write_timesyncd_config
  enable_timesyncd
  wait_for_initial_sync
  show_status
}

main "$@"
