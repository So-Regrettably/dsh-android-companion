#!/system/bin/sh
# DSH 守护（新版 dsh.android.client）
# 判据（2026-11-10 加）：**38571 和 3090 都要在**。
#   - 38571 = DSH 本体
#   - 3090  = App 的设备桥（工具调用 / 原生确认都走它）
#   只起 38571 不起 3090 的实例没意义：能聊天，但所有工具都报
#   DSHA_NATIVE_CONSENT_UNAVAILABLE / QUERY_FAILED。
#   这种状态通常是 root 兜底（dsh-start.sh）留下的孤儿 node 占着端口，
#   必须先杀掉它，再让 App 自己拉起来。
# 绝不用 root 起 proot（会污染 SELinux context，而且没有设备桥）。
LOG=/data/adb/dsh-heal.log
MISSF=/data/adb/.heal-miss

port_up() { ss -lnt 2>/dev/null | grep -q ":$1"; }

wait_up() {
  i=0
  while [ "$i" -lt "${1:-6}" ]; do
    sleep 3; i=$((i+1))
    port_up 38571 && return 0
  done
  return 1
}

# 按钮位置会变（实测 673 / 833），按页面给候选，点一个验一次端口
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

  NEED=0
  WHY=""
  if ! port_up 38571; then NEED=1; WHY="38571 down"; fi
  if ! port_up 3090;  then NEED=1; WHY="${WHY:+$WHY+}3090 down"; fi

  if [ "$NEED" = "0" ]; then
    echo 0 > $MISSF 2>/dev/null
  fi

  # 迟滞：连续 2 次（≥4 分钟）都异常才动手，避免 App/桥短暂重启时误杀健康的 DSH
  if [ "$NEED" = "1" ]; then
    MISS=$(cat $MISSF 2>/dev/null || echo 0)
    case "$MISS" in ""|*[!0-9]*) MISS=0 ;; esac
    MISS=$((MISS + 1))
    echo $MISS > $MISSF
    echo "$(date +%F' '%T) need restart ($WHY, miss=$MISS)" >> $LOG
    if [ "$MISS" -lt 2 ]; then
      sleep 120
      continue
    fi
    echo 0 > $MISSF

    # 孤儿：38571 有人占着但设备桥没了 → root 兜底起的旧实例，先清掉
    if port_up 38571; then
      ORPH=$(ss -lntp 2>/dev/null | awk '/:38571/{print $NF}' | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1)
      if [ -n "$ORPH" ]; then
        echo "$(date +%F' '%T) killing orphan dsh pid=$ORPH (no bridge)" >> $LOG
        kill -9 "$ORPH" 2>/dev/null
        sleep 3
      fi
      am force-stop dsh.android.client 2>/dev/null
      sleep 3
    fi

    input keyevent 224 >/dev/null 2>&1   # 夜间息屏时否则 App 起不来
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
      port_up 38571 && port_up 3090 && break
    done

    # 还没齐：force-stop 重开，再点一次
    if ! port_up 38571 || ! port_up 3090; then
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

    if port_up 38571 && port_up 3090; then
      echo 0 > $MISSF 2>/dev/null
      echo "$(date +%F' '%T) recovered (38571+3090)" >> $LOG
    elif port_up 38571; then
      echo "$(date +%F' '%T) dsh up but NO bridge (3090), will retry" >> $LOG
    else
      echo "$(date +%F' '%T) still down, will retry next cycle" >> $LOG
    fi
  fi
  sleep 120
done
