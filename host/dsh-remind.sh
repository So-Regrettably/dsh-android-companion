#!/system/bin/sh
# 大肥鱼「定时提醒」守护（2026-10-24 建）
#
# 背景：她想提醒管理员某件事时，自己写了 `sleep 到点 + 塞注入队列` 的 bash 脚本，
# 但那轮 shell 工具调用一结束，整个进程组就被回收 —— 脚本 100% 必死，提醒永远不响。
# 所以改成 root 常驻守护扫文件：她只管写文件，到点由这里代她开口。
#
# 接口（她在 proot 里能直接写）：
#   echo "（提醒·到点了）四点啦，点外卖" > /root/.dsh/reminders/<到期unix时间戳>.txt
# 规则：文件名必须是纯数字的秒级时间戳；内容一行、别带引号和反斜杠（会被剥掉）;
#       到点注入成功即删除；想取消就直接删文件。
#
# 日志：/data/adb/remind.log
# 关掉：rm /data/adb/service.d/99-dsh-remind.sh 并 kill 进程

PREFIX=/data/data/com.dsh.client/files/linux/ubuntu
WS=$PREFIX/root
DIR=$WS/.dsh/reminders
INJ=$WS/.dsh/media/onebot/qq-inject.jsonl
LOG=/data/adb/remind.log
ADMIN=YOUR_QQ
BOT=BOT_QQ
INTERVAL=30
# 她自己出去玩的续敲（回合制改不了，但可以连着叫几次，让她"玩一阵"而不是"玩一下"）
PLAY_MARK=$WS/.dsh/play.now
PLAY_STATE=/data/adb/play.state
PLAY_GAP=120      # 每 2 分钟叫一次
PLAY_MAX=2        # 10-25 16:45 从 4 降到 2（省一半）
PLAY_WINDOW=900   # 从她开始玩算起，最长 15 分钟

# 内存守护：她玩过的 App 会一直挂在后台（小黑盒/知乎/B站各 0.5GB 上下），
# 攒到三四个就把 zram 吃满。这里定时把"不在前台"的娱乐 App 退掉，跟前台不冲突。
MEM_LOW_KB=716800        # 可用内存低于 700MB 就动手
MEM_EVERY=600            # 最快 10 分钟一次
MEM_STATE=/data/adb/memguard.last
MEM_APPS="com.max.xiaoheihe com.zhihu.android tv.danmaku.bili"

# 卡死看门狗（2026-10-25 17:1x 建）：会话太长 / 上游不回时，她的回合会挂在半路——
# 消息进来了、`turn/end` 迟迟不来、node 进程 CPU 却是 0，heal 只看 3080 端口根本发现不了。
# 判据：日志最后一段里「followup」出现在「turn/end」之后，且日志 5 分钟没长过。
WEBLOG=$WS/dsh-web.log
STUCK_STATE=/data/adb/stuck.state
FIX_STATE=/data/adb/stuck.fix
STUCK_SEC=300        # 静默 5 分钟判定卡死

# 每天 00:00 收工提示 / 05:00 换新会话（2026-10-25 用户定：他 12 点睡，收工在西边更真实）
CLOSE_STATE=/data/adb/close.state
ROT_STATE=/data/adb/rotate.state
FIX_COOLDOWN=900     # 15 分钟内又卡 → 认为重启没用，换新会话

log() { echo "$(date '+%F %T') $*" >> $LOG; }

inject() {
  printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
    "$BOT" "$ADMIN" "$NOW" "$NOW" "$1" "$1" "$ADMIN" >> "$INJ"
}

rotate_session() {
  MAP=$WS/.dsh/media/onebot/chat-sessions.json
  [ -f "$MAP" ] || return
  cp -p "$MAP" "/data/adb/backup/chat-sessions.json.$(date +%s)" 2>/dev/null
  printf '{}\n' > "$MAP"
  chown u0_a234:u0_a234 "$MAP" 2>/dev/null
}

restart_dsh() {
  rm -f "$WS/.dsha-stopped"
  input keyevent 224 2>/dev/null
  am start -n com.dsh.client/com.deepseekharness.app.ui.MainActivity >/dev/null 2>&1
  sleep 8
  input tap 135 2333 2>/dev/null
  sleep 2
  input tap 540 660 2>/dev/null
  sleep 30
}

cpu_busy() {
  P=$(pidof com.dsh.client 2>/dev/null | awk '{print $1}')
  [ -z "$P" ] && return 1
  A=$(awk '{print $14 + $15}' "/proc/$P/stat" 2>/dev/null)
  sleep 3
  B=$(awk '{print $14 + $15}' "/proc/$P/stat" 2>/dev/null)
  [ -z "$A" ] && return 1
  [ -z "$B" ] && return 1
  [ "$((B - A))" -ge 20 ]
}

