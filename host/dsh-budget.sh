#!/system/bin/sh
# 大肥鱼日预算刹车（余额差分法）
# 原理：每 10 分钟查一次 DeepSeek 余额，当日消耗 = 当日基准余额 - 当前余额
#   >= 9 元  → 写 ALARM 并直接给她注入一条提醒（她会跟管理员说一声）
#   >= 10 元 → 写 BRAKE 文件并 force-stop DSHA；自愈脚本看到 BRAKE 不会拉活
#   次日 08:00 后自动解除（夜里不重启，避免盲点屏幕）
# 不依赖电脑、不依赖 proot 里的 python/zstd。

CRED=/data/data/dsh.android.client/files/linux/ubuntu/root/.dsh/.credentials.yaml
# 给她自己看的账本（这个路径在 proot 里能看到，/data/adb 她看不到）
LEDGER=/data/data/dsh.android.client/files/linux/ubuntu/root/budget.txt
DIR=/data/adb/budget
LOG=$DIR/log
STATE=$DIR/state
LAST=$DIR/last
ALARM=$DIR/ALARM
BRAKE=$DIR/BRAKE
# 默认额度
DEF_WARN=9
DEF_STOP=10
WARN=$DEF_WARN
STOP=$DEF_STOP
# 当日临时额度：$DIR/override 里写 "YYYY-MM-DD warn stop"，只有日期等于今天时才生效。
# ⚠️ 必须**每轮重读**：只在启动时读一次的话，跨天后还会按着过期的临时额度走
#    （10-27 踩到——守护是 25 号带着 12/15 启动的，26、27 号账本还写着 15 元停机）。
OV=$DIR/override
INTERVAL=600
INJ=/data/data/dsh.android.client/files/linux/ubuntu/root/.dsh/media/onebot/qq-inject.jsonl
ADMIN=781073897
BOT=429316849

mkdir -p $DIR

log() { echo "$(date '+%F %T') $*" >> $LOG; }

# 每轮重新算一次生效额度：override 日期对不上今天 → 退回默认 9/10
load_limits() {
  W=$DEF_WARN
  S=$DEF_STOP
  OVD=""
  if [ -f "$OV" ]; then
    read -r OVD OVW OVS < "$OV" 2>/dev/null
    if [ "$OVD" = "$(date +%F)" ] && [ -n "$OVS" ]; then
      W=$OVW
      S=$OVS
    fi
  fi
  if [ "$W" != "$WARN" ] || [ "$S" != "$STOP" ]; then
    log "limits reloaded: warn=$WARN stop=$STOP -> warn=$W stop=$S (override=${OVD:-none})"
  fi
  WARN=$W
  STOP=$S
}

get_balance() {
  KEY=$(grep -o 'sk-[0-9a-zA-Z]\{20,\}' "$CRED" 2>/dev/null | head -1)
  [ -z "$KEY" ] && KEY="sk-3bcb886ece5e48cfa7ea7cffb2002b6d"
  curl -s -m 20 --retry 1 https://api.deepseek.com/user/balance \
    -H "Authorization: Bearer $KEY" 2>/dev/null \
    | grep -o '"total_balance":"[0-9.]*"' | head -1 | cut -d'"' -f4
}

ge() { awk "BEGIN{exit !($1 >= $2)}"; }

load_limits
log "budget guard started (warn=$WARN stop=$STOP interval=${INTERVAL}s)"

while true; do
  TODAY=$(date +%F)
  HOUR=$(date +%H | sed 's/^0//')
  [ -z "$HOUR" ] && HOUR=0
  load_limits
  BAL=$(get_balance)

  if [ -n "$BAL" ]; then
    set -- $(cat $STATE 2>/dev/null)
    SDATE=$1
    SBASE=$2
    SSPENT=${3:-0}
    SLAST=${4:-$2}

    # 跨天：重置基准，清掉昨天的提醒
    if [ "$SDATE" != "$TODAY" ]; then
      SDATE=$TODAY
      SBASE=$BAL
      SSPENT=0
      SLAST=$BAL
      rm -f $ALARM
      log "day rollover, baseline=$BAL"
    fi

    # 跨天后解除熔断（只在 08:00 之后，白天自愈脚本能正常点屏幕）
    if [ -f $BRAKE ]; then
      BDATE=$(cat $BRAKE 2>/dev/null)
      if [ "$BDATE" != "$TODAY" ] && [ "$HOUR" -ge 8 ]; then
        rm -f $BRAKE
        log "brake cleared (new day, hour=$HOUR)"
      fi
    fi

    # 只累加余额下降；余额上升视为充值（否则算成负消费，阈值永远不触发）
    SSPENT=$(awk "BEGIN{d=$SLAST-$BAL; s=$SSPENT; if(d>0) s+=d; printf \"%.4f\", s}")
    if awk "BEGIN{exit !($BAL > $SLAST)}"; then
      log "topup/refund: $SLAST -> $BAL (accumulated spend stays $SSPENT)"
    fi
    SLAST=$BAL
    SPENT=$SSPENT
    echo "$TODAY base=$SBASE now=$BAL spent=$SPENT" > $LAST
    {
      echo "日期：$TODAY"
      echo "今日已花：$SPENT 元"
      echo "预算线：$STOP 元（到 $WARN 元先提醒管理员，到 $STOP 元会被强制停机）"
      echo "余额：$BAL 元"
      [ -f $ALARM ] && echo "状态：已经花到 $WARN 元，离 $STOP 元停机线只剩一点，跟他说一声，让他决定还玩不玩"
      [ -f $BRAKE ] && echo "状态：已熔断停机"
    } > $LEDGER

    if [ -f $BRAKE ]; then
      :
    elif ge "$SPENT" "$STOP"; then
      echo "$TODAY" > $BRAKE
      log "BRAKE: spent=$SPENT >= $STOP, force-stop DSHA"
      am force-stop dsh.android.client
    elif ge "$SPENT" "$WARN"; then
      if [ ! -f $ALARM ]; then
        echo "$TODAY $SPENT" > $ALARM
        log "WARN: spent=$SPENT >= $WARN"
        # 光写文件她不一定去看，直接把话递到她面前（DSH 不在线就别塞，插件会把旧行当历史跳过）
        if ss -lntp 2>/dev/null | grep -q ':38571'; then
          NOW=$(date +%s)
          TEXT="（$(date +%H:%M)·系统提示，不是他发的消息。今天已经花到 $SPENT 元，离 $STOP 元的停机线只剩一点了。跟他说一声，让他决定还玩不玩。）"
          printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
            "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"
          log "WARN injected to chat"
        fi
      fi
    fi

    echo "$SDATE $SBASE $SSPENT $SLAST" > $STATE
  else
    log "balance fetch failed"
  fi

  sleep $INTERVAL
done
