#!/system/bin/sh
# 定时任务守护：把到点的任务当成一条「系统提示」投给她，让她自己干活。
#
# 为什么要在外面（不在容器里）：投递要写 qq-inject.jsonl，而"到点"这件事
# 得有人一直盯着——她的进程会睡觉、会被换掉，root 守护不会。
#
# 任务文件：<工作区>/.cron/jobs/<id>.job，一行三个字段（tab 分隔）：
#     <到期的 unix 秒>  <周期秒，0=一次性>  <内容>
# 由 /root/cron（cron.py）生成；这里只负责"到点就投、投完排下一次"。
#
# 闸门（她自己也认这几条）：
#   1. 预算熔断 BRAKE 在 → 一律不触发
#   2. 只在 08:00–23:30 触发（其余时间等着，不补发）
#   3. 每天最多 12 次
#   4. 错过太久（比如关机两天）只补未来最近的一个点，不连环补
set -u
R=/data/data/dsh.android.client/files/linux/ubuntu/root
JOBS=$R/.cron/jobs
STATE=$R/.cron/state
LOG=$R/.cron/fired.log
INJ=$R/.dsh/media/onebot/qq-inject.jsonl
BRAKE=/data/adb/budget/BRAKE
BOT=429316849
ADMIN=781073897
DAILY_CAP=12

mkdir -p "$JOBS" 2>/dev/null

in_window() {
  HH=$(date +%H | sed 's/^0//'); [ -z "$HH" ] && HH=0
  MM=$(date +%M | sed 's/^0//'); [ -z "$MM" ] && MM=0
  [ "$HH" -ge 8 ] && [ "$HH" -lt 23 ] && return 0
  [ "$HH" -eq 23 ] && [ "$MM" -le 30 ] && return 0
  return 1
}

# 当天已触发次数
bump_counter() {
  TODAY=$(date +%F)
  N=0
  if [ -f "$STATE" ]; then
    set -- $(cat "$STATE" 2>/dev/null)
    [ "${1:-}" = "$TODAY" ] && N=${2:-0}
  fi
  N=$((N + 1))
  echo "$TODAY $N" > "$STATE"
  echo "$N"
}

# 启动时若任务已经过期太久（关机等原因），把 daily/weekly 推到未来最近一个点
normalize_stale() {
  NOW=$(date +%s)
  for f in "$JOBS"/*.job; do
    [ -f "$f" ] || continue
    E=$(cut -f1 "$f" 2>/dev/null); P=$(cut -f2 "$f" 2>/dev/null); T=$(cut -f3- "$f" 2>/dev/null)
    case "$E" in ''|*[!0-9]*) continue ;; esac
    [ "$P" -gt 0 ] 2>/dev/null || continue
    # 过期超过 1 个周期 → 说明错过了，直接推到未来
    if [ "$E" -lt $((NOW - P)) ]; then
      N=$((E + P))
      while [ "$N" -le "$NOW" ]; do N=$((N + P)); done
      printf '%s\t%s\t%s\n' "$N" "$P" "$T" > "$f"
      echo "$(date '+%F %T') rearmed stale $(basename "$f") -> $N" >> "$LOG"
    fi
  done
}

echo "$(date '+%F %T') cron daemon started (cap=$DAILY_CAP/day)" >> "$LOG"
normalize_stale

while true; do
  if [ ! -f "$BRAKE" ] && in_window; then
    NOW=$(date +%s)
    for f in "$JOBS"/*.job; do
      [ -f "$f" ] || continue
      E=$(cut -f1 "$f" 2>/dev/null)
      case "$E" in ''|*[!0-9]*) continue ;; esac
      [ "$E" -le "$NOW" ] || continue

      P=$(cut -f2 "$f" 2>/dev/null)
      T=$(cut -f3- "$f" 2>/dev/null | tr -d '\012\015' | sed 's/["\\]//g' | head -c 200)
      [ -z "$T" ] && { rm -f "$f"; continue; }

      # 当天次数闸门
      TODAY=$(date +%F); N=0
      if [ -f "$STATE" ]; then
        set -- $(cat "$STATE" 2>/dev/null)
        [ "${1:-}" = "$TODAY" ] && N=${2:-0}
      fi
      if [ "$N" -ge "$DAILY_CAP" ]; then
        echo "$(date '+%F %T') skip cap($N/$DAILY_CAP) $(basename "$f")" >> "$LOG"
        sleep 60
        continue
      fi

      # 2026-11-09：QQ 桥不通就别戳她（桥断时戳一次=白烧一大笔 token）
      if ! tail -n 200 /data/data/dsh.android.client/files/linux/ubuntu/root/dsh-web.log 2>/dev/null | grep -E "OneBot connected|forward WS error" | tail -1 | grep -q "OneBot connected"; then
        echo "$(date '+%F %T') skip bridge_down $(basename "$f")" >> "$LOG"
        sleep 60
        continue
      fi

      HM=$(date +%H:%M)
      TEXT="（$HM·系统提示，不是他发的消息。这是你自己排的定时任务：$T 。做完不用跟他汇报；不想说话就一个字别输出，插件会跳过空消息。）"
      printf '{"post_type":"message","message_type":"private","sub_type":"friend","self_id":%s,"user_id":%s,"message_id":%s,"time":%s,"raw_message":"%s","message":[{"type":"text","data":{"text":"%s"}}],"sender":{"user_id":%s,"nickname":"管理员"}}\n' \
        "$BOT" "$ADMIN" "$NOW" "$NOW" "$TEXT" "$TEXT" "$ADMIN" >> "$INJ"

      CNT=$(bump_counter)
      echo "$(date '+%F %T') fired $(basename "$f") #$CNT text=$T" >> "$LOG"

      if [ "${P:-0}" -gt 0 ] 2>/dev/null; then
        NEW=$((E + P))
        while [ "$NEW" -le "$NOW" ]; do NEW=$((NEW + P)); done
        printf '%s\t%s\t%s\n' "$NEW" "$P" "$T" > "$f"
      else
        rm -f "$f"
      fi
      NOW=$(date +%s)
    done
  fi
  sleep 30
done
