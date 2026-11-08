#!/system/bin/sh
# 大肥鱼「按键/触摸」代执行守护（2026-10-24 建，11-07 扩展 swipe/tap）
#
# 为什么要有它：容器里的 su 是 Ubuntu su（只切 uid 不切 SELinux 域），
# input 在 untrusted_app 域没有 INJECT_EVENTS，直接被 MIUI 拒；
# 而 Magisk su（/system/bin/su）在 proot 里又找不到 magiskd daemon。
# 只有 host 侧的 root（magisk 域）才有 INJECT_EVENTS 权限。
# 所以：她在 proot 里写请求文件，host 侧 root 替她注入。
#
# 接口（她在 proot 里直接写 /root/.dsh/key，一行）：
#   enter / back / home / 数字        → keyevent
#   swipe x1 y1 x2 y2 [ms]            → input swipe（滑动）
#   tap x y                           → 100ms 按压点击
#   dbltap x y                        → 双击（两下，间隔 120ms）
# 结果写在 /root/.dsh/key.out（一行），日志 /data/adb/key.log
#
# 关掉：rm /data/adb/service.d/99-dsh-key.sh 并 kill 进程

WS=/data/data/dsh.android.client/files/linux/ubuntu/root
REQ=$WS/.dsh/key
OUT=$WS/.dsh/key.out
LOG=/data/adb/key.log
INTERVAL=1

log() { echo "$(date '+%F %T') $*" >> $LOG; }

do_swipe() { input swipe "$1" "$2" "$3" "$4" "$5"; }
do_tap() { input swipe "$1" "$2" "$1" "$2" 100; }
do_dbltap() { input swipe "$1" "$2" "$1" "$2" 80; sleep 0.12; input swipe "$1" "$2" "$1" "$2" 80; }

log "key/touch runner started (req=$REQ interval=${INTERVAL}s)"

while true; do
  if [ -f "$REQ" ]; then
    CMD=$(tr -d '\r\n' < "$REQ" 2>/dev/null)
    rm -f "$REQ"
    RES="ok"
    set -- $CMD
    case "$1" in
      enter|ok|go)   input keyevent 66 ;;
      search|ime)    input keyevent 84 ;;
      back)          input keyevent 4 ;;
      home)          input keyevent 3 ;;
      recents)       input keyevent 187 ;;
      esc|escape)    input keyevent 111 ;;
      del|delete)    input keyevent 67 ;;
      swipe)
        if [ "$#" -lt 5 ]; then RES="swipe_need:x1 y1 x2 y2 [ms]"; else do_swipe "$2" "$3" "$4" "$5" "${6:-300}"; fi ;;
      tap)
        if [ "$#" -lt 3 ]; then RES="tap_need:x y"; else do_tap "$2" "$3"; fi ;;
      dbltap)
        if [ "$#" -lt 3 ]; then RES="dbltap_need:x y"; else do_dbltap "$2" "$3"; fi ;;
      '')            RES="empty" ;;
      *[!0-9]*)      RES="unknown:$1" ;;
      *)             input keyevent "$1" ;;
    esac
    echo "$RES $CMD" > "$OUT"
    chown u0_a264:u0_a264 "$OUT" 2>/dev/null
    log "touch $1 -> $RES"
  fi
  sleep $INTERVAL
done
