#!/system/bin/sh
# G750 Boost proc_monitor.sh v2.1.2
# - am_proc_start: 白名单主进程启动 -> 校验 PID -> 登记 marker
# - am_proc_died:  白名单主进程退出 -> 记录精确退出时间（迟滞用）
# - 事件只做"加速/记录"；真实存活判定始终由 service.sh 负责
# 作者: 雨色

MODDIR=$1
STATE_DIR=$2
LOG=$3

[ -n "$MODDIR" ] && [ -n "$STATE_DIR" ] && [ -n "$LOG" ] || exit 1
mkdir -p "$STATE_DIR/events"

# ---- 单实例保护：已有存活实例则直接退出（防止重启累积）----
MPIDF="$STATE_DIR/monitor.pid"
if [ -f "$MPIDF" ]; then
  _old=$(cat "$MPIDF" 2>/dev/null)
  case "$_old" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_old" != "$$" ] && [ -d "/proc/$_old" ]; then
        exit 0
      fi
      ;;
  esac
fi
echo $$ > "$MPIDF" 2>/dev/null

# 收到 TERM/INT 立即退出
trap 'exit 0' TERM INT

log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null; }

is_game_pkg() {
  t=$1
  [ -n "$t" ] || return 1
  [ -f "$MODDIR/games.txt" ] || return 1
  while IFS= read -r p || [ -n "$p" ]; do
    case "$p" in
      \#*|"") continue ;;
    esac
    [ "$t" = "$p" ] && return 0
  done < "$MODDIR/games.txt"
  return 1
}

# 进程创建瞬间 cmdline 可能尚未可读，最多重试 1 秒
wait_target_cmdline() {
  pkg=$1
  pid=$2
  retry=0
  while [ $retry -lt 20 ]; do
    [ -d "/proc/$pid" ] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    set -- $cmdline
    cmdline=$1
    if [ "$cmdline" = "$pkg" ]; then
      proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
      case "$proc_state" in
        ""|Z|z) return 1 ;;
        *) return 0 ;;
      esac
    fi
    usleep 50000 2>/dev/null || sleep 0.05
    retry=$((retry + 1))
  done
  return 1
}

handle_start() {
  pkg=$1
  pid=$2
  is_game_pkg "$pkg" || return 0
  wait_target_cmdline "$pkg" "$pid" || return 0
  mkdir -p "$STATE_DIR/events"
  printf '%s\n' "$pkg" > "$STATE_DIR/events/$pid.tmp"
  mv "$STATE_DIR/events/$pid.tmp" "$STATE_DIR/events/$pid"
  log "PROC START $pkg $pid"
}

handle_died() {
  pkg=$1
  pid=$2
  is_game_pkg "$pkg" || return 0
  printf '%s %s\n' "$(date +%s)" "$pkg" > "$STATE_DIR/last_died"
  rm -f "$STATE_DIR/events/$pid"
  log "PROC DIED $pkg $pid"
}

logcat -b events -v brief -s am_proc_start:I -s am_proc_died:I 2>/dev/null | while IFS= read -r line; do
  [ -f "$MODDIR/disable" ] && exit 0
  [ -f "$MODDIR/remove" ] && exit 0

  case "$line" in
    *am_proc_start*)
      # 格式: [user,pid,uid,process,hostingType,...]
      e_pid=$(printf '%s\n' "$line" | sed -n 's/.*\[[^,]*,\([0-9][0-9]*\),[^,]*,\([^,]*\),.*/\1/p')
      e_proc=$(printf '%s\n' "$line" | sed -n 's/.*\[[^,]*,[^,]*,[^,]*,\([^,]*\),.*/\1/p')
      [ -n "$e_pid" ] && [ -n "$e_proc" ] || continue
      handle_start "$e_proc" "$e_pid"
      ;;
    *am_proc_died*)
      # 格式: [user,pid,process,oom_score,proc_state]
      d_pid=$(printf '%s\n' "$line" | sed -n 's/.*\[[^,]*,\([0-9][0-9]*\),\([^,]*\),.*/\1/p')
      d_proc=$(printf '%s\n' "$line" | sed -n 's/.*\[[^,]*,\([0-9][0-9]*\),\([^,]*\),.*/\2/p')
      [ -n "$d_pid" ] && [ -n "$d_proc" ] || continue
      handle_died "$d_proc" "$d_pid"
      ;;
  esac
done