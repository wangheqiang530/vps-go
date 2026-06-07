#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-config-fail2ban.sh
# 作用：为 Debian 11/12/13 与 Ubuntu 精简 VPS 自动安装并加固 Fail2Ban SSH 防护。
# 特点：
# - 自动安装必需依赖：fail2ban、python3-systemd、nftables、iptables
# - apt/dpkg 全程非交互，遇到包内配置文件冲突时默认保留当前文件，避免管道执行中断
# - 使用 systemd journal 读取 sshd 日志，不依赖 /var/log/auth.log 或 rsyslog
# - 备份并隔离旧本地配置，支持在旧机器上覆盖安装/更新/加固
# - SSH jail 使用 aggressive 模式，覆盖更多扫描、异常握手、预认证断开行为
# - 优先使用 nftables 动作，自动回退到 iptables
# - 显式启用 IPv6 自动处理，避免 allowipv6 未定义警告
# - 检测 iptables legacy 后端但不自动切换，避免影响老机器 Docker/防火墙规则
# - 自动检测 sshd 监听端口，检测失败时回退为 ssh
# - 增加 journal、防火墙、Fail2Ban 状态自检与失败诊断

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行脚本，例如：sudo bash $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "错误：此脚本面向 Debian/Ubuntu，当前系统未找到 apt-get。" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  echo "错误：当前系统未运行 systemd。Debian VPS 通常默认使用 systemd。" >&2
  exit 1
fi

CSI='\033['
COL_RESET="${CSI}0m"
COL_INFO="${CSI}1;34m"
COL_OK="${CSI}1;32m"
COL_WARN="${CSI}1;33m"
COL_ERR="${CSI}1;31m"

info() { printf '%b[INFO]%b %s\n' "$COL_INFO" "$COL_RESET" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$COL_OK" "$COL_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$COL_WARN" "$COL_RESET" "$*"; }
err() { printf '%b[ERROR]%b %s\n' "$COL_ERR" "$COL_RESET" "$*" >&2; }

SCRIPT_START_TS="$(date +%s)"
LAST_STEP_TS="$SCRIPT_START_TS"
backup_path="/root/fail2ban-backup-$(date +%Y%m%d-%H%M%S)"

APT_DPKG_OPTIONS=(
  "-o" "Dpkg::Use-Pty=0"
  "-o" "Dpkg::Options::=--force-confdef"
  "-o" "Dpkg::Options::=--force-confold"
)

banner() {
  cat <<'EOF_BANNER'
============================================================
  VPS Fail2Ban SSH Hardening
  Debian 11/12/13 Minimal VPS Edition
============================================================
EOF_BANNER
}

elapsed_total() {
  local now
  now="$(date +%s)"
  printf '%s' "$((now - SCRIPT_START_TS))"
}

mark_step() {
  local msg="$1"
  local now delta
  now="$(date +%s)"
  delta="$((now - LAST_STEP_TS))"
  LAST_STEP_TS="$now"
  ok "$msg，用时 ${delta}s"
}

apt_get_noninteractive() {
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_DPKG_OPTIONS[@]}" "$@" < <(yes N)
}

dpkg_configure_noninteractive() {
  DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a < <(yes N)
}

backup_configs() {
  mkdir -p "$backup_path"

  for item in \
    /etc/fail2ban/jail.local \
    /etc/fail2ban/fail2ban.local \
    /etc/fail2ban/fail2ban.d \
    /etc/fail2ban/jail.d; do
    if [ -e "$item" ]; then
      cp -a "$item" "$backup_path/"
    fi
  done

  mark_step "已备份旧配置到：$backup_path"
}

repair_dpkg_if_needed() {
  if dpkg --audit 2>/dev/null | grep -q .; then
    warn "检测到存在未配置完成的软件包，先尝试非交互修复 dpkg/apt 状态"
    dpkg_configure_noninteractive || true
    apt_get_noninteractive -f install -y
    mark_step "dpkg/apt 状态修复完成"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  info "更新软件源"
  apt_get_noninteractive update -y

  repair_dpkg_if_needed

  info "安装 Fail2Ban 与精简系统必需依赖"
  if ! apt_get_noninteractive install -y --no-install-recommends \
    fail2ban \
    python3-systemd \
    nftables \
    iptables \
    ca-certificates; then
    warn "apt-get 安装阶段失败，尝试先修复 dpkg 半配置状态后重试"
    dpkg_configure_noninteractive || true
    apt_get_noninteractive -f install -y || true
    apt_get_noninteractive install -y --no-install-recommends \
      fail2ban \
      python3-systemd \
      nftables \
      iptables \
      ca-certificates
  fi

  repair_dpkg_if_needed

  if ! python3 - <<'PY' >/dev/null 2>&1
import systemd.journal
PY
  then
    err "python3-systemd 安装后仍不可用，Fail2Ban 无法读取 systemd journal。"
    exit 1
  fi

  mark_step "依赖安装完成"
}

