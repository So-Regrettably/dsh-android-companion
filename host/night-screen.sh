#!/system/bin/sh
# 屏幕/音量/亮度守护
# 屏幕：00:00-07:00 息屏，07:00-23:59 持续亮屏
# 音量：始终保持静音（媒体/通知/铃声/系统/闹钟）
# 亮度：始终保持最低（关闭自动亮度）
# 2026-11-08：启动即对齐当前状态；静音+低亮度每 5 分钟重设防被改回。

LOG=/data/adb/night.log
STATE=/data/adb/night.state

set_low_brightness() {
  settings put system screen_brightness_mode 0 2>/dev/null
  settings put system screen_brightness 1 2>/dev/null
}

set_mute() {
  settings put system volume_system 0 2>/dev/null
  settings put system volume_ring 0 2>/dev/null
  settings put system volume_music 0 2>/dev/null
  settings put system volume_alarm 0 2>/dev/null
  settings put system volume_notification 0 2>/dev/null
}

is_day() {
  H=$(date +%H)
  [ "$H" -ge 7 ]
}

apply_screen() {
  # $1 = day|night
  if [ "$1" = "day" ]; then
    settings put system screen_off_timeout 2147483647 2>/dev/null
    settings put global stay_on_while_plugged_in 7 2>/dev/null
    input keyevent 224 2>/dev/null
    echo "$(date +%F' '%T) screen-on (day)" >> $LOG
  else
    settings put system screen_off_timeout 30000 2>/dev/null
    settings put global stay_on_while_plugged_in 0 2>/dev/null
    input keyevent 223 2>/dev/null
    echo "$(date +%F' '%T) screen-off (night)" >> $LOG
  fi
  echo "$1" > "$STATE"
}

# 启动即对齐：低亮度 + 静音 + 按当前时间定屏幕状态
set_low_brightness
set_mute
if is_day; then CUR="day"; else CUR="night"; fi
OLD=$(cat "$STATE" 2>/dev/null)
if [ "$CUR" != "$OLD" ]; then
  apply_screen "$CUR"
  OLD="$CUR"
fi

CNT=0
while true; do
  if is_day; then N="day"; else N="night"; fi
  if [ "$N" != "$OLD" ]; then
    apply_screen "$N"
    OLD="$N"
  fi
  CNT=$((CNT+1))
  if [ "$CNT" -ge 10 ]; then   # 每 10*30秒 = 5 分钟重设一次
    set_low_brightness
    set_mute
    CNT=0
  fi
  sleep 30
done