stuckwatch() {
  ss -lntp 2>/dev/null | grep -q ':3080' || return
  [ -f /data/adb/budget/BRAKE ] && return
  [ -f "$WEBLOG" ] || return
  PEND=$(tail -c 6000 "$WEBLOG" 2>/dev/null | awk '/followup from private/{f=NR} /turn\/end for private/{t=NR} END{print (f>t)?1:0}')
  SIZE=$(stat -c %s "$WEBLOG" 2>/dev/null)
  [ -z "$SIZE" ] && return
  set -- $(cat "$STUCK_STATE" 2>/dev/null)
  PS=${1:-0}
  PD=${2:-0}
  if [ "$PEND" != "1" ] || [ "$SIZE" != "$PS" ]; then
    echo "$SIZE 0" > "$STUCK_STATE"
    return
  fi
  if [ "$PD" -eq 0 ]; then
    echo "$SIZE $NOW" > "$STUCK_STATE"
    return
  fi
  [ "$((NOW - PD))" -ge "$STUCK_SEC" ] || return

  # 假阳性护栏：真干活的时候（刷 App、调工具）CPU 不会是 0。忙就延后 5 分钟再判。
  if cpu_busy; then
    echo "$SIZE $NOW" > "$STUCK_STATE"
    return
  fi

  log "stuck: no turn/end for $((NOW - PD))s (log=$SIZE)"
  LASTFIX=$(cat "$FIX_STATE" 2>/dev/null)
  ROTATED=0
  if [ -n "$LASTFIX" ] && [ "$((NOW - LASTFIX))" -lt "$FIX_COOLDOWN" ]; then
    rotate_session
    ROTATED=1
    log "stuck recurs within $((FIX_COOLDOWN / 60))min -> session rotated"
  fi
  echo "$NOW" > "$FIX_STATE"
  restart_dsh
  if [ "$ROTATED" = "1" ]; then
    inject "（系统提示，不是他发的消息。刚才会话太长卡住了，我换了一个新会话重启，你还是你。他上一条你还没回到，现在回他一下，别解释技术细节。）"
  else
    inject "（系统提示，不是他发的消息。刚才卡了几分钟、没回成话，现在已经重启好了。他上一条你还没回到，现在回他一下。）"
  fi
  log "stuck fix done (rotated=$ROTATED, dsh restarted)"
  echo "0 0" > "$STUCK_STATE"
}

memguard() {
  LAST=$(cat "$MEM_STATE" 2>/dev/null)
  if [ -n "$LAST" ] && [ "$((NOW - LAST))" -lt "$MEM_EVERY" ]; then
    return
  fi
  AV=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)
  [ -z "$AV" ] && return
  if [ "$AV" -ge "$MEM_LOW_KB" ]; then
    echo "$NOW" > "$MEM_STATE"
    return
  fi
  FG=$(dumpsys activity activities 2>/dev/null \
    | sed -n 's/.*topResumedActivity=ActivityRecord{[^}]* u0 \([^/]*\)\/.*/\1/p' | head -1)
  KILLED=""
  for pkg in $MEM_APPS; do
    [ "$pkg" = "$FG" ] && continue
    if pidof "$pkg" >/dev/null 2>&1; then
      am force-stop "$pkg" 2>/dev/null
      KILLED="$KILLED $pkg"
    fi
  done
  echo "$NOW" > "$MEM_STATE"
  if [ -n "$KILLED" ]; then
    log "memguard avail=$((AV/1024))MB fg=$FG killed:$KILLED"
  else
    log "memguard avail=$((AV/1024))MB fg=$FG nothing-to-kill"
  fi
}

mkdir -p "$DIR" 2>/dev/null
chown u0_a234:u0_a234 "$DIR" 2>/dev/null
chmod 755 "$DIR" 2>/dev/null

log "remind watcher started (dir=$DIR interval=${INTERVAL}s)"

