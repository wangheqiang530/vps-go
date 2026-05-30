#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# install-config-fail2ban.sh
# 作用：为 Debian 12/Ubuntu 精简 VPS 自动安装并配置 Fail2Ban SSH 防护。
# 特点：
# - 自动安装必需依赖：fail2ban、python3-systemd、nftables、iptables
# - Debian 12 精简系统默认使用 systemd journal，不依赖 /var/log/auth.log 或 rsyslog
# - 优先使用 nftables 动作，自动回退到 iptables
# - 显式启用 IPv6 自动处理，避免 allowipv6 未定义警告
# - 可重复运行：会备份旧配置并写入干净配置

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行脚本，例如：sudo bash $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "错误：此脚本面向 Debian/Ubuntu，当前系统未找到 apt-get。" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  echo "错误：当前系统未运行 systemd。Debian 12 VPS 通常默认使用 systemd。" >&2
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

backup_path="/root/fail2ban-backup-$(date +%Y%m%d-%H%M%S)"

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

  ok "已备份旧配置到：$backup_path"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  info "更新软件源"
  apt-get update -y

  info "安装 Fail2Ban 与精简系统必需依赖"
  apt-get install -y --no-install-recommends \
    fail2ban \
    python3-systemd \
    nftables \
    iptables \
    ca-certificates

  if ! python3 - <<'PY' >/dev/null 2>&1
import systemd.journal
PY
  then
    err "python3-systemd 安装后仍不可用，Fail2Ban 无法读取 systemd journal。"
    exit 1
  fi

  ok "依赖安装完成"
}

choose_action() {
  local nft_action="$1"
  local ipt_action="$2"

  if command -v nft >/dev/null 2>&1 && [ -f "/etc/fail2ban/action.d/${nft_action}.conf" ]; then
    printf '%s\n' "$nft_action"
  elif [ -f "/etc/fail2ban/action.d/${ipt_action}.conf" ]; then
    printf '%s\n' "$ipt_action"
  else
    printf '%s\n' "iptables-multiport"
  fi
}

write_configs() {
  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d /var/log

  local banaction
  local banaction_allports
  banaction="$(choose_action nftables-multiport iptables-multiport)"
  banaction_allports="$(choose_action nftables-allports iptables-allports)"

  info "封禁动作：$banaction"
  info "全端口封禁动作：$banaction_allports"

  # 使用 systemd 后端后，sshd jail 不再依赖 /var/log/auth.log。
  # logtarget 保持为文件，方便 recidive jail 读取历史封禁记录。
  cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
loglevel = INFO
logtarget = /var/log/fail2ban.log
socket = /run/fail2ban/fail2ban.sock
pidfile = /run/fail2ban/fail2ban.pid
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 30d
EOF

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
backend = systemd
allowipv6 = auto
banaction = $banaction
banaction_allports = $banaction_allports

findtime = 10m
maxretry = 5
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  # recidive 读取 /var/log/fail2ban.log，因此上面的 logtarget 必须保持为文件。
  cat > /etc/fail2ban/jail.d/recidive.local <<'EOF'
[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
action = %(banaction_allports)s[name=recidive]
bantime = 7d
findtime = 2d
maxretry = 5
EOF

  touch /var/log/fail2ban.log
  chmod 640 /var/log/fail2ban.log || true

  ok "已写入 Debian 12 精简系统配置"
}

enable_services() {
  if command -v nft >/dev/null 2>&1; then
    systemctl enable --now nftables >/dev/null 2>&1 || warn "nftables 服务未启用，但 Fail2Ban 仍可按需创建规则。"
  fi

  info "检查 Fail2Ban 配置"
  fail2ban-client -t

  info "启动并重启 Fail2Ban"
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2

  if ! systemctl is-active --quiet fail2ban; then
    err "Fail2Ban 启动失败，最近日志如下："
    journalctl -u fail2ban --no-pager -n 80 >&2 || true
    exit 1
  fi

  ok "Fail2Ban 已运行"
}

show_status() {
  echo
  info "当前 jail 状态"
  fail2ban-client status || true
  echo
  fail2ban-client status sshd || true

  echo
  ok "安装配置完成"
  echo "常用命令："
  echo "  fail2ban-client status"
  echo "  fail2ban-client status sshd"
  echo "  fail2ban-client set sshd banip 1.2.3.4"
  echo "  fail2ban-client set sshd unbanip 1.2.3.4"
  echo "  tail -f /var/log/fail2ban.log"
  echo
  echo "如需回滚旧配置："
  echo "  systemctl stop fail2ban"
  echo "  cp -a $backup_path/* /etc/fail2ban/"
  echo "  systemctl start fail2ban"
}

main() {
  info "开始配置 Fail2Ban：Debian 12 精简 VPS 优先版"
  backup_configs
  install_packages
  write_configs
  enable_services
  show_status
}

main "$@"
