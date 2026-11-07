#!/system/bin/sh
# DSH 日常维护：工作区备份 + 守护日志轮转
# 由 service.d/99-dsh-maintenance.sh 拉起，每小时检查一轮
#
# 1) 工作区备份：每天第一次跑到时，把 /root（memory/diary/roles/AGENTS*）
#    拷到 /data/adb/backup/workspace/<日期>/，保留最近 7 份。
#    她写的记忆/日记目前没有任何备份，手机一坏就全没 —— 这是唯一的正本。
# 2) 日志轮转：consent/heartbeat/heal 等日志超过 200KB 就只留尾部 50KB。

LOG=/data/adb/maint.log

# 10-24 12:10 起权威工作区是 /root（读写都在这儿），default-workspace 只是冗余副本
WS=/data/data/dsh.android.client/files/linux/ubuntu/root
BK=/data/adb/backup/workspace

# 会话目录归档：换会话后会留下死目录（session.v4.jsonl.zstd 不再被任何映射引用），
# 长期堆积拖慢 du/ls/备份扫描。按「最近 N 个」保留，更早的移到归档目录，不删（留作翻旧账）。
# ⚠️ 必须放在 WS= 之后：shell 是顺序展开的，写在前面会展开成空路径（10-26 踩过）
SESS_DIR=$WS/.dsh/sessions/--root--
SESS_ARCH=/data/adb/backup/sessions-archive
SESS_KEEP=4        # 当前 + 最近 3 个历史

log() { echo "$(date '+%F %T') $*" >> $LOG; }

backup_workspace() {
  TODAY=$(date +%F)
  DST=$BK/$TODAY
  [ -d "$DST" ] && return 0            # 今天已备过
  [ -d "$WS" ] || { log "工作区不存在 $WS"; return 1; }
  mkdir -p "$DST" 2>/dev/null
  cp -r $WS/memory $WS/diary $WS/roles "$DST"/ 2>/dev/null
  cp -p $WS/AGENTS.md $WS/AGENTS.local.md "$DST"/ 2>/dev/null
  # 用 App 属主备一份可读的（防 root 属主文件混进备份后恢复时踩 hmr 的坑）
  # chmod 只改权限位，属主还是 root —— 必须一起 chown，否则哪天从备份恢复
  # 又是一堆 EACCES（10-30 查备份时发现 169 个文件全是 root）
  chown -R u0_a264:u0_a264 "$DST" 2>/dev/null
  chmod -R u+rwX,go+rX "$DST"
  N=$(find "$DST" -type f | wc -l)
  log "工作区已备份 -> $DST ($N 个文件)"
  # 只留最近 7 份（Android 的 head 不支持负数，先数数量）
  CNT=$(ls -1 $BK 2>/dev/null | wc -l)
  if [ "$CNT" -gt 7 ]; then
    ls -1 $BK | sort | head -n $((CNT - 7)) | while read -r OLD; do
      rm -rf "$BK/$OLD"
      log "清理旧备份 $OLD"
    done
  fi
}

rotate_logs() {
  for F in /data/adb/consent.log /data/adb/heartbeat.log /data/adb/dsh-heal.log \
           /data/adb/night.log /data/adb/budget/log /data/adb/maint.log; do
    [ -f "$F" ] || continue
    SZ=$(wc -c "$F" 2>/dev/null | awk '{print $1}')
    [ -z "$SZ" ] && continue
    if [ "$SZ" -gt 200000 ]; then
      tail -c 50000 "$F" > "$F.tmp" && mv "$F.tmp" "$F"
      log "日志轮转 $F ($(wc -c < "$F")B)"
    fi
  done
}

prune_sessions() {
  [ -d "$SESS_DIR" ] || return
  mkdir -p "$SESS_ARCH"
  TMP=/data/local/tmp/sess.list
  : > "$TMP"
  for d in "$SESS_DIR"/*/; do
    d=${d%/}
    name=${d##*/}
    f="$SESS_DIR/$name/session.v4.jsonl.zstd"
    [ -f "$f" ] || continue
    ts=$(stat -c %Y "$f" 2>/dev/null)
    [ -n "$ts" ] && echo "$ts $name" >> "$TMP"
  done
  # 按会话文件 mtime 从新到旧，跳过前 SESS_KEEP 个，其余归档
  i=0
  sort -rn "$TMP" 2>/dev/null | while read -r _ts name; do
    i=$((i + 1))
    [ "$i" -le "$SESS_KEEP" ] && continue
    if mv "$SESS_DIR/$name" "$SESS_ARCH/$name" 2>/dev/null; then
      log "会话归档 $name"
    fi
  done
  rm -f "$TMP"
}

