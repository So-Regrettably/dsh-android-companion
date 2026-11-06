#!/system/bin/sh
# DSH 守护（2026-10-28 改造）：每 2 分钟看 3080，挂了就用自己的 proot 启动
#
# 为什么不再用 `am start`：10-28 装了 ffmpeg 之后，**应用内启动器**执行 node 时报
# `libstdc++.so.6: cannot open shared object file`（proot 退出码 127），应用起不来。
# 但我们从 shell 手工起的 proot 一切正常，所以自愈改走 /data/adb/dsh-start.sh。
LOG=/data/adb/dsh-heal.log

while true; do
  # 预算熔断期间不拉活
  if [ -f /data/adb/budget/BRAKE ]; then
    sleep 120
    continue
  fi

  # 清掉 App 自己拉起的重复实例（2026-10-30 加）
  #
  # App 的「启动 / 恢复上次状态」会另起一个 **app 身份**的 proot DSH。
  # 而我们自愈用的是 root 身份（dsh-start.sh 走 su），root 那个先占住 3080 之后，
  # app 这个抢不到端口却不会退出，还继续读写 /root/.dsh 下的文件 —— root 属主的
  # 它写不进去，于是 EACCES 周期性地刷进 dsh-web.log（10-30 18:32 起就有一个这样
  # 的实例在跑，一直没人发现）。
  #
  # 只在「3080 已经在服务」时才杀：否则可能把唯一一个可用的实例杀掉。
  # uid 10234 = u0_a234。
  # 只清"没占端口的影子"。占着 3080 的那个无论 root 还是 app 身份都留着 ——
  # 2026-10-31 00:20 教训：原来的写法是"3080 有服务就杀 app 身份的 node"，
  # 结果 App 自己起的那个实例（正占着 3080、界面显示正常）被一刀砍了，
  # 换成 root 实例顶上去，App 又变回"DSH 未运行"。判断必须落到"谁占着端口"。
  if ss -lnt 2>/dev/null | grep -q ':3080'; then
    OWNER=$(ss -lntp 2>/dev/null | grep ':3080' \
            | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    for p in $(ps -A -o PID,UID,NAME 2>/dev/null \
               | awk '$2==10234 && $3=="node" {print $1}'); do
      [ "$p" = "$OWNER" ] && continue          # 占着端口的是正主，不动
      tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q 'dsh web' || continue
      kill -9 "$p" 2>/dev/null
      echo "$(date +%F' '%T) killed shadow app-instance pid=$p (owner=$OWNER)" >> $LOG
    done
  fi
  if ! ss -lntp 2>/dev/null | grep -q ':3080'; then
    echo "$(date +%F' '%T) dsh down, starting via proot" >> $LOG
    rm -f /data/data/com.dsh.client/files/linux/ubuntu/root/.dsha-stopped
    nohup setsid sh /data/adb/dsh-start.sh >/dev/null 2>&1 &
    # 兜底起来之后，顺手清掉 App 的「恢复与恢复」标记。
    # 2026-10-31 04:13 实测：App 自己拉的实例是普通 App 身份，会被 MIUI 当后台进程回收；
    # root 实例不会被杀。所以界面会一直停在 StartupRecoveryActivity，而服务其实好好的。
    # App 在后台时改 prefs 不会被覆盖（它只在启动/退出时写），下次打开就不会看到恢复页。
    sed -i 's|name="web_startup_recovery_requested" value="true"|name="web_startup_recovery_requested" value="false"|' \
      /data/data/com.dsh.client/shared_prefs/deepseekharness.xml 2>/dev/null
    echo "$(date +%F' '%T) cleared app recovery flag" >> $LOG

    # 等它起来，最多 90 秒；没起来再退回「点应用图标」那条老路
    i=0
    while [ $i -lt 18 ]; do
      sleep 5
      i=$((i+1))
      ss -lntp 2>/dev/null | grep -q ':3080' && break
    done
    if ! ss -lntp 2>/dev/null | grep -q ':3080'; then
      echo "$(date +%F' '%T) proot start failed, fallback to app" >> $LOG
      input keyevent 224
      am start -n com.dsh.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
      sleep 45
    fi
  fi
  sleep 120
done
