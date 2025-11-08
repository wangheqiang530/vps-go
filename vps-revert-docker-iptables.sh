#!/usr/bin/env bash
#
# vps-revert-docker-iptables.sh
# 用途：将 Docker 恢复为使用 iptables（回滚之前把 Docker 改成 nft 的改动）
# 操作：
#  - 备份 /etc/docker/daemon.json, /etc/nftables.conf, /etc/fail2ban/jail.local
#  - 写入 daemon.json: {"iptables": true, "ip6tables": true, "userland-proxy": false}
#    （若你希望 userland-proxy=true 可修改变量）
#  - 重启 docker 服务（等待短时间）
#  - 删除 runtime nft 表 docker_published_nat（若存在）
#  - 从 /etc/nftables.conf 中清理自动管理的 DOCKER PUBLISHED DNAT 段（marker）
#  - 如果系统提供 iptables 的 fail2ban action，则把 fail2ban 的 banaction 切回 iptables-multiport
#  - 写日志并输出摘要
#
# 备注：
#  - 脚本尽量安全（提前备份），但请先在测试主机跑一次
#  - 如果你想保留 IPv6 行为或其它自定义，请在运行前修改变量
#

set -uo pipefail
IFS=$'\n\t'

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
LOG="/var/log/vps-revert-docker-iptables-${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "==== vps-revert-docker-iptables started: $(date -R) ===="

# 配置项（如需不同选择可在运行前修改）
USERLAND_PROXY=false   # 如果想使用 docker-proxy，请设置为 true
IP6TABLES=true         # 是否同时启用 ip6tables（通常设 true）
DAEMON_FILE="/etc/docker/daemon.json"
NFT_FILE="/etc/nftables.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

declare -a OK=()
declare -a WARN=()
declare -a FAIL=()

safe_backup() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak.${TIMESTAMP}" 2>/dev/null && OK+=("备份 $f -> ${f}.bak.${TIMESTAMP}") || WARN+=("备份 $f 失败")
  else
    WARN+=("文件 $f 不存在，跳过备份")
  fi
}

record_ok() { OK+=("$1"); echo "[OK] $1"; }
record_warn() { WARN+=("$1"); echo "[WARN] $1"; }
record_fail() { FAIL+=("$1"); echo "[FAIL] $1"; }

# 1) 备份关键文件
safe_backup "$DAEMON_FILE"
safe_backup "$NFT_FILE"
safe_backup "$FAIL2BAN_JAIL"

# 2) 写入 /etc/docker/daemon.json（恢复 iptables 管理）
cat > "$DAEMON_FILE" <<EOF
{
  "iptables": true,
  "ip6tables": ${IP6TABLES},
  "userland-proxy": ${USERLAND_PROXY}
}
EOF

if [[ $? -eq 0 ]]; then
  record_ok "已写入 $DAEMON_FILE（iptables=true）"
else
  record_fail "写入 $DAEMON_FILE 失败"
fi

# 3) 重启 docker 并等待（给 docker 一点时间重新建立规则）
if systemctl restart docker; then
  record_ok "systemctl restart docker 成功"
  # 等待 Docker 启动并恢复容器
  sleep 3
  # 检查 docker 是否 active
  if systemctl is-active --quiet docker; then
    record_ok "docker 服务处于 active"
  else
    record_warn "docker 服务重启后不处于 active，稍后请检查 docker logs"
  fi
else
  record_fail "重启 docker 失败（检查 systemctl status docker）"
fi

# 4) 删除 runtime 中我们可能创建的 docker_published_nat 表（如果存在）
if nft list table ip docker_published_nat >/dev/null 2>&1; then
  if nft delete table ip docker_published_nat >/dev/null 2>&1; then
    record_ok "已移除 runtime nft 表 docker_published_nat"
  else
    record_warn "尝试删除 nft table docker_published_nat 失败（可能权限或语法问题）"
  fi
else
  record_warn "runtime 中未检测到 docker_published_nat 表，跳过"
fi

