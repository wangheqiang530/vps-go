#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install-ntpdate-daily.sh
# 说明：
#  - 在 Debian / Ubuntu 上安装 ntpdate（若已安装则跳过）
#  - 设置时区为 Asia/Shanghai
#  - 在 /etc/cron.daily/ 安装每日校准脚本：/etc/cron.daily/ntpdate-sync
#  - 使用 ntpdate -u 依次尝试主/备时间服务器，日志写入 /var/log/ntpdate-sync.log
#  - 幂等设计：可重复运行不会产生问题
# =============================================================================

# ------------------ 彩色输出封装 ------------------
CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"   # 蓝
COL_OK="${CSI}1;32m"     # 绿
COL_WARN="${CSI}1;33m"   # 黄
COL_ERR="${CSI}1;31m"    # 红

logfile="/var/log/ntpdate-install.log"

info()  { printf '%b %s%b\n' "$COL_INFO"  "[INFO]  " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile"; }
ok()    { printf '%b %s%b\n' "$COL_OK"    "[OK]    " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile"; }
warn()  { printf '%b %s%b\n' "$COL_WARN"  "[WARN]  " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile"; }
err()   { printf '%b %s%b\n' "$COL_ERR"   "[ERROR] " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile" >&2; }

# ------------------ 需要 root ------------------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行此脚本"
  exit 1
fi

info "开始安装/配置：每日 ntpdate 时间校准（幂等）"
info "日志记录：$logfile"

# ------------------ 检测发行版（尽量兼容） ------------------
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    printf '%s|%s' "${ID:-unknown}" "${VERSION_ID:-unknown}"
  else
    printf 'unknown|unknown'
  fi
}
OS_INFO=$(detect_os)
info "检测到系统：$OS_INFO"

# ------------------ 安装 ntpdate（若缺失） ------------------
if command -v ntpdate >/dev/null 2>&1; then
  ok "ntpdate 已存在（跳过安装）"
else
  info "ntpdate 未检测到，尝试通过 apt 非交互安装（这需要网络）..."
  # apt-get 安装：先 apt-get update（尽量减少不必要更新，但缺包时必须）
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || { warn "apt-get update 失败，继续尝试安装（可能已有缓存）"; }
  if apt-get install -y --no-install-recommends ntpdate >/dev/null 2>&1; then
    ok "ntpdate 安装完成"
  else
    err "ntpdate 安装失败，请检查网络/仓库后重试"
    exit 2
  fi
fi

# ------------------ 设置时区为 Asia/Shanghai ------------------
TZ_TARGET="Asia/Shanghai"
CURRENT_TZ=""
if command -v timedatectl >/dev/null 2>&1; then
  CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  if [ "$CURRENT_TZ" != "$TZ_TARGET" ]; then
    info "设置系统时区为 $TZ_TARGET"
    timedatectl set-timezone "$TZ_TARGET"
    ok "时区已设置为 $TZ_TARGET"
  else
    ok "时区已是 $TZ_TARGET（跳过）"
  fi
else
  # 没有 timedatectl 的系统，尝试 /etc/localtime 处理
  if [ -f "/usr/share/zoneinfo/$TZ_TARGET" ]; then
    info "通过 /etc/localtime 设定时区为 $TZ_TARGET"
    ln -sf "/usr/share/zoneinfo/$TZ_TARGET" /etc/localtime
    ok "时区已设置为 $TZ_TARGET （通过 /etc/localtime）"
  else
    warn "无法找到 zoneinfo/$TZ_TARGET，跳过时区设置"
  fi
fi

# ------------------ 生成每日同步脚本内容（幂等） ------------------
CRON_SCRIPT_PATH="/etc/cron.daily/ntpdate-sync"
CRON_LOG="/var/log/ntpdate-sync.log"
# 主/备用时间服务器列表（可根据地域再调整）
# 主权威：Cloudflare；备用：Google、pool.ntp.org、阿里（在中国大陆）
SERVERS=(
  "time.cloudflare.com"
  "time.google.com"
  "0.pool.ntp.org"
  "ntp1.aliyun.com"
)

# 构造脚本内容
read -r -d '' CRON_SCRIPT_CONTENT <<'EOF' || true
#!/bin/sh
# /etc/cron.daily/ntpdate-sync
# 每日同步时间（使用 ntpdate -u），按顺序尝试主/备服务器
LOG="/var/log/ntpdate-sync.log"
echo "=== $(date -Iseconds) ntpdate-sync start ===" >>"$LOG"
# 尝试的服务器列表（按需修改）
SERVERS="time.cloudflare.com time.google.com 0.pool.ntp.org ntp1.aliyun.com"
for s in $SERVERS; do
  echo "$(date -Iseconds) try: $s" >>"$LOG"
  # -u 使用 unprivileged source port（更易通过防火墙）
  if ntpdate -u "$s" >>"$LOG" 2>&1; then
    echo "$(date -Iseconds) success: $s" >>"$LOG"
    break
  else
    echo "$(date -Iseconds) fail: $s" >>"$LOG"
  fi
done
echo "=== $(date -Iseconds) ntpdate-sync end ===" >>"$LOG"
EOF

# 比较现有脚本（如果存在），若相同则不替换
need_install_cron=1
if [ -f "$CRON_SCRIPT_PATH" ]; then
  if cmp -s <(printf '%s' "$CRON_SCRIPT_CONTENT") "$CRON_SCRIPT_PATH"; then
    need_install_cron=0
    ok "每日同步脚本已存在且内容一致（跳过重写）：$CRON_SCRIPT_PATH"
  else
    warn "检测到已有不同的每日同步脚本，将覆盖为自动化版本（可重复运行）"
    need_install_cron=1
  fi
fi

if [ "$need_install_cron" -eq 1 ]; then
  tmpf="$(mktemp)"
  printf '%s' "$CRON_SCRIPT_CONTENT" > "$tmpf"
  chmod 0755 "$tmpf"
  mv "$tmpf" "$CRON_SCRIPT_PATH"
  ok "已安装/更新每日同步脚本：$CRON_SCRIPT_PATH"
fi

# 确保日志文件存在并有合适权限
touch "$CRON_LOG"
chmod 0644 "$CRON_LOG"
chown root:root "$CRON_LOG" || true

# ------------------ 立即执行一次（幂等） ------------------
info "立即执行一次每日同步任务以校准当前时间（一次性）"
if sh "$CRON_SCRIPT_PATH"; then
  ok "即时同步成功。查看 /var/log/ntpdate-sync.log 获取细节"
else
  warn "即时同步遇到问题，请查看 /var/log/ntpdate-sync.log 与系统网络设置"
fi

# ------------------ 小结与提醒 ------------------
ok "安装/配置完成：每日自动校准（/etc/cron.daily/ntpdate-sync）已就绪"
info "主要时间服务器（尝试顺序）： ${SERVERS[*]}"
info "日志：$CRON_LOG"
info "若 VPS 经常使用快照/恢复，建议在每次恢复后手动运行： ntpdate -u time.cloudflare.com"

exit 0