reset_configs() {
  info "清理旧 Fail2Ban 本地配置，避免旧 jail.d 配置覆盖新配置"

  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d
  local disabled_dir="$backup_path/disabled-old-configs"
  mkdir -p "$disabled_dir"

  for file in /etc/fail2ban/jail.local /etc/fail2ban/fail2ban.local; do
    if [ -f "$file" ]; then
      mv -f "$file" "$disabled_dir/$(basename "$file")"
    fi
  done

  local dir file base target moved=0
  for dir in /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      base="$(basename "$file")"
      # Debian 包自带 defaults-debian.conf 通常只启用 sshd，不会覆盖本脚本的加固参数，保留以减少包管理副作用。
      if [ "$base" = "defaults-debian.conf" ]; then
        continue
      fi
      target="$disabled_dir/$(basename "$dir")-$base"
      mv -f "$file" "$target"
      moved=$((moved + 1))
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.local' -o -name '*.conf' \) -print0)
  done

  if [ "$moved" -gt 0 ]; then
    ok "已隔离 $moved 个旧配置片段到：$disabled_dir"
  else
    ok "未发现需要隔离的旧配置片段"
  fi

  mark_step "旧配置清理完成"
}

check_firewall_backend() {
  info "检查 iptables/ip6tables 后端"

  local ipt_ver=""
  local ip6t_ver=""
  ipt_ver="$(iptables -V 2>/dev/null || true)"
  ip6t_ver="$(ip6tables -V 2>/dev/null || true)"

  [ -n "$ipt_ver" ] && echo "  iptables:  $ipt_ver" || warn "iptables 命令不可用"
  [ -n "$ip6t_ver" ] && echo "  ip6tables: $ip6t_ver" || warn "ip6tables 命令不可用"

  if printf '%s\n%s\n' "$ipt_ver" "$ip6t_ver" | grep -qi 'legacy'; then
    warn "检测到 iptables legacy 后端。脚本不会自动切换，以避免影响老机器 Docker/现有防火墙规则。"
    warn "建议后续人工评估是否统一到 iptables-nft，避免 legacy 与 nftables 混用。"
  fi

  mark_step "防火墙后端检查完成"
}

check_journal_access() {
  info "检查 systemd journal 中的 sshd 日志可读性"

  local found=0
  if journalctl _COMM=sshd -n 1 --no-pager -o cat 2>/dev/null | grep -q .; then
    found=1
  elif journalctl -u ssh -n 1 --no-pager -o cat 2>/dev/null | grep -q .; then
    found=1
  elif journalctl -u sshd -n 1 --no-pager -o cat 2>/dev/null | grep -q .; then
    found=1
  fi

  if [ "$found" -eq 1 ]; then
    ok "已读取到 sshd/ssh 相关 journal 日志"
  else
    warn "暂未读取到 sshd/ssh 历史日志；这不一定是错误，新连接失败日志产生后 Fail2Ban 仍可匹配。"
  fi

  mark_step "journal 检查完成"
}

choose_action() {
  local nft_action="$1"
  local ipt_action="$2"

  if command -v nft >/dev/null 2>&1 && [ -f "/etc/fail2ban/action.d/${nft_action}.conf" ]; then
    printf '%s\n' "$nft_action"
  elif [ -f "/etc/fail2ban/action.d/${ipt_action}.conf" ]; then
    printf '%s\n' "$ipt_action"
  else
    printf '%s\n' "$ipt_action"
  fi
}

detect_ssh_port() {
  local ports=""
  local cfg port

  if command -v sshd >/dev/null 2>&1; then
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu | paste -sd, - || true)"
  fi

  if [ -z "$ports" ]; then
    for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$cfg" ] || continue
      port="$(awk 'tolower($1)=="port" && $0 !~ /^[[:space:]]*#/ {print $2}' "$cfg" 2>/dev/null | sort -nu | paste -sd, - || true)"
      if [ -n "$port" ]; then
        ports="$port"
        break
      fi
    done
  fi

  if [ -n "$ports" ] && printf '%s' "$ports" | grep -Eq '^[0-9]+(,[0-9]+)*$'; then
    printf '%s\n' "$ports"
  else
    printf '%s\n' "ssh"
  fi
}

