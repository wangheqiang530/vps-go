#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-ntpdate-daily.sh
# 作用：为 Debian 11/12/13 精简 VPS 配置轻量级每日时间同步。
# 设计目标：
# - 自动安装 ntpsec-ntpdate，无需手动补包。
# - 不依赖 cron/cron.daily，使用 systemd timer。
# - 设置时区为 Asia/Shanghai。
# - 立即执行一次同步，并安装每日自动同步。
# - 适合不想常驻 chrony/ntpd 的低内存 VPS。
#
# 可选环境变量：
#   TIMEZONE=Asia/Shanghai
#   NTP_SERVERS="time.cloudflare.com time.google.com 0.pool.ntp.org ntp1.aliyun.com"
#   DISABLE_TIMESYNCD=1   禁用 systemd-timesyncd，避免重复同步

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
NTP_SERVERS="${NTP_SERVERS:-time.cloudflare.com time.google.com 0.pool.ntp.org ntp1.aliyun.com}"
DISABLE_TIMESYNCD="${DISABLE_TIMESYNCD:-1}"
MAIN_LOG="/var/log/ntpdate-install.log"
SYNC_LOG="/var/log/ntpdate-sync.log"
SYNC_SCRIPT="/usr/local/sbin/ntpdate-sync"
SERVICE_FILE="/etc/systemd/system/ntpdate-sync.service"
TIMER_FILE="/etc/systemd/system/ntpdate-sync.timer"
BACKUP_DIR="/root/ntpdate-backup-$(date +%Y%m%d-%H%M%S)"

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
    "$SYNC_SCRIPT" \
    "$SERVICE_FILE" \
    "$TIMER_FILE" \
    /etc/cron.daily/ntpdate-sync; do
    if [ -e "$item" ] || [ -L "$item" ]; then
      cp -a "$item" "$BACKUP_DIR/" 2>/dev/null || true
    fi
  done

  ok "已备份旧配置到：$BACKUP_DIR"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive

  info "更新 apt 软件源"
  apt-get update -y

  info "安装时间同步所需依赖"
  if apt-get install -y --no-install-recommends ntpsec-ntpdate ca-certificates tzdata; then
    ok "已安装 ntpsec-ntpdate"
  else
    warn "ntpsec-ntpdate 安装失败，尝试安装 ntpdate"
    apt-get install -y --no-install-recommends ntpdate ca-certificates tzdata
    ok "已安装 ntpdate"
  fi

  if ! command -v ntpdate >/dev/null 2>&1; then
    err "安装完成后仍未找到 ntpdate 命令，无法继续。"
    exit 1
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
    timedatectl set-timezone "$TIMEZONE"
  else
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    printf '%s\n' "$TIMEZONE" > /etc/timezone
  fi

  ok "时区已设置为 $TIMEZONE"
}

maybe_disable_timesyncd() {
  if [ "$DISABLE_TIMESYNCD" != "1" ]; then
    warn "保留 systemd-timesyncd，未禁用。"
    return 0
  fi

  if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null; then
      info "禁用 systemd-timesyncd，避免与 ntpdate timer 重复同步"
      systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || warn "禁用 systemd-timesyncd 失败，继续安装 ntpdate timer。"
    fi
  fi
}

write_sync_script() {
  cat > "$SYNC_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

LOG="$SYNC_LOG"
SERVERS="$NTP_SERVERS"

log() { printf '%s %s\n' "\$(date '+%F %T')" "\$*" >> "\$LOG"; }

log "ntpdate-sync start"

if ! command -v ntpdate >/dev/null 2>&1; then
  log "ntpdate command not found"
  exit 127
fi

for server in \$SERVERS; do
  log "try ntpdate -u \$server"
  if timeout 30 ntpdate -u "\$server" >> "\$LOG" 2>&1; then
    log "success \$server"
    exit 0
  fi
  log "failed \$server"
done

log "all ntp servers failed"
exit 1
EOF

  chmod 0755 "$SYNC_SCRIPT"
  chown root:root "$SYNC_SCRIPT" 2>/dev/null || true
  touch "$SYNC_LOG"
  chmod 0644 "$SYNC_LOG" 2>/dev/null || true
  ok "已写入同步脚本：$SYNC_SCRIPT"
}

write_systemd_units() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=One-shot ntpdate time synchronization
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SYNC_SCRIPT
EOF

  cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Run ntpdate time synchronization daily

[Timer]
OnBootSec=5min
OnCalendar=daily
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ntpdate-sync.timer >/dev/null 2>&1
  ok "已启用 systemd timer：ntpdate-sync.timer"
}

remove_old_cron_job() {
  if [ -f /etc/cron.daily/ntpdate-sync ]; then
    rm -f /etc/cron.daily/ntpdate-sync
    ok "已移除旧 cron.daily 任务：/etc/cron.daily/ntpdate-sync"
  fi
}

run_sync_now() {
  info "立即执行一次时间同步"

  if systemctl start ntpdate-sync.service; then
    ok "立即同步执行成功"
    return 0
  fi

  err "立即同步失败。最近同步日志如下："
  tail -n 80 "$SYNC_LOG" >&2 || true
  exit 1
}

show_status() {
  echo
  info "当前时间状态"
  timedatectl status 2>/dev/null | sed -n '1,120p' || true

  echo
  info "定时器状态"
  systemctl list-timers ntpdate-sync.timer --no-pager || true

  echo
  ok "配置完成"
  echo "同步脚本：$SYNC_SCRIPT"
  echo "systemd service：$SERVICE_FILE"
  echo "systemd timer：$TIMER_FILE"
  echo "安装日志：$MAIN_LOG"
  echo "同步日志：$SYNC_LOG"
  echo "备份目录：$BACKUP_DIR"
  echo
  echo "常用命令："
  echo "  systemctl status ntpdate-sync.timer --no-pager -l"
  echo "  systemctl start ntpdate-sync.service"
  echo "  tail -n 100 $SYNC_LOG"
}

main() {
  touch "$MAIN_LOG"
  require_root
  require_debian_systemd
  backup_existing_files
  install_dependencies
  set_timezone
  maybe_disable_timesyncd
  write_sync_script
  write_systemd_units
  remove_old_cron_job
  run_sync_now
  show_status
}

main "$@"
