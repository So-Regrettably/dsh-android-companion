#!/system/bin/sh
# DSH 守护（新版 dsh.android.client）：每 2 分钟看 38571，挂了先唤起 App 点重试，再 proot 兜底
LOG=/data/adb/dsh-heal.log

while true; do
  # 预算熔断期间不拉活
  if [ -f /data/adb/budget/BRAKE ]; then
    sleep 120
    continue
  fi

  # DSH 活着吗（38571 端口 = DSH web）
  if ! ss -lnt 2>/dev/null | grep -q ':38571'; then
    echo "$(date +%F' '%T) dsh down, try app first" >> $LOG

    # 1) 唤起 App，让它自己接管（新版 App 管理 DSH 生命周期）
    am start -n dsh.android.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
    sleep 8

    # 2) 若停在「启动恢复」页，点「重试启动」
    ACT=$(dumpsys activity activities 2>/dev/null | grep topResumedActivity | head -1)
    if echo "$ACT" | grep -q 'StartupRecoveryActivity'; then
      input tap 540 1265
      echo "$(date +%F' '%T) clicked retry-start" >> $LOG
      sleep 10
    fi

    # 3) 等最多 90 秒
    i=0
    while [ $i -lt 18 ]; do
      sleep 5
      i=$((i+1))
      ss -lnt 2>/dev/null | grep -q ':38571' && break
    done

    # 4) 还没起来，force-stop 重开 App（不要 root 起 proot，会污染 SELinux context）
    if ! ss -lnt 2>/dev/null | grep -q ':38571'; then
      echo "$(date +%F' '%T) app retry failed, force-stop and reopen" >> $LOG
      am force-stop dsh.android.client 2>/dev/null
      sleep 4
      am start -n dsh.android.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
      sleep 12
      ACT=$(dumpsys activity activities 2>/dev/null | grep topResumedActivity | head -1)
      if echo "$ACT" | grep -q 'StartupRecoveryActivity'; then
        input tap 540 1265
        sleep 10
      fi
    fi
    ss -lnt 2>/dev/null | grep -q ':38571' && echo "$(date +%F' '%T) recovered" >> $LOG
  fi
  sleep 120
done
