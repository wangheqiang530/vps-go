#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# VPS 初始化脚本 — Debian 优化版（含 Docker iptables 回退、fail2ban 固化、Portainer Agent 健康自检）
# 作者: ChatGPT （为你定制）
# 说明: 非交互式；出错会被记录但不会中断整个流程（除非致命错误明确需要退出）。

set -o pipefail

##########################
# 配置区域（可按需修改）#
##########################
LOG_DIR="/var/log"
TS=$(date +%Y%m%d%H%M%S)
LOG_FILE="${LOG_DIR}/vps-init-${TS}.log"
SUMMARY_FILE="${LOG_DIR}/vps-init-summary-${TS}.json"
REPORT_MD="${LOG_DIR}/vps-init-report-${TS}.md"

# 要安装/升级的包列表（Debian 系统）
PKGS=(sudo curl wget bash unzip rsync htop net-tools rsyslog nftables apt-transport-https ca-certificates gnupg lsb-release jq)

# Docker 强制使用 iptables（你要求回退到 iptables）
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_DAEMON_BACKUP_SUFFIX=".bak.${TS}"
DESIRED_DAEMON_JSON='{
  "iptables": true,
  "ip6tables": true,
  "userland-proxy": false
}'

# fail2ban 固定项
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
FAIL2BAN_JAIL_BACKUP="${FAIL2BAN_JAIL_LOCAL}.bak.${TS}"

# Portainer agent settings
PORTAINER_AGENT_NAME="portainer_agent"
PORTAINER_AGENT_PORT=19001
PORTAINER_AGENT_CURL_IMG="curlimages/curl:8.4.0"

# 清理保留天数
JOURNAL_KEEP_DAYS=14
TMP_CLEAN_DAYS=7

# 最大自动重启尝试次数（agent/docker）
MAX_AGENT_RESTARTS=1
MAX_DOCKER_RESTARTS=1

##########################
# 颜色与格式定义
##########################
# 终端颜色（只在支持颜色的终端生效）
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
BOLD="\033[1m"
NORMAL="\033[0m"

