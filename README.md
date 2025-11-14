# vps-go
VPS各类脚本合集
---
一键安装dnscrypt，并修改配置文件，启用cf和google的doh安全dns，并且开启缓存。内存占用约为30m左右
```
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/refs/heads/main/install-dnscrypt-universal.sh | bash
```
---
一键安装ntpdate，修改时区为Asia/Shanghai，每日定时ntp同步时间。
```
curl -fsSL https://raw.githubusercontent.com/wangheqiang530/vps-go/refs/heads/main/install-ntpdate-daily.sh | bash
```
