#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install-ntpdate-daily-final.sh
# 最终版：为内存受限 VPS 配置每日时间同步（ntpdate / ntpsec-ntpdate 兼容）
# - 设置时区为 Asia/Shanghai
# - 安装 ntpsec-ntpdate（若需要并可用）
# - 在 /etc/cron.daily/ 安装每日同步脚本（幂等）
# - 立即执行一次同步（幂等）
# - 彩色输出并写日志
# =============================================================================

# ---------------------- 颜色与日志 ----------------------
CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"   # 蓝
COL_OK="${CSI}1;32m"     # 绿
COL_WARN="${CSI}1;33m"   # 黄
COL_ERR="${CSI}1;31m"    # 红

main_log="/var/log/ntpdate-install.log"
sync_log="/var/log/ntpdate-sync.log"

# 输出函数（同时写日志）
_info()  { printf '%b%s%b\n' "$COL_INFO" "[INFO]  " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$main_log"; }
_ok()    { printf '%b%s%b\n' "$COL_OK"   "[OK]    " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$main_log"; }
_warn()  { printf '%b%s%b\n' "$COL_WARN" "[WARN]  " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$main_log"; }
_err()   { printf '%b%s%b\n' "$COL_ERR"  "[ERROR] " "$COL_RESET"; printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$main_log" >&2; }

# ---------------------- 必须以 root 运行 ----------------------
if [ "$(id -u)" -ne 0 ]; then
  _err "请以 root 用户运行此脚本"
  exit 1
fi

_info "开始：配置每日时间同步（轻量、幂等）"
_info "主日志：${main_log}"
_info "同步日志：${sync_log}"

# ---------------------- 检测发行版（信息，仅供日志） ----------------------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  _info "检测到系统：${NAME:-unknown} ${VERSION_ID:-unknown} (${ID:-unknown})"
else
  _info "无法读取 /etc/os-release（继续执行）"
fi

# ---------------------- 查找可用同步命令 ----------------------
find_time_client() {
  # 返回第一个可用的命令名（ntpdate 兼容接口优先）
  if command -v ntpdate >/dev/null 2>&1; then
    printf '%s' "ntpdate"
    return 0
  fi
  # ntpsec 包通常提供 ntpdate 可执行文件 name as ntpsec-ntpdate but provides ntpdate binary
  if command -v ntpsec-ntpdate >/dev/null 2>&1; then
    # ntpsec-ntpdate 包 may not provide "ntpdate" name; try calling ntpdate anyway after install
    printf '%s' "ntpdate"
    return 0
  fi
  if command -v sntp >/dev/null 2>&1; then
    printf '%s' "sntp"
    return 0
  fi
  if command -v busybox >/dev/null 2>&1; then
    # busybox may provide ntpd or sntp; prefer busybox ntpd -q
    printf '%s' "busybox"
    return 0
  fi
  # no client found
  return 1
}

# ---------------------- 安装 ntpdate / ntpsec-ntpdate（若需要） ----------------------
ensure_ntpdate() {
  if command -v ntpdate >/dev/null 2>&1; then
    _ok "检测到 ntpdate（已有），将使用现有工具"
    return 0
  fi

  _info "未检测到 ntpdate，尝试安装 ntpsec-ntpdate（兼容 ntpdate）"
  # 尝试 apt-get 安装 ntpsec-ntpdate 或 ntpdate（旧包）
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || _warn "apt-get update 失败（继续尝试安装）"
    # 先尝试安装 ntpsec-ntpdate（新替代包）
    if apt-get install -y --no-install-recommends ntpsec-ntpdate >/dev/null 2>&1; then
      _ok "已安装 ntpsec-ntpdate（将以 ntpdate 兼容方式使用）"
      # ensure ntpdate command exists (ntpsec-ntpdate provides ntpdate binary usually)
      if command -v ntpdate >/dev/null 2>&1; then
        return 0
      fi
    else
      _warn "未能安装 ntpsec-ntpdate（或包不可用）"
    fi

    # 作为备选，尝试安装兼容包 openntpd 或 ntp（尽量少）
    if apt-get install -y --no-install-recommends openntpd >/dev/null 2>&1; then
      _ok "安装 openntpd（提供 sntp），脚本将使用 sntp 作为回退"
      return 0
    fi

    # 尝试安装 ntp（提供 ntpd/ntpdate 在某些旧仓库）
    if apt-get install -y --no-install-recommends ntp >/dev/null 2>&1; then
      _ok "安装 ntp（若包含 ntpdate），已可用"
      return 0
    fi
  else
    _warn "系统没有 apt-get（或不可用），跳过自动安装步骤"
  fi

  # 如果到这里仍然没有合适工具，检测 busybox 是否存在（很多小镜像带 busybox）
  if command -v busybox >/dev/null 2>&1; then
    _ok "检测到 busybox，可用 busybox ntpd -q 作为回退"
    return 0
  fi

  _err "未能安装或找到任何一次性时间同步工具（ntpdate/ntpsec-ntpdate/sntp/busybox），请手动安装或联系管理员"
  return 2
}

# ---------------------- 时区设置（Asia/Shanghai） ----------------------
set_timezone() {
  local tz="Asia/Shanghai"
  if command -v timedatectl >/dev/null 2>&1; then
    local cur
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [ "$cur" != "$tz" ]; then
      _info "设置时区为 $tz"
      timedatectl set-timezone "$tz"
      _ok "时区已设置为 $tz"
    else
      _ok "时区已是 $tz（跳过）"
    fi
  else
    # fallback: /etc/localtime
    if [ -f "/usr/share/zoneinfo/$tz" ]; then
      ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
      _ok "通过 /etc/localtime 设置时区为 $tz"
    else
      _warn "无法找到 zoneinfo/$tz，跳过时区设置"
    fi
  fi
}

# ---------------------- 生成每日同步脚本（幂等） ----------------------
install_cron_daily() {
  local cron_path="/etc/cron.daily/ntpdate-sync"
  local servers=("time.cloudflare.com" "time.google.com" "0.pool.ntp.org" "ntp1.aliyun.com")
  # 构建脚本内容（带回退逻辑）
  cat > /tmp/ntpdate-sync.tmp <<'EOF'
#!/bin/sh
# /etc/cron.daily/ntpdate-sync
# 每日时间同步脚本：按顺序尝试 ntpdate -> sntp -> busybox ntpd -q
LOG="/var/log/ntpdate-sync.log"
echo "=== $(date -Iseconds) ntpdate-sync start ===" >>"$LOG"
SERVERS="time.cloudflare.com time.google.com 0.pool.ntp.org ntp1.aliyun.com"
# 首先尝试 ntpdate（最兼容）
for s in $SERVERS; do
  echo "$(date -Iseconds) try ntpdate: $s" >>"$LOG"
  if command -v ntpdate >/dev/null 2>&1; then
    if ntpdate -u "$s" >>"$LOG" 2>&1; then
      echo "$(date -Iseconds) success ntpdate: $s" >>"$LOG"
      exit 0
    else
      echo "$(date -Iseconds) fail ntpdate: $s" >>"$LOG"
    fi
  fi
done

# 回退尝试 sntp（openntpd）
for s in $SERVERS; do
  echo "$(date -Iseconds) try sntp: $s" >>"$LOG"
  if command -v sntp >/dev/null 2>&1; then
    # sntp 用法可能因实现不同，尝试通用形式
    if sntp -s "$s" >>"$LOG" 2>&1; then
      echo "$(date -Iseconds) success sntp: $s" >>"$LOG"
      exit 0
    else
      echo "$(date -Iseconds) fail sntp: $s" >>"$LOG"
    fi
  fi
done

# 最后回退尝试 busybox ntpd -q
if command -v busybox >/dev/null 2>&1; then
  for s in $SERVERS; do
    echo "$(date -Iseconds) try busybox ntpd -q: $s" >>"$LOG"
    if busybox ntpd -q -p "$s" >>"$LOG" 2>&1; then
      echo "$(date -Iseconds) success busybox ntpd -q: $s" >>"$LOG"
      exit 0
    else
      echo "$(date -Iseconds) fail busybox ntpd -q: $s" >>"$LOG"
    fi
  done
fi

echo "$(date -Iseconds) ntpdate-sync: all methods failed" >>"$LOG"
exit 1
EOF

  # compare with existing file to keep idempotent
  if [ -f "$cron_path" ]; then
    if cmp -s /tmp/ntpdate-sync.tmp "$cron_path"; then
      _ok "每日同步脚本已存在且内容相同（/etc/cron.daily/ntpdate-sync）"
      rm -f /tmp/ntpdate-sync.tmp
      return 0
    else
      _warn "检测到已有不同的每日同步脚本，将覆盖（/etc/cron.daily/ntpdate-sync）"
    fi
  fi

  mv /tmp/ntpdate-sync.tmp "$cron_path"
  chmod 0755 "$cron_path"
  chown root:root "$cron_path" || true
  _ok "已安装/更新每日同步脚本：$cron_path"
  # 确保日志文件存在
  touch "$sync_log" 2>/dev/null || true
  chmod 0644 "$sync_log" || true
  chown root:root "$sync_log" || true
  return 0
}

# ---------------------- 立即执行一次同步（幂等） ----------------------
run_one_sync_now() {
  _info "立即执行一次同步（会尝试多种方法，记录在 ${sync_log}）"
  # 调用 cron 脚本以统一逻辑
  if /etc/cron.daily/ntpdate-sync >/dev/null 2>&1; then
    _ok "即时同步脚本执行成功（请查看 ${sync_log} 获取详情）"
    return 0
  else
    _warn "即时同步脚本执行返回非零（可能网络或服务器问题），请查看 ${sync_log}"
    return 1
  fi
}

# ---------------------- 主流程 ----------------------
# 1. 确保存在可用的同步工具（尝试安装 ntpsec-ntpdate）
ensure_ntpdate || true

# 2. 设置时区
set_timezone

# 3. 安装/更新每日同步脚本（幂等）
install_cron_daily

# 4. 立即运行一次同步
run_one_sync_now

# 5. 最终输出状态
# 检查当前时间与同步工具信息
_info "当前系统时间与同步状态："
timedatectl status 2>/dev/null | sed -n '1,120p' | tee -a "$main_log" || true

# 打印一条总结
_ok "配置完成：每日自动时间同步已安装（/etc/cron.daily/ntpdate-sync）"
_info "如果你希望修改同步频率（比如改为每小时），我可以提供 systemd timer 或 cron.hourly 版本"
_info "若你希望改用 chrony（更专业但会多驻留进程），也可以随时切换"

exit 0