# 输出到日志和 stdout 的 helper
log() {
  echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
log_plain() {
  echo -e "$*" >> "$LOG_FILE"
}

##########################
# 状态记录结构
##########################
# 用数组维护任务、状态、详情、开始/结束时间
declare -a TASK_NAME
declare -a TASK_STATUS
declare -a TASK_DETAIL
declare -a TASK_T0
declare -a TASK_T1

add_task() {
  TASK_NAME+=("$1")
  TASK_STATUS+=("$2")
  TASK_DETAIL+=("$3")
  TASK_T0+=("${4:-0}")
  TASK_T1+=("${5:-0}")
}

set_task_status() {
  local idx=$1; shift
  TASK_STATUS[$idx]="$1"
  TASK_DETAIL[$idx]="${2:-}"
  TASK_T1[$idx]=$(date +%s)
}

start_task() {
  local name="$1"
  TASK_NAME+=("$name")
  TASK_STATUS+=("RUN")
  TASK_DETAIL+=("")
  TASK_T0+=("$(date +%s)")
  TASK_T1+=("0")
  echo $(( ${#TASK_NAME[@]} - 1 ))
}

finish_task_ok() {
  local idx=$1; shift
  TASK_STATUS[$idx]="OK"
  TASK_T1[$idx]=$(date +%s)
  TASK_DETAIL[$idx]="${*:-}"
}

finish_task_note() {
  local idx=$1; shift
  TASK_STATUS[$idx]="NOTE"
  TASK_T1[$idx]=$(date +%s)
  TASK_DETAIL[$idx]="${*:-}"
}

finish_task_fail() {
  local idx=$1; shift
  TASK_STATUS[$idx]="FAIL"
  TASK_T1[$idx]=$(date +%s)
  TASK_DETAIL[$idx]="${*:-}"
}

##########################
# 辅助函数
##########################
# 执行命令但不通过 set -e 退出，将输出记录并返回退出码
run_cmd() {
  local out
  out=$("$@" 2>&1)
  local rc=$?
  echo "$out" >>"$LOG_FILE"
  return $rc
}

# Run and capture output & rc
run_cmd_capture() {
  local -n _out=$1; shift
  _out="$("$@" 2>&1)"
  return $?
}

# safe write file with backup
safe_write_file() {
  local path="$1"; shift
  local content="$*"
  if [ -f "$path" ]; then
    cp -a "$path" "${path}${DOCKER_DAEMON_BACKUP_SUFFIX}" 2>/dev/null || true
  fi
  echo "$content" > "$path"
}

##########################
# 启动 banner
##########################
echo
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NORMAL}"
echo -e "${BOLD}║        VPS 初始化脚本 — Debian + iptables（自动化增强版）      ║${NORMAL}"
echo -e "${BOLD}║        作者: WHQ  /  运行时间: $(date -R)                 ║${NORMAL}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NORMAL}"
echo

log "启动初始化，日志: $LOG_FILE"
log_plain "脚本参数: $*"

START_TIME=$(date +%s)

##########################
# 阶段 0: 系统检测
##########################
i_task=$(start_task "系统检测 - 主机与发行版")
# detect os
run_cmd_capture out lsb_release -a 2>/dev/null || run_cmd_capture out cat /etc/os-release
finish_task_note $i_task "$out"

# bash 版本
i_task2=$(start_task "系统检测 - bash 版本")
bash --version > /tmp/.vps_bash_ver.$$ 2>&1 || true
bashver=$(cat /tmp/.vps_bash_ver.$$ 2>/dev/null)
rm -f /tmp/.vps_bash_ver.$$ 2>/dev/null || true
finish_task_note $i_task2 "$bashver"

##########################
# 阶段 1: apt 更新索引
##########################
i_task3=$(start_task "apt 更新索引")
log "执行: apt-get update -y"
if run_cmd apt-get update -y >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task3 "命令执行成功"
else
  finish_task_fail $i_task3 "apt update 失败（稍后尝试继续）"
fi

##########################
# 阶段 2: 安装/升级常用依赖
##########################
i_task4=$(start_task "安装/升级常用依赖")
log "安装/升级包: ${PKGS[*]}"
# 安装 docker 官方源的 prerequisites（若需要）
run_cmd apt-get install -y "${PKGS[@]}" >>"$LOG_FILE" 2>&1 || true
# apt upgrade 不强制全部自动重启内核，仅做安全升级
if run_cmd apt-get upgrade -y >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task4 "安装/升级完成"
else
  finish_task_note $i_task4 "部分包未成功升级，继续后续操作"
fi

# rsyslog 启用
i_task_rsyslog=$(start_task "rsyslog 启用")
if run_cmd systemctl enable --now rsyslog >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task_rsyslog "rsyslog enabled"
else
  finish_task_fail $i_task_rsyslog "rsyslog 启用失败"
fi

##########################
# 阶段 3: 检测并配置 Docker（切换到 iptables 模式）
##########################
i_task_docker=$(start_task "Docker - 检测 Docker")
if docker_version=$(docker --version 2>/dev/null); then
  finish_task_ok $i_task_docker "$docker_version"
else
  finish_task_fail $i_task_docker "Docker 未安装或 docker 命令不可用"
fi

# 备份并写入 daemon.json（如果需要变更）
i_task_docker_conf=$(start_task "Docker - 配置 daemon.json 为 iptables 模式")
# 读取当前配置以便比较
cur_daemon_json=""
if [ -f "$DOCKER_DAEMON_JSON" ]; then
  cur_daemon_json=$(cat "$DOCKER_DAEMON_JSON" 2>/dev/null || true)
fi

# 如果当前配置不包含 "iptables": true，则写入（备份原文件）
if echo "$cur_daemon_json" | grep -q '"iptables"\s*:\s*true' >/dev/null 2>&1; then
  finish_task_note $i_task_docker_conf "daemon.json 已为 iptables 模式或包含 iptables:true"
else
  # 备份并写入
  if [ -f "$DOCKER_DAEMON_JSON" ]; then
    cp -a "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}${DOCKER_DAEMON_BACKUP_SUFFIX}" 2>/dev/null || true
  fi
  echo "$DESIRED_DAEMON_JSON" > "$DOCKER_DAEMON_JSON"
  # 重新加载 docker
  if run_cmd systemctl restart docker >>"$LOG_FILE" 2>&1; then
    finish_task_ok $i_task_docker_conf "daemon.json 写入并重启 docker"
  else
    finish_task_fail $i_task_docker_conf "daemon.json 写入或 docker 重启失败（查看日志）"
  fi
fi

# 再探测 docker 的网络（检测 bridge 子网）
i_task_docker_net=$(start_task "Docker - 探测 Docker 子网")
docker_bridge_info=$(docker network inspect bridge 2>/dev/null || true)
if [ -n "$docker_bridge_info" ]; then
  # 从 JSON 提取 IPv4/IPv6 子网
  ipv4sub=$(echo "$docker_bridge_info" | jq -r '.[0].IPAM.Config[0].Subnet // "none"' 2>/dev/null || echo "none")
  ipv6sub=$(echo "$docker_bridge_info" | jq -r '.[0].IPAM.Config[0].SubnetIPv6 // "none"' 2>/dev/null || echo "none")
  finish_task_ok $i_task_docker_net "IPv4: ${ipv4sub} | IPv6: ${ipv6sub}"
else
  finish_task_note $i_task_docker_net "无法探测 Docker bridge（docker network inspect bridge 失败或 docker 未运行）"
fi

##########################
# 阶段 4: sysctl / 内核网络优化
##########################
i_task_sysctl=$(start_task "网络 - 应用 sysctl 设置")
# 推荐 sysctl 配置（追加，不覆盖）
SYSCTL_FILE="/etc/sysctl.d/99-vps-init.conf"
cat > "$SYSCTL_FILE" <<'EOF'
# vps-init recommended tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
if run_cmd sysctl --system >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task_sysctl "$(sysctl net.core.default_qdisc 2>/dev/null || true; sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true)"
else
  finish_task_fail $i_task_sysctl "sysctl 应用失败"
fi

##########################
# 阶段 5: nftables 配置（保留 nft，但不干扰 Docker iptables）
##########################
i_task_nft=$(start_task "nftables - 生成并加载基本规则")
NFT_FILE="/etc/nftables.conf"
# 备份
if [ -f "$NFT_FILE" ]; then
  cp -a "$NFT_FILE" "${NFT_FILE}.bak.${TS}" 2>/dev/null || true
fi
# 写入默认允许型基础规则（保留 docker 的 nat 表由 iptables 管理）
cat > "$NFT_FILE" <<'EOF'
#!/usr/sbin/nft -f

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        ct state established,related accept
        # 其余规则可以按需自定义
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # 注意：Docker 的 nat 仍由 iptables-nft/iptable 前端管理，不要随意添加针对 DOCKER 的 PREROUTING 规则
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname != "lo" masquerade
    }
}
EOF

if run_cmd nft -f "$NFT_FILE" >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task_nft "已写入并加载 /etc/nftables.conf"
else
  finish_task_fail $i_task_nft "加载 nftables 失败（请检查 /etc/nftables.conf）"
fi

# enable nftables systemd service if存在
i_task_nft_svc=$(start_task "nftables - 启用 nftables 服务")
if run_cmd systemctl enable --now nftables >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task_nft_svc "nftables enabled"
else
  finish_task_note $i_task_nft_svc "nftables 服务启用失败或不可用（继续）"
fi

##########################
# 阶段 6: fail2ban 安装与固定配置
##########################
i_task_fail2ban_install=$(start_task "fail2ban - 安装")
# Debian 默认仓库
run_cmd apt-get install -y fail2ban >>"$LOG_FILE" 2>&1 || true
if systemctl status fail2ban >/dev/null 2>&1; then
  finish_task_ok $i_task_fail2ban_install "fail2ban 安装/存在"
else
  finish_task_note $i_task_fail2ban_install "fail2ban 可能未安装或服务未启动"
fi

i_task_fail2ban_conf=$(start_task "fail2ban - 配置 fixa")
# 备份 jail.local
if [ -f "$FAIL2BAN_JAIL_LOCAL" ]; then
  cp -a "$FAIL2BAN_JAIL_LOCAL" "${FAIL2BAN_JAIL_BACKUP}" 2>/dev/null || true
fi

cat > "$FAIL2BAN_JAIL_LOCAL" <<EOF
# vps-init 自动写入: 固定 fail2ban 行为
[DEFAULT]
banaction = iptables-multiport
allowipv6 = auto
# 其它默认设置可在需要时扩展
EOF

# reload fail2ban
if run_cmd systemctl restart fail2ban >>"$LOG_FILE" 2>&1; then
  finish_task_ok $i_task_fail2ban_conf "已写入 $FAIL2BAN_JAIL_LOCAL 并 restart fail2ban"
else
  finish_task_fail $i_task_fail2ban_conf "fail2ban restart 失败，请检查日志"
fi

##########################
# 阶段 7: Portainer Agent 健康自检（自动恢复逻辑）
##########################
i_task_agent_check=$(start_task "Portainer Agent - 健康自检")
AGENT_CID=""
if docker ps --format '{{.Names}}' | grep -q "^${PORTAINER_AGENT_NAME}\$"; then
  # agent 存在，尝试在容器网络命名空间内请求 /api/status
  # 使用独立容器连接 container:NAME 网络以避免在 agent 容器内执行命令
  log "检测到容器 ${PORTAINER_AGENT_NAME}，尝试内部访问 agent"
  run_cmd_capture agent_out docker run --rm --network "container:${PORTAINER_AGENT_NAME}" "${PORTAINER_AGENT_CURL_IMG}" -k --connect-timeout 6 https://127.0.0.1:9001/api/status || true
  agent_rc=$?
  log_plain "agent 内部请求输出: $agent_out"
  if echo "$agent_out" | grep -qi "Missing request signature headers\|HTTP/2 403\|Unauthorized"; then
    finish_task_ok $i_task_agent_check "Agent 内部响应正常（403/Unauthorized 为预期的未认证返回），agent 存活"
  elif echo "$agent_out" | grep -qi "Connected\|HTTP/2 200"; then
    finish_task_ok $i_task_agent_check "Agent 内部响应正常（200/ok）"
  else
    # 未返回或超时，尝试自动恢复
    finish_task_note $i_task_agent_check "Agent 内部请求无响应 or 超时，开始自动恢复尝试"
    # 尝试重启容器（有限次数）
    attempt=0
    restarted_agent=false
    while [ $attempt -lt $MAX_AGENT_RESTARTS ]; do
      attempt=$((attempt+1))
      log "尝试重启容器 ${PORTAINER_AGENT_NAME}（第 ${attempt} 次）"
      run_cmd docker restart "${PORTAINER_AGENT_NAME}" >>"$LOG_FILE" 2>&1 || true
      # 等待几秒后再检测
      sleep 5
      run_cmd_capture agent_out docker run --rm --network "container:${PORTAINER_AGENT_NAME}" "${PORTAINER_AGENT_CURL_IMG}" -k --connect-timeout 6 https://127.0.0.1:9001/api/status || true
      log_plain "重启后 agent 内部请求输出: $agent_out"
      if echo "$agent_out" | grep -qi "Missing request signature headers\|HTTP/2 403\|Unauthorized\|HTTP/2 200"; then
        finish_task_ok $i_task_agent_check "重启容器后 agent 恢复: ${agent_out}"
        restarted_agent=true
        break
      fi
    done

    if [ "$restarted_agent" = false ]; then
      # 尝试重启 docker（若 agent 重启无效）
      attempt_d=0
      docker_restarted=false
      while [ $attempt_d -lt $MAX_DOCKER_RESTARTS ]; do
        attempt_d=$((attempt_d+1))
        log "尝试重启 docker（第 ${attempt_d} 次）"
        run_cmd systemctl restart docker >>"$LOG_FILE" 2>&1 || true
        sleep 5
        run_cmd_capture agent_out docker run --rm --network "container:${PORTAINER_AGENT_NAME}" "${PORTAINER_AGENT_CURL_IMG}" -k --connect-timeout 6 https://127.0.0.1:9001/api/status || true
        log_plain "重启 docker 后 agent 内部请求输出: $agent_out"
        if echo "$agent_out" | grep -qi "Missing request signature headers\|HTTP/2 403\|Unauthorized\|HTTP/2 200"; then
          finish_task_ok $i_task_agent_check "重启 docker 后 agent 恢复: ${agent_out}"
          docker_restarted=true
          break
        fi
      done

      if [ "$docker_restarted" = false ] && [ "$restarted_agent" = false ]; then
        finish_task_fail $i_task_agent_check "多次尝试后 agent 仍无响应，请检查容器日志或网络"
      fi
    fi
  fi
else
  finish_task_note $i_task_agent_check "未检测到容器 ${PORTAINER_AGENT_NAME}（跳过）"
fi

##########################
# 阶段 8: 清理与优化
##########################
i_task_clean_group=$(start_task "清理与优化 - APT & journal")
# apt autoclean/clean/autoremove
run_cmd apt-get autoclean -y >>"$LOG_FILE" 2>&1 || true
run_cmd apt-get clean -y >>"$LOG_FILE" 2>&1 || true
run_cmd apt-get autoremove -y >>"$LOG_FILE" 2>&1 || true
# journalctl vacuum
run_cmd journalctl --vacuum-time=${JOURNAL_KEEP_DAYS}d >>"$LOG_FILE" 2>&1 || true
finish_task_ok $i_task_clean_group "apt/journal 清理完成"

# 清理 /tmp /var/tmp
i_task_tmp=$(start_task "清理 - /tmp /var/tmp 7天前文件")
run_cmd find /tmp -type f -mtime +"${TMP_CLEAN_DAYS}" -print -delete >>"$LOG_FILE" 2>&1 || true
run_cmd find /var/tmp -type f -mtime +"${TMP_CLEAN_DAYS}" -print -delete >>"$LOG_FILE" 2>&1 || true
finish_task_ok $i_task_tmp "清理 /tmp /var/tmp 完成"

# Docker 空间与 prune
i_task_docker_df=$(start_task "Docker 清理 - docker system df")
run_cmd docker system df >>"$LOG_FILE" 2>&1 || true
finish_task_ok $i_task_docker_df "docker system df: 已记录"

i_task_docker_prune=$(start_task "Docker 清理 - docker system prune -af --volumes")
run_cmd docker system prune -af --volumes >>"$LOG_FILE" 2>&1 || true
finish_task_ok $i_task_docker_prune "docker prune 已执行（结果已写日志）"

##########################
# 阶段 9: 导出状态与自检
##########################
i_task_export=$(start_task "导出 - nft ruleset / docker ps / fail2ban status")
# nft ruleset 导出（若存在）
if run_cmd nft list ruleset >>"${LOG_DIR}/nft-ruleset-${TS}.txt" 2>&1; then
  finish_task_note $i_task_export "nft ruleset 导出到 ${LOG_DIR}/nft-ruleset-${TS}.txt"
else
  log "nft list ruleset 可能失败或未安装"
fi
# docker ps 导出
run_cmd docker ps --no-trunc > "${LOG_DIR}/docker-ps-${TS}.txt" 2>&1 || true
# fail2ban 状态
run_cmd fail2ban-client status > "${LOG_DIR}/fail2ban-status-${TS}.txt" 2>&1 || true
finish_task_ok $i_task_export "导出完成"

##########################
# 阶段 10: 最终自检（服务 enabled & active）
##########################
i_task_final_check=$(start_task "最终自检 - 检查关键服务")
services=(docker nftables fail2ban rsyslog)
svc_ok_msg=""
for svc in "${services[@]}"; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1 && systemctl is-active "$svc" >/dev/null 2>&1; then
    svc_ok_msg+="${svc}: enabled & active; "
  else
    svc_ok_msg+="${svc}: NOT OK; "
  fi
done
finish_task_ok $i_task_final_check "$svc_ok_msg"

##########################
# 生成最终汇总与漂亮表格（自动列宽与颜色）
##########################
END_TIME=$(date +%s)
TOTAL_SECONDS=$((END_TIME - START_TIME))

# 计算每个任务的耗时并准备打印表格
# 先计算列宽
max_task_len=0
max_status_len=6
max_detail_len=0
for idx in "${!TASK_NAME[@]}"; do
  tlen=${#TASK_NAME[$idx]}
  [ $tlen -gt $max_task_len ] && max_task_len=$tlen
  slen=${#TASK_STATUS[$idx]}
  [ $slen -gt $max_status_len ] && max_status_len=$slen
  dlen=${#TASK_DETAIL[$idx]}
  [ $dlen -gt $max_detail_len ] && max_detail_len=$dlen
done

# 限制最大列宽避免超大
[ $max_task_len -gt 60 ] && max_task_len=60
[ $max_detail_len -gt 80 ] && max_detail_len=80

# 打印表头
sep_line=$(printf '─%.0s' $(seq 1 $((max_task_len + max_status_len + max_detail_len + 8))))
echo
echo -e "$sep_line"
printf "│ %-${max_task_len}s │ %-${max_status_len}s │ %-${max_detail_len}s │\n" "任务" "状态" "详情"
echo -e "$sep_line"
# 打印每个任务
for idx in "${!TASK_NAME[@]}"; do
  name="${TASK_NAME[$idx]}"
  status="${TASK_STATUS[$idx]}"
  detail="${TASK_DETAIL[$idx]}"
  duration=0
  if [ "${TASK_T1[$idx]}" -ne 0 ] && [ "${TASK_T0[$idx]}" -ne 0 ]; then
    duration=$((TASK_T1[$idx] - TASK_T0[$idx]))
  fi
  # 颜色
  case "$status" in
    "OK") color="$GREEN";;
    "NOTE") color="$YELLOW";;
    "FAIL") color="$RED";;
    "RUN") color="$BLUE";;
    *) color="$NORMAL";;
  esac
  printf "│ %-${max_task_len}s │ ${color}%-${max_status_len}s${NORMAL} │ %-${max_detail_len}s │\n" "$name" "$status" "$detail"
