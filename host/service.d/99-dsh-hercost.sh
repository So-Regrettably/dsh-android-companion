#!/system/bin/sh
# 开机自启：本地计量守护
nohup setsid sh /data/adb/dsh-hercost.sh >/dev/null 2>&1 &
