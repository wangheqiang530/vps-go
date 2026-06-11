# vps-go

VPS 常用自动化脚本合集，主要面向 Debian 11/12/13 与 Ubuntu 精简 VPS。

> 建议以 root 身份运行下面的一键命令。脚本默认全自动执行，不需要交互确认。

## Fail2Ban SSH 防护

脚本：`install-config-fail2ban.sh`

用途：自动安装并加固 Fail2Ban 的 SSH 防护，适合暴露 SSH 的精简 VPS。

主要特性：

- 自动安装 `fail2ban`、`python3-systemd`、`nftables`、`iptables` 等依赖。
- 使用 systemd journal 读取 SSH 日志，不依赖 `/var/log/auth.log` 或 rsyslog。
- 自动检测 SSH 监听端口，检测失败时回退为 `ssh`。
- 使用 aggressive 模式覆盖更多扫描、异常握手和预认证断开行为。
- 优先使用 nftables 动作，必要时回退到 iptables。
- 备份并隔离旧 Fail2Ban 本地配置，适合重复安装或升级加固。

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-config-fail2ban.sh | bash
```

## DNSCrypt 安全 DNS

脚本：`install-dnscrypt-universal.sh`

用途：自动安装 `dnscrypt-proxy`，把系统 DNS 指向本机轻量加密 DNS 代理。

主要特性：

- 从 DNSCrypt 官方 GitHub Release 自动安装适配当前 CPU 架构的二进制。
- 默认监听 `127.0.2.1:53`，端口冲突时自动尝试 `127.0.3.1`。
- 默认上游为 `cloudflare,google`，可通过 `DNSCRYPT_SERVERS` 自定义。
- 生成配置后先启动并通过解析测试，确认可用后才修改 `/etc/resolv.conf`。
- 默认开启缓存，并安装 systemd timer 做健康检查。
- 默认不锁定 `/etc/resolv.conf`；如需锁定可设置 `LOCK_RESOLV=1`。

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-dnscrypt-universal.sh | bash
```

自定义上游示例：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-dnscrypt-universal.sh | DNSCRYPT_SERVERS="cloudflare,quad9-dnscrypt-ip4-filter-pri" bash
```

锁定 `/etc/resolv.conf` 示例：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-dnscrypt-universal.sh | LOCK_RESOLV=1 bash
```

## Timesyncd 轻量时间同步

脚本：`install-timesyncd-lite.sh`

用途：使用系统原生 `systemd-timesyncd` 配置轻量级长期时间同步，防止 VPS 长期运行后时间漂移。

主要特性：

- 使用 `systemd-timesyncd`，不再使用旧版 `ntpdate daily timer`。
- 适合内存紧张的 Debian 11/12/13 精简 VPS，CPU 与内存占用很低。
- 默认海外 NTP 优先：`time.cloudflare.com` 与 `pool.ntp.org`。
- 国内公网 NTP 作为后备：阿里云与腾讯云 NTP 会追加到 `NTP=` 后段。
- 自动设置时区为 `Asia/Shanghai`。
- 自动清理旧版脚本创建的 `ntpdate-sync.timer/service`。
- 支持 `global`、`aliyun`、`tencent`、`google`、`custom` profile。

一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-timesyncd-lite.sh | bash
```

阿里云内网 NTP 优先：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-timesyncd-lite.sh | NTP_PROFILE=aliyun bash
```

腾讯云内网 NTP 优先：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-timesyncd-lite.sh | NTP_PROFILE=tencent bash
```

完全自定义 NTP：

```bash
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/main/install-timesyncd-lite.sh | NTP_PROFILE=custom NTP_SERVERS="time.cloudflare.com 0.pool.ntp.org" FALLBACK_NTP_SERVERS="ntp.aliyun.com ntp.tencent.com" bash
```