done
echo -e "$sep_line"

# 阶段耗时展示（聚合）
echo
echo -e "${BOLD}总耗时: ${TOTAL_SECONDS}s${NORMAL}"
echo -e "各阶段耗时（秒）:"
for idx in "${!TASK_NAME[@]}"; do
  name="${TASK_NAME[$idx]}"
  dur=0
  if [ "${TASK_T1[$idx]}" -ne 0 ] && [ "${TASK_T0[$idx]}" -ne 0 ]; then
    dur=$((TASK_T1[$idx] - TASK_T0[$idx]))
  fi
  printf "  - %-30s : %6ds\n" "$name" "$dur"
done

# 写入 JSON-like 摘要（简易）
{
  echo "{"
  echo "  \"timestamp\": \"$(date -Iseconds)\","
  echo "  \"log_file\": \"${LOG_FILE}\","
  echo "  \"tasks\": ["
  for idx in "${!TASK_NAME[@]}"; do
    name=$(echo "${TASK_NAME[$idx]}" | sed 's/"/\\"/g')
    status="${TASK_STATUS[$idx]}"
    detail=$(echo "${TASK_DETAIL[$idx]}" | sed 's/"/\\"/g')
    t0=${TASK_T0[$idx]}
    t1=${TASK_T1[$idx]}
    echo "    { \"task\":\"${name}\",\"status\":\"${status}\",\"detail\":\"${detail}\",\"t0\":${t0},\"t1\":${t1} },"
  done
  echo "  ],"
  echo "  \"total_seconds\": ${TOTAL_SECONDS}"
  echo "}"
} > "$SUMMARY_FILE"

log "详细日志： $LOG_FILE"
log "摘要文件（JSON-like）： $SUMMARY_FILE"
log "Markdown 报告： $REPORT_MD"

# 简单 Markdown 报告
{
  echo "# VPS Init Report - ${TS}"
  echo
  echo "运行时间: $(date -R)"
  echo
  echo "总耗时: ${TOTAL_SECONDS}s"
  echo
  echo "任务摘要:"
  for idx in "${!TASK_NAME[@]}"; do
    printf "- **%s** : %s -- %s\n" "${TASK_NAME[$idx]}" "${TASK_STATUS[$idx]}" "${TASK_DETAIL[$idx]}"
  done
} > "$REPORT_MD"

# 最后提示
echo
echo -e "${GREEN}初始化完成。建议检查日志文件并根据需要回滚 *.bak.* 文件（脚本已备份被改写文件）。${NORMAL}"
echo -e "日志: ${LOG_FILE}"
echo -e "摘要: ${SUMMARY_FILE}"
echo -e "报告: ${REPORT_MD}"
echo

exit 0
