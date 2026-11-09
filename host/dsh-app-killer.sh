#!/system/bin/sh
# dsh-app-killer.sh —— 用完 App 回到桌面后，60 秒仍不在前台就 force-stop，释放内存护住 DSH
# 原理：监控前台进程，当从某个第三方 App 切回桌面(launcher)时记下它；
#       60 秒后若它还没回到前台，就 am force-stop。
# 白名单：桌面/系统/DSH/QQ 等不杀。
LOG=/data/adb/killer.log
CAND=/data/adb/killer.cand

# 取当前前台包名（topResumedActivity 行里 "u0 <pkg>/..."）
fgpkg() {
  dumpsys activity activities 2>/dev/null | grep 'topResumedActivity' | sed -n '1p' | \
    sed -E 's/.* u0 ([A-Za-z0-9._]+)\/.*/\1/'
}

whitelisted() {
  case "$1" in
    ""|com.miui.home|com.android.systemui|dsh.android.client|com.netease.cloudmusic|com.topjohnwu.magisk|\
    com.miui.*|com.android.*|com.xiaomi.*|com.google.*|com.qualcomm.*|com.mediatek.*|com.miui.voiceassist) return 0 ;;
    *) return 1 ;;
  esac
}

echo "$(date +%F' '%T) app-killer up" >> $LOG
LAST=""
while true; do
  CUR=$(fgpkg)

  # 检测「切回桌面」：从某 App 变到 launcher
  if [ -n "$LAST" ] && [ "$LAST" != "$CUR" ] && ! whitelisted "$LAST" &&      { [ "$CUR" = "com.miui.home" ] || [ "$LAST" = "com.tencent.mobileqq" ]; }; then
    if true; then
      echo "$LAST $(date +%s)" > $CAND
      echo "$(date +%F' '%T) 用完 $LAST，60s 后若仍在后台就杀" >> $LOG
    fi
  fi
  LAST="$CUR"

  # 处理候选
  if [ -s "$CAND" ]; then
    PKG=$(awk '{print $1}' "$CAND")
    TS=$(awk '{print $2}' "$CAND")
    NOW=$(date +%s)
    if [ "$PKG" = "$CUR" ]; then
      rm -f "$CAND"          # 又回到前台，取消
    elif [ $((NOW - TS)) -ge 60 ]; then
      am force-stop "$PKG" 2>/dev/null
      echo "$(date +%F' '%T) force-stop $PKG（离开前台 $((NOW - TS))s）" >> $LOG
      rm -f "$CAND"
    fi
  fi

  sleep 15
done
