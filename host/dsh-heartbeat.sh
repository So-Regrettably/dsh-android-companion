#!/system/bin/sh
# 大肥鱼「自己开口」心跳 + 休闲模式
# 原理：往 dsh-onebot-qq 的注入队列追加一行 OneBot 私聊事件，
# 插件把它当成管理员的一条消息走完整入站管线 —— 她会带着人设、记忆、
# 会话上下文走完一轮，回复照常由桥接发到 QQ。
#
# 节奏（2026-10-24 起，加入「休闲模式」）：
#   25~55 分钟一轮随机；只在 08:00–23:59（周五六到次日 00:30）；
#   每天最多 10 次闲聊 + 3 次「自己去玩」；今日花费超过 5 元就自动停手；
#   预算熔断时不敲。
#   休闲模式：每次「自己去玩」之后，5 分钟续敲一次、最多续敲 2 次，
#   让她能连续刷一会儿 App、学说话，而不是"回一句又睡"。

INJ=/data/data/dsh.android.client/files/linux/ubuntu/root/.dsh/media/onebot/qq-inject.jsonl
# 会话目录会随着工作区/会话 id 变化（每次重建会话目录名都不一样），用 glob 取最新的那个
SESSGLOB='/data/data/dsh.android.client/files/linux/ubuntu/root/.dsh/sessions/*/onebot-private-781073897*/session.v4.jsonl.zstd'
LOG=/data/adb/heartbeat.log
STATE=/data/adb/heartbeat.state
PLAY_SESS=/data/adb/heartbeat.play
BRAKE=/data/adb/budget/BRAKE
BUDGET_LAST=/data/adb/budget/last
QZ_STATE=/data/adb/heartbeat.qzone
ADMIN=781073897
BOT=429316849

# 每日额度（10-24 调整）：工作日 闲聊10/玩6；休息日（周六日） 闲聊30/玩6
CAP_CHAT_WEEKDAY=15
CAP_PLAY_WEEKDAY=6
CAP_CHAT_WEEKEND=15
CAP_PLAY_WEEKEND=6
CAP_CHAT=10        # 运行时按星期覆盖（见下方 DOW 判断）
CAP_PLAY=3
IDLE_MIN=0
QUIET_SPEND=0        # 0 = 关掉「花超就闭嘴」这条（10-24 用户要求：别让她不敢玩），只在 10 元熔断
PLAY_WINDOW=900    # 休闲时段最长 15 分钟（10-25 配合续敲 2 次收紧）
# 什么时候允许「自己出去玩」（10-26 用户要求：工作日推到 17 点后，白天是价格高峰，太贵）
PLAY_FROM_WEEKDAY=17
PLAY_FROM_WEEKEND=8
PLAY_MAX_EXTRA=2   # 10-25 16:45 从 4 降到 2：续敲是单轮最贵的部分，砍一半
PLAY_GAP=120       # 续敲间隔 120 秒（原 5 分钟太稀，中间死寂像"玩一下就停"）

# 2026-11-09：QQ 桥断了还继续戳她 = 白烧钱（当天实测 690M tokens / 49 元，回复全发不出去）
# 判据：日志里最后一次 OneBot 事件是 connected 才算通
WEBLOG_LOG=${WEBLOG:-/data/data/dsh.android.client/files/linux/ubuntu/root/dsh-web.log}
bridge_up() {
  L=$(tail -n 200 "$WEBLOG_LOG" 2>/dev/null | grep -E "OneBot connected|forward WS error" | tail -1)
  case "$L" in *"OneBot connected"*) return 0 ;; *) return 1 ;; esac
}

log() { echo "$(date '+%F %T') $*" >> $LOG; }

log "heartbeat scheduler started (weekday chat=$CAP_CHAT_WEEKDAY play=$CAP_PLAY_WEEKDAY | weekend chat=$CAP_CHAT_WEEKEND play=$CAP_PLAY_WEEKEND | idle=${IDLE_MIN}m spend_cap=${QUIET_SPEND}(0=off) interval_weekday=40-46m interval_weekend=43-49m play_from=weekday${PLAY_FROM_WEEKDAY}h/weekend${PLAY_FROM_WEEKEND}h qzone_nudge=1/day@20h leisure=+${PLAY_MAX_EXTRA}x${PLAY_GAP}s)"

