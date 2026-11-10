#!/system/bin/sh
# 本地计量守护：每 10 分钟在 proot 里跑一次 hercost.mjs --write
# 产出 /data/adb/budget/her-cost（她自己的花费，与账户余额无关）
LOG=/data/adb/hercost.log
ROOTFS=/data/data/dsh.android.client/files/linux/ubuntu
PLIB=/data/local/tmp/plib
INTERVAL=600

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 60000 ] && tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

while true; do
  LIB=$(ls -d /data/app/*/dsh.android.client*/lib/arm64 2>/dev/null | head -1)
  if [ -n "$LIB" ] && [ -x "$PLIB/libproot.so" ] && [ -f "$ROOTFS/root/hercost.mjs" ]; then
    LD_LIBRARY_PATH="$PLIB:$ROOTFS/../lib:$LIB" \
    PROOT_LOADER="$LIB/libprootloader.so" \
    PROOT_LOADER_32="$LIB/libprootloader32.so" \
    PROOT_TMP_DIR="$ROOTFS/../tmp" \
    PROOT_L2S_DIR="$ROOTFS/.l2s" \
    "$PLIB/libproot.so" --link2symlink -L --kill-on-exit -0 --rootfs="$ROOTFS" --cwd=/root \
      -b /dev -b /proc -b /sys -b /system -b /data/adb:/data/adb \
      /bin/bash -c 'export PATH="/root/dsh-bin:/usr/local/bin:/usr/bin:/bin"; node /root/hercost.mjs --write' >> "$LOG" 2>&1
    echo "$(date '+%F %T') round done: $(cat /data/adb/budget/her-cost 2>/dev/null)" >> "$LOG"
  else
    echo "$(date '+%F %T') skip: lib/proot/script missing" >> "$LOG"
  fi
  sleep $INTERVAL
done
