#!/system/bin/sh
# DSH 守护（新版 dsh.android.client）
#
# 判据：**38571（本体）和 3090（App 设备桥）都要在**。
#   只有 38571 没有 3090 = 孤儿实例（root 兜底起的），能聊天但所有工具
#   都报 DSHA_NATIVE_CONSENT_UNAVAILABLE / QUERY_FAILED，必须杀掉重来。
#
# 2026-11-10 加固：
#   1) /data/adb/dsh.busy —— 别的守护（remind 换会话）正在操作时跳过，避免互相打架
#   2) 只在「3090 单独缺失」时先等 20 秒复核，避免 App 启动瞬间误判被强停
#   3) 连续失败退避：连挂 5 次后歇 15 分钟，别每 2 分钟 force-stop 折腾电池
LOG=/data/adb/dsh-heal.log
BUSY=/data/adb/dsh.busy
FAILS=0

port_up() { ss -lnt 2>/dev/null | grep -q ":$1"; }

busy_now() {
  [ -f "$BUSY" ] || return 1
  T=$(stat -c %Y "$BUSY" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - T )) -lt 300 ]
}

wait_up() {
  i=0
  while [ "$i" -lt "${1:-6}" ]; do
    sleep 3; i=$((i+1))
    port_up 38571 && return 0
  done
  return 1
}

# 按钮位置会变（实测 673 / 833 / 1265），按页面给候选，点一个验一次
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

  # 别的守护正在操作（换会话等），让开
  if busy_now; then
    sleep 60
    continue
  fi

  NEED=0
  WHY=""
  if ! port_up 38571; then NEED=1; WHY="38571 down"; fi
  if ! port_up 3090; then
    if [ "$NEED" = "0" ]; then
      # 只有桥没了：先等 20 秒复核，排除 App 刚启动的瞬间
      sleep 20
      port_up 3090 || { NEED=1; WHY="3090 down"; }
    else
      WHY="$WHY+3090 down"
    fi
  fi

  if [ "$NEED" = "1" ]; then
    echo "$(date +%F' '%T) need restart ($WHY) fails=$FAILS" >> $LOG
    touch "$BUSY"

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

    rm -f "$BUSY"

    if port_up 38571 && port_up 3090; then
      echo "$(date +%F' '%T) recovered (38571+3090)" >> $LOG
      FAILS=0
    elif port_up 38571; then
      FAILS=$((FAILS+1))
      echo "$(date +%F' '%T) dsh up but NO bridge (3090), fails=$FAILS" >> $LOG
    else
      FAILS=$((FAILS+1))
      echo "$(date +%F' '%T) still down, fails=$FAILS" >> $LOG
    fi

    # 连续失败退避，别一直折腾
    if [ "$FAILS" -ge 5 ]; then
      echo "$(date +%F' '%T) failed $FAILS times, backoff 15min" >> $LOG
      sleep 900
      FAILS=0
      continue
    fi
  fi
  sleep 120
done
