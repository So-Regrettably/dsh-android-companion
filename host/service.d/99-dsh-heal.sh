#!/system/bin/sh
# 开机自启壳：Magisk 会把 service.d 下的脚本在 post-fs-data 之后执行。
# 每个守护对应一个壳，内容几乎一样，只是脚本名不同。
# 注意：必须 nohup + setsid，否则 service.d 执行完后子进程会被回收。
nohup setsid sh /data/adb/dsh-heal.sh >/dev/null 2>&1 &