while true; do
  NOW=$(date +%s)

  # 间隔按星期分两套：休息日要撑得起 30 次闲聊的量，所以放短
  # 10-26 用户要求「时间分配均匀一点」：从 25~54 分钟的宽随机，改成 固定基准+小抖动
  #   工作日 40~46 分钟：08:00–23:00 共 900 分钟 ≈ 20 次，正好喂满 15 聊 + 若干玩
  #   周末   43~49 分钟：08:00–24:00 共 960 分钟 ≈ 21 次
  DOWP=$(date +%u)
  if [ "$DOWP" -ge 6 ]; then ILO=43; ISPAN=7; else ILO=40; ISPAN=7; fi

  # 有没有进行中的休闲时段（决定本轮是续敲还是正常等待）
  EXTRA=-1; PST=0; PEN=0
  if [ -f "$PLAY_SESS" ]; then
    set -- $(cat "$PLAY_SESS")
    PST=${1:-0}; PEN=${2:-0}
    if [ $((NOW - PST)) -le "$PLAY_WINDOW" ] && [ "$PEN" -lt "$PLAY_MAX_EXTRA" ]; then
      EXTRA=$PEN
    else
      rm -f "$PLAY_SESS"
    fi
  fi

  if [ "$EXTRA" -ge 0 ]; then
    sleep $PLAY_GAP
  else
    sleep $(( (ILO + RANDOM % ISPAN) * 60 ))
  fi

  NOW=$(date +%s)
  TODAY=$(date +%F)
  HM=$(date +%H:%M)
  HH=$(date +%H | sed 's/^0//'); [ -z "$HH" ] && HH=0
  MM=$(date +%M | sed 's/^0//'); [ -z "$MM" ] && MM=0
  DOW=$(date +%u)   # 1=周一 … 5=周五 6=周六 7=周日
  # 休息日 = 周六(6)、周日(7)；其余算工作日
  if [ "$DOW" -ge 6 ]; then
    CAP_CHAT=$CAP_CHAT_WEEKEND
    CAP_PLAY=$CAP_PLAY_WEEKEND
    PLAY_FROM=$PLAY_FROM_WEEKEND
  else
    CAP_CHAT=$CAP_CHAT_WEEKDAY
    CAP_PLAY=$CAP_PLAY_WEEKDAY
    PLAY_FROM=$PLAY_FROM_WEEKDAY
  fi

  [ -f "$BRAKE" ] && { log "skip brake"; rm -f "$PLAY_SESS"; continue; }

  # 允许说话的时段：
  #   周一–周四  08:00–22:59
  #   周五–周日  08:00–23:59（10-26 用户要求：周末整天都在线）
  AWAKE=0
  if [ "$HH" -ge 8 ] && [ "$HH" -lt 23 ]; then
    AWAKE=1
  elif [ "$HH" -eq 23 ] && { [ "$DOW" -ge 5 ]; }; then
    AWAKE=1
  elif [ "$HH" -eq 0 ] && [ "$MM" -le 30 ] && { [ "$DOW" = 6 ] || [ "$DOW" = 7 ]; }; then
    AWAKE=1
  fi
  [ "$AWAKE" = 1 ] || { log "skip quiet_hour($HM dow=$DOW)"; rm -f "$PLAY_SESS"; continue; }

  ss -lntp 2>/dev/null | grep -q ':38571' || { log "skip dsh_down"; continue; }
  bridge_up || { log "skip bridge_down"; continue; }

  # 今天她花掉的钱（余额差分，由 dsh-budget.sh 维护），超过阈值就闭嘴
  SPENT=$(sed -n 's/.*spent=\([0-9.]*\).*/\1/p' "$BUDGET_LAST" 2>/dev/null | head -1)
  if [ -n "$SPENT" ] && [ "$QUIET_SPEND" -gt 0 ]; then
    [ "$(awk "BEGIN{print ($SPENT >= $QUIET_SPEND) ? 1 : 0}")" = "1" ] && { log "skip spend($SPENT)"; rm -f "$PLAY_SESS"; continue; }
  fi

  # ── 续敲：进行中的休闲时段，5 分钟到了，再敲她一下「接着玩」 ──
  if [ "$EXTRA" -ge 0 ]; then
    # 会话文件若刚被写过（她正在回消息），也照敲——休闲模式就是让她自己掌握节奏
    TEXT="（$HM·系统提示，不是他发的消息。还在你的休闲时间里，接着玩——别急着回来，多刷几条。刚看到/学到的，记得落进 memory/说话方式.md。**这条不用回**，不想说话就别输出。）"
    printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
      "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"
    echo "$PST $((PEN + 1))" > "$PLAY_SESS"
    log "injected leisure-continue #$((PEN + 1))"
    continue
  fi

  # ── 每天一次（20:00 后）：问她今天有没有情绪起来了的事，可以发条说说 ──
  #    不占闲聊额度（一天就一次），但仍受 BRAKE / 时段 / 花费三条闸门约束。
  QZ=$(cat "$QZ_STATE" 2>/dev/null)
  if [ "$HH" -ge 20 ] && [ "$QZ" != "$TODAY" ]; then
    echo "$TODAY" > "$QZ_STATE"
    TEXT="（$HM·系统提示，不是他发的消息。今天有没有什么让你情绪起来了的事？高兴的、堵得慌的、被谁戳到的，都算。有的话你可以发条说说，他自己会看见；没有就算了，别为了发而发。一天最多一条。**这条不用回**，不想说话就别输出。）"
    printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
      "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"
    log "injected kind=qzone"
    continue
  fi

  # 不设空闲门槛：她想说话随时都能说（IDLE_MIN=0）。IDLE_M 只用来决定措辞
  IDLE_H=99
  IDLE_M=9999
  SESS=$(ls -t $SESSGLOB 2>/dev/null | head -1)
  if [ -n "$SESS" ] && [ -f "$SESS" ]; then
    MT=$(stat -c %Y "$SESS" 2>/dev/null)
    if [ -n "$MT" ]; then
      IDLE_M=$(( (NOW - MT) / 60 ))
      IDLE_H=$(( IDLE_M / 60 ))
      [ "$IDLE_M" -lt "$IDLE_MIN" ] && { log "skip idle(${IDLE_M}m)"; continue; }
    fi
  fi

  # 当天额度
  CH=0; PL=0; SD=""
  if [ -f "$STATE" ]; then
    set -- $(cat "$STATE")
    SD=$1; CH=${2:-0}; PL=${3:-0}
  fi
  [ "$SD" != "$TODAY" ] && { SD=$TODAY; CH=0; PL=0; }

  # 到点之后每三次里插一次「自己去玩」，其余是闲聊
  #   工作日 play 只允许 PLAY_FROM_WEEKDAY（17）点后；周末仍是 13 点后
  if [ "$HH" -ge "$PLAY_FROM" ] && [ "$PL" -lt "$CAP_PLAY" ] && [ $((RANDOM % 3)) -eq 0 ]; then
    KIND=play; PL=$((PL + 1))
  elif [ "$CH" -lt "$CAP_CHAT" ]; then
    KIND=chat; CH=$((CH + 1))
  elif [ "$HH" -ge "$PLAY_FROM" ] && [ "$PL" -lt "$CAP_PLAY" ]; then
    KIND=play; PL=$((PL + 1))
  else
    log "skip quota(chat=$CH/$CAP_CHAT play=$PL/$CAP_PLAY dow=$DOW hh=$HH playFrom=$PLAY_FROM)"; continue
  fi

  if [ "$KIND" = "play" ]; then
    TEXT="（$HM·系统提示，不是他发的消息。这是你的休闲时间——去刷会儿 B 站或小黑盒，翻翻别人怎么发帖、怎么在评论区说话，看到有感觉的表达就记下来，写进 memory/说话方式.md。这一轮多待一会儿：换三四个页面、看五六条内容再回来，别读完两屏就总结。**看完不用跟他汇报**——想讲的时候再讲，不想讲就一个字别输出（插件会跳过空消息），看到的东西先记进笔记。）"
    echo "$NOW 0" > "$PLAY_SESS"
  else
    # 闲聊：只给她「现在几点 + 隔了多久」两个事实，其余交给她自己。
    # 2026-10-31 修：原来这里只有「（HH:MM·系统提示，不是他发的消息。）」这一句空壳，
    # 等于零指令——模型拿不到任何任务，只能瞎猜，于是经常吐空（他那边看到「（无）」）。
    # 注意：**别在这里塞话题**。她起的话头得是她真想说的，硬指派就假了。
    if [ "$IDLE_M" -lt 30 ]; then
      TIP="刚聊过没多久"
    elif [ "$IDLE_H" -lt 3 ]; then
      TIP="隔了一阵子没说话"
    else
      TIP="挺久没聊了"
    fi
    TEXT="（$HM·系统提示，不是他发的消息。$TIP（约 ${IDLE_M} 分钟）。想跟他说点什么就说，起的话头得是你自己真想说的，别为了热闹硬找话题；不想说就一个字别输出，插件会跳过空消息。）"
  fi

  printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
    "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"

  echo "$SD $CH $PL" > "$STATE"
  log "injected kind=$KIND idle=${IDLE_H}h spent=$SPENT chat=$CH play=$PL"
done