write_configs() {
  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d /var/log

  local banaction
  local banaction_allports
  local ssh_port
  banaction="$(choose_action nftables-multiport iptables-multiport)"
  banaction_allports="$(choose_action nftables-allports iptables-allports)"
  ssh_port="$(detect_ssh_port)"

  info "封禁动作：$banaction"
  info "全端口封禁动作：$banaction_allports"
  info "SSH 监听端口：$ssh_port"

  # 使用 systemd 后端后，sshd jail 不再依赖 /var/log/auth.log。
  # logtarget 保持为文件，方便 recidive jail 读取历史封禁记录。
  cat > /etc/fail2ban/fail2ban.local <<'EOF_F2B'
[Definition]
loglevel = INFO
logtarget = /var/log/fail2ban.log
socket = /run/fail2ban/fail2ban.sock
pidfile = /run/fail2ban/fail2ban.pid
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 30d
EOF_F2B

  cat > /etc/fail2ban/jail.local <<EOF_JAIL
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
backend = systemd
allowipv6 = auto
banaction = $banaction
banaction_allports = $banaction_allports

findtime = 15m
maxretry = 3
bantime = 1d
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 30d

[sshd]
enabled = true
port = $ssh_port
filter = sshd[mode=aggressive]
backend = systemd
maxretry = 3
findtime = 15m
bantime = 1d
EOF_JAIL

  # recidive 读取 /var/log/fail2ban.log，因此上面的 logtarget 必须保持为文件。
  cat > /etc/fail2ban/jail.d/recidive.local <<'EOF_RECIDIVE'
[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
action = %(banaction_allports)s[name=recidive]
bantime = 30d
findtime = 7d
maxretry = 3
EOF_RECIDIVE

  touch /var/log/fail2ban.log
  chmod 640 /var/log/fail2ban.log || true

  mark_step "已写入加固配置"
}

diagnose_failure() {
  err "Fail2Ban 启动或配置检查失败，开始输出诊断信息："
  echo
  echo "===== fail2ban-client -t =====" >&2
  fail2ban-client -t >&2 || true
  echo
  echo "===== systemctl status fail2ban =====" >&2
  systemctl status fail2ban --no-pager -l >&2 || true
  echo
  echo "===== journalctl -u fail2ban =====" >&2
  journalctl -u fail2ban --no-pager -n 100 >&2 || true
  echo
  echo "===== iptables backend =====" >&2
  iptables -V >&2 || true
  ip6tables -V >&2 || true
  echo
  echo "===== nft ruleset =====" >&2
  nft list ruleset >&2 || true
}

enable_services() {
  if command -v nft >/dev/null 2>&1; then
    systemctl enable --now nftables >/dev/null 2>&1 || warn "nftables 服务未启用，但 Fail2Ban 仍可按需创建规则。"
  fi

  info "检查 Fail2Ban 配置"
  if ! fail2ban-client -t; then
    diagnose_failure
    exit 1
  fi

  info "启动并重启 Fail2Ban"
  systemctl enable fail2ban >/dev/null 2>&1
  if ! systemctl restart fail2ban; then
    diagnose_failure
    exit 1
  fi
  sleep 2

  if ! systemctl is-active --quiet fail2ban; then
    diagnose_failure
    exit 1
  fi

  mark_step "Fail2Ban 已运行"
}

show_status() {
  echo
  info "当前 jail 状态"
  fail2ban-client status || true
  echo
  fail2ban-client status sshd || true
  echo
  info "sshd jail 动作"
  fail2ban-client get sshd actions || true
  echo
  info "nftables 规则预览，最多显示前 120 行"
  nft list ruleset 2>/dev/null | sed -n '1,120p' || true

  echo
  ok "安装配置完成，总耗时 $(elapsed_total)s"
  echo "常用命令："
  echo "  fail2ban-client status"
  echo "  fail2ban-client status sshd"
  echo "  fail2ban-client set sshd banip 1.2.3.4"
  echo "  fail2ban-client set sshd unbanip 1.2.3.4"
  echo "  tail -f /var/log/fail2ban.log"
  echo
  echo "如需回滚旧配置："
  echo "  systemctl stop fail2ban"
  echo "  cp -a $backup_path/jail.local /etc/fail2ban/ 2>/dev/null || true"
  echo "  cp -a $backup_path/fail2ban.local /etc/fail2ban/ 2>/dev/null || true"
  echo "  cp -a $backup_path/jail.d/. /etc/fail2ban/jail.d/ 2>/dev/null || true"
  echo "  cp -a $backup_path/fail2ban.d/. /etc/fail2ban/fail2ban.d/ 2>/dev/null || true"
  echo "  systemctl start fail2ban"
  echo
  echo "旧配置已备份/隔离于：$backup_path"
}

main() {
  banner
  info "开始配置 Fail2Ban：Debian 11/12/13 精简 VPS 加固版"
  backup_configs
  install_packages
  reset_configs
  check_firewall_backend
  check_journal_access
  write_configs
  enable_services
  show_status
}

main "$@"
