#!/system/bin/sh
# 抖音省电守护：抖音在前台超过 10 分钟，自动按 home 回桌面（停止播放，省电）
# 2026-11-08 用户要求：刷完抖音切桌面，避免抖音一直播放耗电

PKG=com.ss.android.ugc.aweme
LIMIT_MIN=10
LOG=/data/adb/douyin-watch.log
CNT=0

log() { echo "$(date '+%F %T') $*" >> $LOG; }

log "douyin watch started (limit=${LIMIT_MIN}min)"

while true; do
  FG=$(dumpsys activity activities 2>/dev/null | grep topResumedActivity | head -1)
  if echo "$FG" | grep -q "$PKG"; then
    CNT=$((CNT+1))
    # 每 30 秒 +1，LIMIT_MIN 分钟 = LIMIT_MIN*2 次
    if [ "$CNT" -ge $((LIMIT_MIN*2)) ]; then
      input keyevent 3
      log "抖音前台 ${LIMIT_MIN} 分钟，自动回桌面"
      CNT=0
    fi
  else
    CNT=0
  fi
  sleep 30
done