fix_owner() {
  # 属主/标签自愈（2026-10-30 加）
  #
  # 为什么需要：DSH 是以 root 身份跑 proot 的（dsh-start.sh 里 su -c），
  # 所以她写出来的每一个文件属主都是 root、SELinux 标签是 app_data_file:s0。
  # 一旦启动方式变回 App 自己拉 proot（u0_a264 / s0:c234,...），这些文件
  # 立刻写不进——表现就是 EACCES + 会话保存失败 + 记忆写不进去。
  # 10-29（67 个）、10-30（87 个）各踩过一次，第二次连当前会话目录都是 root。
  #
  # 只改权限元数据，不碰内容。跳过 node_modules（几万个文件，扫起来慢且不会出问题）。
  P='*/node_modules/*'
  N=$(find "$WS" -not -path "$P" -not -user u0_a264 2>/dev/null | wc -l)
  if [ "$N" -gt 0 ]; then
    find "$WS" -not -path "$P" -not -user u0_a264 2>/dev/null \
      -exec chown u0_a264:u0_a264 {} +
    log "属主自愈：修正 $N 项（原本是 root）"
  fi
  M=$(find "$WS" -not -path "$P" -not -context "u:object_r:app_data_file:s0:c234,c256,c512,c768" \
      -type f 2>/dev/null | wc -l)
  if [ "$M" -gt 0 ]; then
    find "$WS" -not -path "$P" -not -context "u:object_r:app_data_file:s0:c234,c256,c512,c768" \
      -type f 2>/dev/null -exec chcon u:object_r:app_data_file:s0:c234,c256,c512,c768 {} +
    log "标签自愈：修正 $M 个文件"
  fi
}

# ── 2026-11-06：给 proot 里看的宿主快照 ───────────────────────────────
# 她在 proot 里读不到 /data/adb（那是宿主 root 的目录，没挂载进容器）。
# 「语音/图片不见了，是不是有脚本在清」这类问题以前只能靠管理员去查。
# 这里每小时把最常问的几件事导成一份纯文本，她 cat /root/.dsh/adb-peek.txt 就有答案。
#
# ⚠️ 判断守护是否在跑**不能用** `ps -A -o NAME | grep dsh-`：toybox 的 NAME 列只显示
# "sh"，grep 永远 0 个，11-06 我自己就被这个骗过一次（以为 15 个守护全挂了）。
# 必须读 /proc/PID/cmdline。
adb_peek() {
  OUT="$WS/.dsh/adb-peek.txt"
  TMP="$OUT.tmp"
  {
    echo "# /data/adb 快照  $(date '+%F %T')"
    echo "# 由 dsh-maintenance.sh 每小时刷新。proot 里读不到 /data/adb，看这份就够。"
    echo
    echo "## 守护脚本（当前在跑的）"
    for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
      tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -oE '/data/adb/[a-z0-9-]+\.sh'
    done | sed 's#/data/adb/##' | sort -u | sed 's/^/  /'
    echo
    echo "## 媒体目录实况"
    echo "  media/onebot  文件 $(ls "$WS/.dsh/media/onebot" 2>/dev/null | wc -l) 个，其中 say-*.mp3 $(ls "$WS/.dsh/media/onebot"/say-*.mp3 2>/dev/null | wc -l) 条"
    echo "  media/tts     文件 $(ls "$WS/.dsh/media/tts" 2>/dev/null | wc -l) 个"
    echo "  images/       归档 $(find "$WS/images" -type f 2>/dev/null | wc -l) 个"
    echo
    echo "## 清理规则（一句话版）"
    echo "  media_* / stt_*       插件 tempTtlHours 到期删（现在 24 小时，按 mtime 算）"
    echo "  say-*.mp3             /root/say 只留最近 40 条；media/tts 里的原件不动"
    echo "  media/tts/*           不自动清理"
    echo "  chat-sessions.json    状态文件，任何清理都不碰"
    echo "  qq-*.jsonl            审计/注入日志，只按大小轮转，不删内容"
    echo "  memes/                表情库，不自动清理"
    echo
    echo "## 日志尾"
    # ⚠️ 只有 heal 是 dsh- 前缀，其余几个是简称（remind.log / maint.log / push.log）。
    # 11-06 第一版统一拼成 dsh-$f.log，结果 remind 和 maint 两段永远是空的 —— 假信息比没信息更坏。
    for f in dsh-heal.log remind.log maint.log push.log heartbeat.log; do
      echo "  --- $f ---"
      tail -3 "/data/adb/$f" 2>/dev/null | sed 's/^/    /'
    done
    echo
    echo "## 预算 / 内存"
    [ -f /data/adb/budget/BRAKE ] && echo "  ⚠ BRAKE 生效中（停机到次日 08:00）"
    [ -f /data/adb/budget/ALARM ] && echo "  ⚠ ALARM 已触发（接近上限）"
    grep -E 'MemAvailable' /proc/meminfo 2>/dev/null | sed 's/^/  /'
    echo "  磁盘 /data: $(df -h /data 2>/dev/null | tail -1 | awk '{print $4" 可用 / "$2" 总"}')"
  } > "$TMP" 2>/dev/null
  if [ -s "$TMP" ]; then
    chown 10234:10234 "$TMP" 2>/dev/null
    chmod 644 "$TMP" 2>/dev/null
    chcon u:object_r:app_data_file:s0:c234,c256,c512,c768 "$TMP" 2>/dev/null
    mv -f "$TMP" "$OUT" 2>/dev/null
  fi
}

if [ "$1" = "once" ]; then
  fix_owner
  backup_workspace
  rotate_logs
  prune_sessions
  adb_peek
  echo OK
  exit 0
fi

log "maintenance loop started"
while true; do
  fix_owner
  backup_workspace
  rotate_logs
  prune_sessions
  adb_peek
  sleep 3600
done