# 5) 从 /etc/nftables.conf 中清理之前添加的 managed block（BEGIN/END 标记）
if [[ -f "$NFT_FILE" ]]; then
  # 备份（已在 safe_backup），现在清理 managed block
  if grep -q "# BEGIN DOCKER PUBLISHED DNAT (managed)" "$NFT_FILE" 2>/dev/null; then
    # 使用 awk 删除从 BEGIN 到 END 的区域（包含标记行）
    awk 'BEGIN{del=0} /# BEGIN DOCKER PUBLISHED DNAT \(managed\)/{del=1; next} /# END DOCKER PUBLISHED DNAT \(managed\)/{del=0; next} { if(!del) print }' "$NFT_FILE" > "${NFT_FILE}.tmp" && mv "${NFT_FILE}.tmp" "$NFT_FILE"
    if [[ $? -eq 0 ]]; then
      record_ok "已从 $NFT_FILE 中移除 DOCKER PUBLISHED DNAT 管理段（若存在）"
      # 重新加载 nftables 文件
      if nft -f "$NFT_FILE" >/dev/null 2>&1; then
        record_ok "已重新加载 $NFT_FILE"
      else
        record_warn "重新加载 $NFT_FILE 时出现问题，请手动验证 nft list ruleset"
      fi
    else
      record_warn "尝试编辑 $NFT_FILE 失败（请手动清理）"
    fi
  else
    record_warn "$NFT_FILE 中未发现 DOCKER PUBLISHED DNAT 管理段，跳过清理"
  fi
else
  record_warn "$NFT_FILE 不存在，跳过 nft 文件清理"
fi

# 6) 让 fail2ban 使用 iptables banaction（如果可用），否则保留原样
#    优先选择 iptables-multiport -> iptables
PREFERRED=""
if [[ -f /etc/fail2ban/action.d/iptables-multiport.conf ]]; then
  PREFERRED="iptables-multiport"
elif [[ -f /etc/fail2ban/action.d/iptables.conf ]]; then
  PREFERRED="iptables"
fi

if [[ -n "$PREFERRED" ]]; then
  safe_backup "$FAIL2BAN_JAIL"
  # 如果 jail.local 存在，修改或加入 banaction；否则创建
  if [[ -f "$FAIL2BAN_JAIL" ]]; then
    # replace or append
    if grep -q "^\[DEFAULT\]" "$FAIL2BAN_JAIL"; then
      if grep -q "^[[:space:]]*banaction[[:space:]]*=" "$FAIL2BAN_JAIL"; then
        sed -i -E "s/^[[:space:]]*banaction[[:space:]]*=.*$/banaction = ${PREFERRED}/" "$FAIL2BAN_JAIL" || true
      else
        awk -v ba="banaction = ${PREFERRED}" '
          $0 ~ /^\[DEFAULT\]/ { print; print ba; c=1; next } { print }
          END { if(!c) { print "[DEFAULT]"; print ba } }
        ' "$FAIL2BAN_JAIL" > "${FAIL2BAN_JAIL}.tmp" && mv "${FAIL2BAN_JAIL}.tmp" "$FAIL2BAN_JAIL"
      fi
    else
      echo -e "[DEFAULT]\nbanaction = ${PREFERRED}\n" >> "$FAIL2BAN_JAIL"
    fi
  else
    cat > "$FAIL2BAN_JAIL" <<EOF
[DEFAULT]
banaction = ${PREFERRED}
EOF
  fi

  # 重载 fail2ban
  if fail2ban-client reload >/dev/null 2>&1; then
    record_ok "已将 fail2ban 的 banaction 切换为 ${PREFERRED} 并重载"
  else
    if systemctl restart fail2ban >/dev/null 2>&1; then
      record_ok "已将 fail2ban 的 banaction 切换为 ${PREFERRED} 并重启"
    else
      record_warn "修改 fail2ban banaction 后重载/重启失败，请检查 journalctl -u fail2ban"
    fi
  fi
else
  record_warn "未发现 iptables action 文件，保留 fail2ban 当前配置"
fi

# 7) 输出目前的 iptables / nft / docker 状态简短检查
echo
echo "------ 快速检查（简短） ------"
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -L -n -v | sed -n '1,50p'
else
  echo "iptables 命令不可用"
fi

echo
echo "nft ruleset (head):"
nft list ruleset | sed -n '1,80p'

echo
echo "docker ps (简短):"
docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' || true

# 8) 摘要写入并打印
echo
echo "==== 摘要 ===="
echo "成功项："
for i in "${OK[@]}"; do echo " - $i"; done
echo
echo "警告项："
for i in "${WARN[@]}"; do echo " - $i"; done
echo
echo "失败项："
for i in "${FAIL[@]}"; do echo " - $i"; done

echo
echo "日志已写入: $LOG"
echo "如果你要批量在多台 VPS 上执行，建议把此脚本复制到每台并以 root 运行。"

echo "==== 完成: $(date -R) ===="
exit 0