while true; do
  NOW=$(date +%s)
  HH=$(date +%H)
  D=$(date +%F)

  # DSH 没起来时不要注入：插件启动时会把已存在的行当「历史」跳过，
  # 那样提醒就静默丢了。留着文件下一轮再试。
  if ss -lntp 2>/dev/null | grep -q ':3080'; then
    for f in "$DIR"/*.txt; do
      [ -f "$f" ] || continue
      BASE=$(basename "$f" .txt)
      # 文件名两种：<unix秒>.txt（一次）  <unix秒>.daily.txt（每天这个点再来一次）
      # 每天重复是 2026-10-30 加的 —— 她原来的 07:30 得每天自己重挂，
      # 哪天忙忘了或者换会话就断，反而最需要它的日子没有。
      REPEAT=0
      NAME=$BASE
      case "$BASE" in
        *.daily) NAME=${BASE%.daily}; REPEAT=1 ;;
      esac
      case "$NAME" in
        ''|*[!0-9]*) log "skip bad name: $BASE (must be unix epoch[.daily])"; continue ;;
      esac
      [ "$NAME" -le "$NOW" ] || continue

      TEXT=$(tr -d '\012\015' < "$f" | sed 's/["\\]//g' | head -c 400)
      if [ -z "$TEXT" ]; then
        rm -f "$f"
        log "empty reminder dropped due=$NAME"
        continue
      fi

      LATE=$(( NOW - NAME ))
      printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
        "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"
      rm -f "$f"
      log "fired due=$NAME late=${LATE}s repeat=$REPEAT text=$TEXT"

      # 每天重复的：排下一次。手机可能几天没开机，一次只补一天，
      # 多余的不能攒着（连着弹三天提醒比漏一天更烦），直接跳到未来的第一个点。
      if [ "$REPEAT" = "1" ]; then
        NEXT=$(( NAME + 86400 ))
        while [ "$NEXT" -le "$NOW" ]; do
          NEXT=$(( NEXT + 86400 ))
        done
        printf '%s\n' "$TEXT" > "$DIR/$NEXT.daily.txt"
        chown u0_a234:u0_a234 "$DIR/$NEXT.daily.txt" 2>/dev/null
        log "重复提醒已排下一次 due=$NEXT"
      fi
    done
  fi

  # ── 她自己出去玩的续敲 ──
  # 她（或管理员让她）出去玩时，先写 /root/.dsh/play.now（内容 date +%s 的结果），
  # 这里就每 2 分钟叫她一次「接着玩」，最多 4 次、30 分钟窗口。
  if [ -f "$PLAY_MARK" ]; then
    TS=$(tr -dc '0-9' < "$PLAY_MARK" 2>/dev/null | head -c 12)
    rm -f "$PLAY_MARK"
    # 工作日 17:00 前不接受「出去玩」（10-26 用户要求：白天价格高峰，成本太高）
    PHH=$(date +%H | sed 's/^0//'); [ -z "$PHH" ] && PHH=0
    PDOW=$(date +%u)
    if [ "$PDOW" -lt 6 ] && [ "$PHH" -lt 17 ]; then
      log "play mark ignored (weekday before 17:00 hh=$PHH)"
    elif [ -n "$TS" ]; then
      echo "$TS 0 $TS" > "$PLAY_STATE"
      log "play session accepted (start=$TS)"
    fi
  fi
  if [ -f "$PLAY_STATE" ]; then
    set -- $(cat "$PLAY_STATE" 2>/dev/null)
    PST=${1:-0}; PCNT=${2:-0}; PLAST=${3:-0}
    if [ "$NOW" -ge $((PST + PLAY_WINDOW)) ] || [ "$PCNT" -ge "$PLAY_MAX" ]; then
      rm -f "$PLAY_STATE"
      log "play session ended (cnt=$PCNT)"
    elif [ "$((NOW - PLAST))" -ge "$PLAY_GAP" ]; then
      if ss -lntp 2>/dev/null | grep -q ':3080'; then
        HM=$(date +%H:%M)
        inject "（$HM·系统提示，不是他发的消息。接着玩，别急着回来，多去看几条。刚看到/学到的，记得落进 memory/说话方式.md。）"
        echo "$PST $((PCNT + 1)) $NOW" > "$PLAY_STATE"
        log "play continue #$((PCNT + 1))"
      fi
    fi
  fi

  # ── 每天 00:00：收工提示（让她写日记 + 给下一个自己的便条）──
  if [ "$HH" = "00" ]; then
    if [ "$(cat "$CLOSE_STATE" 2>/dev/null)" != "$D" ]; then
      E=$((NOW - 86400))
      YDAY=$(date -d "@$E" +%F 2>/dev/null)
      [ -z "$YDAY" ] && YDAY="昨天"
      inject "（00:00·系统提示，不是他发的消息。今天到这儿了。睡前写两样东西：diary/$YDAY.md 记今天发生的事和感受；memory/交接.md 覆盖写、不超过五百字，写给明天的自己——现在我是谁、今天学到什么、明天要记得什么。写完就睡，这条不用回。）"
      echo "$D" > "$CLOSE_STATE"
      log "close-of-day nudge sent (yday=$YDAY)"
    fi
  fi

  # ── 每天 05:00：换新会话（这个点她必然在睡；还在聊就跳过）──
  if [ "$HH" = "05" ] && [ "$(cat "$ROT_STATE" 2>/dev/null)" != "$D" ]; then
    if [ ! -f /data/adb/budget/BRAKE ] && ss -lntp 2>/dev/null | grep -q ':3080'; then
      LM=$(stat -c %Y "$WEBLOG" 2>/dev/null)
      if [ -z "$LM" ]; then
        LM=0
      fi
      if [ "$((NOW - LM))" -gt 600 ]; then
        rotate_session
        echo "$D" > "$ROT_STATE"
        log "daily rotate (quiet $(( (NOW - LM) / 60 ))m) -> new session"
        restart_dsh
        log "daily rotate done (dsh restarted)"
        echo "0 0" > "$STUCK_STATE"
      else
        log "daily rotate skipped: active $(( (NOW - LM) / 60 ))m ago"
      fi
    fi
  fi

  # 每天一次查 BreezeBlue 余额（Free 计划月度配额为 0，只有每天 400 需手动领）
  sh /data/adb/breeze-check.sh >/dev/null 2>&1

  stuckwatch

  memguard

  sleep $INTERVAL
done
