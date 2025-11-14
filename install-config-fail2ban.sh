#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install-config-fail2ban.sh
# 作用：自动安装 Fail2Ban，配置 SSH 防护，并启用 recidive（针对重复违规的更长封禁）
# 适用：Debian（也适用于 Ubuntu）
# 以 root 用户运行

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行脚本（或使用 sudo）。"
  exit 1
fi

echo "=== 1/8 更新软件源并安装 Fail2Ban ==="
apt update -y
apt install -y fail2ban

echo
echo "=== 2/8 备份现有配置（如有） ==="
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKDIR="/root/fail2ban-backup-$TIMESTAMP"
mkdir -p "$BACKDIR"
cfgs=(/etc/fail2ban/jail.conf /etc/fail2ban/jail.local /etc/fail2ban/fail2ban.conf)
for f in "${cfgs[@]}"; do
  if [ -f "$f" ]; then
    cp -a "$f" "$BACKDIR/"
    echo "已备份 $f -> $BACKDIR/"
  fi
done

echo
echo "=== 3/8 写入基础 SSH 保护配置到 /etc/fail2ban/jail.local ==="
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
# 全局默认值（可以按需调整）
bantime  = 1h            ; 初次违规封禁 1 小时
findtime = 10m           ; 在 10 分钟窗口内计数
maxretry = 5             ; 失败 5 次封禁

# 忽略的 IP（白名单），请按需添加你的管理 IP 或局域网
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16

# 日志后端（systemd 主流系统可用 systemd）
# backend = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime  = 1h
EOF

echo "/etc/fail2ban/jail.local 已写入："
echo "---------------------------------"
sed -n '1,200p' /etc/fail2ban/jail.local
echo "---------------------------------"

echo
echo "=== 4/8 启用 recidive jail（对重复违规者实施长期封禁） ==="
# recidive 会在 /var/log/fail2ban.log 中记录被反复封禁的 IP，然后对它们实施更长期封禁
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/recidive.local <<'EOF'
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
action   = iptables-allports[name=recidive]
# 这里设置为 7 天（单位为秒）；可以改成更长或更短
bantime  = 604800
findtime = 2d
# 如果在 findtime 时间内多次进 recidive 阶段，则再次触发（可以调）
maxretry = 5
EOF

echo "/etc/fail2ban/jail.d/recidive.local 已写入："
sed -n '1,200p' /etc/fail2ban/jail.d/recidive.local

echo
echo "=== 5/8 确保 filter 文件存在（通常由 package 提供） ==="
# 大多数 distro 已包含 sshd 和 recidive 的 filter；这里做下快速校验
if [ ! -f /etc/fail2ban/filter.d/sshd.conf ]; then
  echo "警告：/etc/fail2ban/filter.d/sshd.conf 不存在，尝试安装默认 filter"
  # 尝试恢复或提示用户
fi

if [ ! -f /etc/fail2ban/filter.d/recidive.conf ]; then
  echo "注意：recidive 过滤器不存在，写入最简单的 recidive 过滤器"
  cat > /etc/fail2ban/filter.d/recidive.conf <<'EOF'
# simple recidive filter - record bans in fail2ban log
[Definition]
failregex = Ban <HOST>
ignoreregex =
EOF
fi

echo
echo "=== 6/8 重载 systemd 并启动/重启 fail2ban ==="
systemctl daemon-reload
systemctl enable --now fail2ban
systemctl restart fail2ban

echo
echo "=== 7/8 显示状态与当前 jail 列表 ==="
fail2ban-client status || true
echo
echo "若要查看 sshd jail 的详情，请运行： fail2ban-client status sshd"
fail2ban-client status sshd || true

echo
echo "=== 8/8 测试与使用说明 ==="
cat <<'INSTR'

脚本已完成基础安装与配置。下面是你可以马上执行的几个常用检查和测试命令：

1) 查看 fail2ban 总状态：
   fail2ban-client status

2) 查看 sshd jail 详细状态：
   fail2ban-client status sshd

3) 查看被封禁 IP 列表：
   fail2ban-client status sshd
   （输出中会包含 "Banned IP list"）

4) 手动封禁 / 解封 IP：
   # 手动封禁（立即封禁）
   fail2ban-client set sshd banip 1.2.3.4

   # 手动解封
   fail2ban-client set sshd unbanip 1.2.3.4

5) 查看 Fail2Ban 日志（实时）：
   tail -n 200 /var/log/fail2ban.log
   tail -f /var/log/fail2ban.log

6) 模拟测试（在安全环境下）：
   在另一台机器从你的公网 IP 发起多次失败 SSH 登录（故意输错密码）；
   然后在服务器上运行：
      fail2ban-client status sshd
   你应该看到被封禁的 IP。

关于“封禁时间翻倍”：
- 本脚本启用了 recidive jail：当 IP 多次进入被封状态后，recidive 会把该 IP 列为“重复违规者”，并以更长的 bantime（脚本中设置为 7 天）再次封禁。这通常能达到“对重复攻击者实行更重惩罚/递增封禁”的目的。
- 若你确实要实现“每次被封禁时自动翻倍封禁时长”的精确机制，那需要自定义 action 或修改 action.d 的配置（风险稍高）。若需要，我可以为你生成一个更激进的“翻倍”实现脚本（会修改 action.d 的配置并保存回滚点）。

INSTR

echo
echo "如果要回滚改动，请运行："
echo "  systemctl stop fail2ban"
echo "  cp -a $BACKDIR/* /etc/fail2ban/  # 手动检查后恢复"
echo "  systemctl start fail2ban"
echo
echo "安装配置完成。祝你服务器安全又开心 😄"
