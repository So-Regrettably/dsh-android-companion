#!/system/bin/sh
# DSH 守护（新版 dsh.android.client）：每 2 分钟看 38571，挂了依次尝试：
#   1) 唤起 App
#   2) 若停在「启动恢复」页 → 点「重试启动」(540,1265)
#      若停在主界面 → 点「启动 DSHA」(540,673)
#   3) 等 90 秒
#   4) 仍不行 → force-stop 重开 App，再按页面点对应按钮
# 绝不用 root 起 proot（会污染 SELinux context 导致 EACCES）
LOG=/data/adb/dsh-heal.log

# 按当前页面点启动按钮；返回 0=点了 1=没匹配到可点的按钮
wait_up() {
  i=0
  while [ "$i" -lt "${1:-6}" ]; do
    sleep 3; i=$((i+1))
    ss -lnt 2>/dev/null | grep -q ':38571' && return 0
  done
  return 1
}

# 2026-11-09：按钮位置会变（实测 673 -> 833），不能硬编码单个坐标。
# 按页面给一串候选 y，点一个等一会儿验端口，没起来再点下一个。
click_start() {
  ACT=$(dumpsys activity activities 2>/dev/null | grep topResumedActivity | head -1)
  case "$ACT" in
    *StartupRecoveryActivity*) CAND="1265 833 673" ;;
    *MainActivity*)            CAND="833 673 1265" ;;
    *) CAND="" ;;
  esac
  if [ -z "$CAND" ]; then
    am start -n dsh.android.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
    sleep 8
    CAND="833 673 1265"
  fi
  for y in $CAND; do
    input tap 540 $y 2>/dev/null
    if wait_up 6; then
      echo "$(date +%F' '%T) clicked y=$y, dsh up" >> $LOG
      return 0
    fi
  done
  echo "$(date +%F' '%T) click_start tried [$CAND], still down" >> $LOG
  return 1
}

while true; do
  # 预算熔断期间不拉活
  if [ -f /data/adb/budget/BRAKE ]; then
    sleep 120
    continue
  fi

  if ! ss -lnt 2>/dev/null | grep -q ':38571'; then
    echo "$(date +%F' '%T) dsh down, try app first" >> $LOG

    input keyevent 224 >/dev/null 2>&1   # 唤醒屏幕（夜间息屏时否则 App 起不来）
    wm dismiss-keyguard >/dev/null 2>&1
    sleep 2
    am start -n dsh.android.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
    sleep 8
    click_start

    # 等最多 90 秒
    i=0
    while [ $i -lt 18 ]; do
      sleep 5
      i=$((i+1))
      ss -lnt 2>/dev/null | grep -q ':38571' && break
    done

    # 还没起来：force-stop 重开，再点一次
    if ! ss -lnt 2>/dev/null | grep -q ':38571'; then
      echo "$(date +%F' '%T) app retry failed, force-stop and reopen" >> $LOG
      am force-stop dsh.android.client 2>/dev/null
      sleep 4
      input keyevent 224 >/dev/null 2>&1
      wm dismiss-keyguard >/dev/null 2>&1
      sleep 1
      am start -n dsh.android.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
      sleep 12
      click_start
    fi

    if ss -lnt 2>/dev/null | grep -q ':38571'; then
      echo "$(date +%F' '%T) recovered" >> $LOG
    else
      echo "$(date +%F' '%T) still down, will retry next cycle" >> $LOG
    fi
  fi
  sleep 120
done
