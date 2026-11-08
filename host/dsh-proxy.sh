#!/system/bin/sh
# mihomo 代理常驻守护（proot 内运行，只监听 127.0.0.1:7897，不影响系统全局网络）
# 每 60 秒检查端口，掉了就拉起；每 12 小时刷新订阅
PLIB=/data/local/tmp/plib
ROOTFS=/data/data/dsh.android.client/files/linux/ubuntu
LIB=$(ls -d /data/app/*/dsh.android.client*/lib/arm64 2>/dev/null | head -1)
LOG=/data/adb/proxy.log
MARK=$ROOTFS/root/.dsh/clash/.last_refresh

[ -n "$LIB" ] || { echo "$(date +%F' '%T) no lib dir" >> $LOG; exit 1; }

export LD_LIBRARY_PATH=$PLIB:$ROOTFS/../lib:$LIB
export PROOT_LOADER=$LIB/libprootloader.so
export PROOT_LOADER_32=$LIB/libprootloader32.so
export PROOT_TMP_DIR=$ROOTFS/../tmp
export PROOT_L2S_DIR=$ROOTFS/.l2s

start_mihomo() {
  echo "$(date +%F' '%T) starting mihomo" >> $LOG
  nohup setsid $PLIB/libproot.so --link2symlink -b $ROOTFS/.l2s:$ROOTFS/.l2s -L --kill-on-exit -0 \
    --rootfs=$ROOTFS --cwd=/root \
    -b /dev -b /dev/urandom:/dev/random -b /proc -b /sys -b /system -b /apex \
    -b /proc/self/fd:/dev/fd -b /storage/emulated/0:/sdcard -b /storage/emulated/0 \
    /bin/bash -c 'export PATH="/root/dsh-bin:/usr/local/bin:/usr/bin:/bin"; exec /root/dsh-bin/mihomo -d /root/.dsh/clash -f /root/.dsh/clash/min.yaml >> /root/.dsh/clash/run.log 2>&1' \
    >> $LOG 2>&1 &
}

is_up() { ss -lnt 2>/dev/null | grep -q '127.0.0.1:7897'; }

echo "$(date +%F' '%T) proxy daemon up" >> $LOG
is_up || start_mihomo

CNT=0
while true; do
  sleep 60
  CNT=$((CNT + 1))
  if ! is_up; then
    echo "$(date +%F' '%T) port down, restart" >> $LOG
    for p in $(ps -A -o PID,ARGS | grep "dsh-bin/mihomo" | grep -v grep | awk '{print $1}'); do kill -9 $p 2>/dev/null; done
    sleep 2
    start_mihomo
    sleep 10
  fi
  # 每 6 小时（360 次 * 60s）刷新一次订阅
  if [ $((CNT % 360)) -eq 0 ]; then
    echo "$(date +%F' '%T) refresh subscription" >> $LOG
    nohup setsid $PLIB/libproot.so --link2symlink -b $ROOTFS/.l2s:$ROOTFS/.l2s -L --kill-on-exit -0 \
      --rootfs=$ROOTFS --cwd=/root -b /dev -b /proc -b /sys -b /system \
      /bin/bash -c 'export PATH="/root/dsh-bin:/usr/bin:/bin"; python3 /root/proxy_refresh.py >> /root/.dsh/clash/refresh.log 2>&1' \
      >> $LOG 2>&1 &
  fi
done
