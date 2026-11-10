#!/system/bin/sh
# ── 安全闸（2026-11-10）───────────────────────────────────────────
# 这个脚本用 root 起 proot，起出来的实例**没有 App 设备桥(3090)**，
# 所有工具调用都会报 DSHA_NATIVE_CONSENT_UNAVAILABLE / QUERY_FAILED。
# 正常重启请让 App 拉起（heal 会自动处理）。确实要用 root 实例调试再加 --force。
if [ "$1" != "--force" ]; then
  echo "拒绝执行：dsh-start.sh 会起一个没有设备桥的 root 实例（工具全废）。"
  echo "正常重启：让 App 点「启动 DSHA」，heal 每 2 分钟会自动补。"
  echo "确实需要 root 实例：sh $0 --force"
  exit 2
fi
# ────────────────────────────────────────────────────────────────
# DSH 启动（新版 dsh.android.client，动态定位 lib 路径，端口 38571）
PLIB=/data/local/tmp/plib
ROOTFS=/data/data/dsh.android.client/files/linux/ubuntu
LIB=$(ls -d /data/app/*/dsh.android.client*/lib/arm64 2>/dev/null | head -1)
LAUNCHER=$(ls -d /data/data/dsh.android.client/files/runtime-launcher-assets/* 2>/dev/null | head -1)
[ -n "$LIB" ] || { echo "no lib dir"; exit 1; }

export LD_LIBRARY_PATH=$PLIB:$ROOTFS/../lib:$LIB
export PROOT_LOADER=$LIB/libprootloader.so
export PROOT_LOADER_32=$LIB/libprootloader32.so
export PROOT_TMP_DIR=$ROOTFS/../tmp
export PROOT_L2S_DIR=$ROOTFS/.l2s
rm -f $ROOTFS/root/.dsha-stopped

exec $PLIB/libproot.so --link2symlink -b $ROOTFS/.l2s:$ROOTFS/.l2s -L --kill-on-exit -0 \
  --rootfs=$ROOTFS --cwd=/root \
  -b /dev -b /dev/urandom:/dev/random -b /proc -b /sys -b /system -b /apex \
  -b /proc/self/fd:/dev/fd -b /storage/emulated/0:/sdcard -b /storage/emulated/0 \
  -b /data/data/dsh.android.client/files/rc1-migration-state:/run/dsha-rc1-state \
  ${LAUNCHER:+-b $LAUNCHER:/run/dsha-launcher} \
  /bin/bash -c 'export PATH="/root/dsh-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"; \
    export DSH_HOME=/root/.dsh; export DSHA_WORKSPACE_DOCUMENTS=/root/Documents; \
    export DSH_PERMISSION_MODE=danger-full-access; export DSH_CONFIRM=1; export BROWSER=true; \
    export NODE_OPTIONS="--import=/root/.dsh/startup-observer.cjs ${NODE_OPTIONS-}"; \
    export DSHA_UI_LANGUAGE=zh; export DSHA_STARTUP_PROFILE=web; \
    cd /root; rm -f /root/.dsha-web.identity; echo $$ > /root/.dsha-web.pid 2>/dev/null; \
    [ ! -e /root/.dsha-stopped ] || exit 0; \
    exec /usr/local/bin/node /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --host 127.0.0.1 --port 38571 >> /root/dsh-web.log 2>&1'
