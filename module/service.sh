#!/system/bin/sh
# G750 Boost service.sh v2.1.2
# - 游戏地板档位接管（min_pwrlevel 主通道 / min_freq 回退通道）
# - 上限档位（max_pwrlevel）常驻保护，防止其他模块/应用拉低
# - 平台自适配: SM8650 / SM8750 / SM8850（运行时探测，不硬编码）
# - 热路径零 fork 化：节点读写 / 配置读取 / 进程校验全部走 shell 内建；
#   游戏中每轮仅约 1 次 fork（只有 sleep），故 0.3s 轮询的绝对开销仍低于
#   旧版 1s 轮询（旧版每轮 ~30 次 fork）
# - 退出 / 禁用 / 卸载 / 异常退出均恢复系统默认档位
# 作者: 雨色

MODDIR=${0%/*}
LOCK=/dev/.g750boost.lock
LOG=$MODDIR/boost.log
STATE_DIR=$MODDIR/state
CONFIG=$MODDIR/config/settings.conf
GPU_PATH_CACHE=$MODDIR/config/gpu_paths.conf

DEFAULT_FLOOR=680
DEFAULT_CEIL=0
POLL=5
GAME_POLL=0.3     # 游戏中统一 0.3s 轮询（热路径零 fork，开销极低）
HYSTERESIS=8

MONITOR_PID=""
SLEEP_PID=""
STATE=idle
ORIG_LEVEL=""
ORIG_MAXLEVEL=""
LAST_SEEN_GAME=0
GAME_PID=""       # 当前跟踪的游戏主进程 pid（快速路径，免每轮 pidof）
GAME_PKG=""
CHECK_TICK=0
CFG_SIG=""        # 配置签名（floor|ceil）：变化才重算档位映射
STATE_LVL=""      # 已写入 state/ 的档位缓存（避免每轮重复写文件）
STATE_MHZ=""
STATE_CEIL_LVL=""
STATE_CEIL_MHZ=""
GAME_INFO=""
GAME_FILE_STATE=""
LAST_SEEN_FILE=""
NOW_EPOCH=0
OUT_LVL=""        # 当前生效地板档位 / MHz
OUT_MHZ=""
CEIL_LVL=""       # 当前生效上限档位 / MHz
CEIL_MHZ=""
EPOCH_NEXT=0
CFG_NEXT=0
PID_SCAN_NEXT=0
PROBE_NEXT=0      # 路径缓存失效检查节拍（低频；失效才重探测）

. "$MODDIR/lib/platform.sh"
. "$MODDIR/lib/freq.sh"

log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null; }
log_throttled() { # $1=key $2=msg $3=秒(默认30) —— 零 fork（$SECONDS 代替 date）
  _secs=${3:-30}
  _f="$STATE_DIR/ts_$1"
  _slot=$(( SECONDS / _secs ))
  _old=""
  read -r _old < "$_f" 2>/dev/null
  [ "$_old" = "$_slot" ] && return 0
  echo "$_slot" > "$_f" 2>/dev/null
  log "$2"
}

# ---- 零 fork 取值/取配置 ----
# rd <file>：结果放 $RD（内建 read，不 fork；sysfs/procfs 均为单行短文本）
RD=""
rd() {
  RD=""
  read -r RD < "$1" 2>/dev/null
}

# 配置读入（内建 read + 文件重定向，非管道 → 不 fork）
CFG_FLOOR_RAW=""
CFG_CEIL_RAW=""
CFG_POLL_RAW=""
cfg_load() {
  CFG_FLOOR_RAW=""
  CFG_CEIL_RAW=""
  CFG_POLL_RAW=""
  [ -f "$CONFIG" ] || return 0
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case "$_k" in
      game_floor_mhz) CFG_FLOOR_RAW=$_v ;;
      game_ceil_mhz)  CFG_CEIL_RAW=$_v ;;
      game_poll)      CFG_POLL_RAW=$_v ;;
    esac
  done < "$CONFIG"
  return 0
}
# ---- 配置解析（容错：非法值回退默认；模式感知；不创建子进程） ----
# 结果写入 CFG_FLOOR / CFG_CEIL，主循环直接使用，避免每轮 grep|tail|cut。
cfg_resolve() {
  CFG_FLOOR="${GB_LEVEL_MAX:-0}"
  [ "$GB_LIST_SRC" != "level" ] && CFG_FLOOR=$DEFAULT_FLOOR

  v=$CFG_FLOOR_RAW
  case "$v" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$GB_LIST_SRC" = "level" ]; then
        [ "$v" -ge 0 ] && [ "$v" -le "${GB_LEVEL_MAX:-0}" ] && CFG_FLOOR=$v
      else
        [ "$v" -ge 100 ] && [ "$v" -le 2000 ] && CFG_FLOOR=$v
      fi
      ;;
  esac

  CFG_CEIL=$DEFAULT_CEIL
  v=$CFG_CEIL_RAW
  case "$v" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$GB_LIST_SRC" = "level" ]; then
        [ "$v" -ge 0 ] && [ "$v" -le "${GB_LEVEL_MAX:-0}" ] && CFG_CEIL=$v
      else
        if [ "$v" -eq 0 ]; then
          CFG_CEIL=0
        elif [ "$v" -ge 100 ] && [ "$v" -le 3000 ]; then
          CFG_CEIL=$v
        fi
      fi
      ;;
  esac
}


# ---- 恢复系统默认档位（幂等；所有已接管节点统一恢复）----
restore_orig() {
  # KGSL 主档位
  if [ -n "$ORIG_LEVEL" ] && [ -f "$GB_GPU_CLASS/min_pwrlevel" ]; then
    rd "$GB_GPU_CLASS/min_pwrlevel"
    if [ "$RD" != "$ORIG_LEVEL" ]; then
      gb_write_pwrlevel "$ORIG_LEVEL"
      log "restore pwrlevel $RD -> $ORIG_LEVEL"
    fi
  fi
  if [ -n "$ORIG_MAXLEVEL" ] && [ -f "$GB_GPU_CLASS/max_pwrlevel" ]; then
    rd "$GB_GPU_CLASS/max_pwrlevel"
    if [ "$RD" != "$ORIG_MAXLEVEL" ]; then
      gb_write_maxlevel "$ORIG_MAXLEVEL"
      log "restore max_pwrlevel $RD -> $ORIG_MAXLEVEL"
    fi
  fi

  # KGSL MHz / Hz 镜像节点：与主档位一起恢复，防止残留旧版本写入。
  if [ -f "$GB_GPU_CLASS/min_clock_mhz" ]; then
    [ "$GB_BOTTOM_MHZ" -gt 0 ] 2>/dev/null && gb_write_minclock_mhz "$GB_BOTTOM_MHZ"
  fi
  if [ -f "$GB_GPU_CLASS/min_gpuclk" ]; then
    [ "$GB_BOTTOM_HZ" -gt 0 ] 2>/dev/null && gb_write_mingpuclk "$GB_BOTTOM_HZ"
  fi
  if [ -f "$GB_GPU_CLASS/max_clock_mhz" ]; then
    [ "$GB_TOP_MHZ" -gt 0 ] 2>/dev/null && gb_write_maxclock_mhz "$GB_TOP_MHZ"
  fi
  if [ -f "$GB_GPU_CLASS/max_gpuclk" ]; then
    [ "$GB_TOP_HZ" -gt 0 ] 2>/dev/null && gb_write_maxgpuclk "$GB_TOP_HZ"
  fi

  # devfreq 软下限/上限：交还内核 QoS / governor 的完整范围。
  if [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
    [ "$GB_BOTTOM_HZ" -gt 0 ] 2>/dev/null && gb_write_minfreq "$GB_BOTTOM_HZ"
  fi
  if [ -n "$GB_DF" ] && [ -f "$GB_DF/max_freq" ]; then
    [ "$GB_TOP_HZ" -gt 0 ] 2>/dev/null && gb_write_maxfreq "$GB_TOP_HZ"
  fi

  # /sys/kernel/gpu（MHz 通道）
  if [ -n "$GB_GPU_KERNEL" ]; then
    [ "$GB_BOTTOM_MHZ" -gt 0 ] 2>/dev/null && gb_write_gpumin "$GB_BOTTOM_MHZ"
    [ "$GB_TOP_MHZ" -gt 0 ] 2>/dev/null && gb_write_gpumax "$GB_TOP_MHZ"
  fi
}

# 清理 monitor 进程树（主 sh + 管道子 shell + logcat），防止孤儿累积
# 说明: proc_monitor.sh 内部是 `logcat | while read`，管道子 shell 不受 kill 主进程影响
kill_monitor_tree() {
  for p in $(ps -ef 2>/dev/null | grep '[p]roc_monitor.sh' | awk '{print $2}'); do
    kill -9 "$p" 2>/dev/null
  done
  for p in $(ps -ef 2>/dev/null | grep '[l]ogcat -b events' | awk '{print $2}'); do
    kill -9 "$p" 2>/dev/null
  done
  return 0
}

cleanup() {
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  kill_monitor_tree
  restore_orig
  rm -rf "$LOCK" "$STATE_DIR"
  exit 0
}

# ---- 单实例 ----
if ! mkdir "$LOCK" 2>/dev/null; then
  old_pid=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ] && exit 0
  rm -rf "$LOCK"
  mkdir "$LOCK" || exit 1
fi
echo $$ > "$LOCK/pid"
trap cleanup INT TERM EXIT
mkdir -p "$STATE_DIR/events"

# ---- 目标进程校验（cmdline 精确匹配主包名；内建 read，避免热路径 fork） ----
check_game_pid() {
  pkg=$1
  pid=$2
  [ -n "$pkg" ] && [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1

  # /proc/<pid>/cmdline 第一字段以 NUL 结束；read -d '' 是 mksh 内建。
  _cmd=""
  IFS= read -r -d '' _cmd < "/proc/$pid/cmdline" 2>/dev/null
  [ "$_cmd" = "$pkg" ] || return 1

  # /proc/<pid>/stat: 从最后一个 ") " 后取第 3 字段（进程状态）。
  # 用 shell 参数展开解析，避免 awk；最后一个分隔符可避开 comm 中的括号。
  _stat=""
  read -r _stat < "/proc/$pid/stat" 2>/dev/null
  _stat=${_stat##*) }
  _state=${_stat%% *}
  case "$_state" in
    ''|Z|z) return 1 ;;
  esac

  if [ "$GAME_PID" != "$pid" ] || [ "$GAME_PKG" != "$pkg" ]; then
    GAME_PID=$pid
    GAME_PKG=$pkg
    printf '%s %s\n' "$pkg" "$pid" > "$STATE_DIR/game_proc"
  fi
  return 0
}

check_game_running() {
  [ -f "$MODDIR/games.txt" ] || return 1
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in
      \#*|"") continue ;;
    esac
    for pid in $(pidof "$pkg" 2>/dev/null); do
      check_game_pid "$pkg" "$pid" && return 0
    done
  done < "$MODDIR/games.txt"
  return 1
}

discover_existing_games() {
  [ -f "$MODDIR/games.txt" ] || return 0
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    case "$pkg" in
      \#*|"") continue ;;
    esac
    for pid in $(pidof "$pkg" 2>/dev/null); do
      if check_game_pid "$pkg" "$pid"; then
        # 服务启动时游戏已在跑（不会有 start 事件）-> 直接写入事件缓存
        printf '%s %s\n' "$pkg" "$pid" > "$STATE_DIR/game_proc"
        break
      fi
    done
  done < "$MODDIR/games.txt"
}

# 地板守护：每轮调用（0.3s）。节点存在就检查，偏离才写回。
# 单位：pwrlevel=档位号；*_clock_mhz/gpu_min_clock=MHz；*_gpuclk/min_freq=Hz。
guard_floor() {
  if [ -f "$GB_GPU_CLASS/min_pwrlevel" ]; then
    rd "$GB_GPU_CLASS/min_pwrlevel"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$FLOOR_LVL" ]; then
           gb_write_pwrlevel "$FLOOR_LVL"
           log_throttled floor_pwrlevel "floor protect min_pwrlevel $RD -> $FLOOR_LVL"
         fi ;;
    esac
  fi
  if [ -f "$GB_GPU_CLASS/min_clock_mhz" ]; then
    rd "$GB_GPU_CLASS/min_clock_mhz"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$FLOOR_MHZ" ]; then
           gb_write_minclock_mhz "$FLOOR_MHZ"
           log_throttled floor_minclock "floor protect min_clock_mhz $RD -> $FLOOR_MHZ"
         fi ;;
    esac
  fi
  if [ -f "$GB_GPU_CLASS/min_gpuclk" ]; then
    want_hz=$((FLOOR_MHZ * 1000000))
    rd "$GB_GPU_CLASS/min_gpuclk"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$want_hz" ]; then
           gb_write_mingpuclk "$want_hz"
           log_throttled floor_mingpuclk "floor protect min_gpuclk $RD -> $want_hz"
         fi ;;
    esac
  fi
  if [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
    want_hz=$((FLOOR_MHZ * 1000000))
    rd "$GB_DF/min_freq"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$want_hz" ]; then
           gb_write_minfreq "$want_hz"
           log_throttled floor_minfreq "floor protect min_freq $RD -> $want_hz"
         fi ;;
    esac
  fi
  if [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/gpu_min_clock" ]; then
    rd "$GB_GPU_KERNEL/gpu_min_clock"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$FLOOR_MHZ" ]; then
           gb_write_gpumin "$FLOOR_MHZ"
           log_throttled floor_gpumin "floor protect gpu_min_clock $RD -> $FLOOR_MHZ"
         fi ;;
    esac
  fi
}

# 上限守护：每轮调用（0.3s）。节点存在就检查，偏低才写回。
# 不按 GB_GPU_MODE 分支，8e/8e5 与 8g3 统一覆盖实际存在的全部节点。
guard_ceiling() {
  if [ -f "$GB_GPU_CLASS/max_pwrlevel" ]; then
    rd "$GB_GPU_CLASS/max_pwrlevel"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" != "$CEIL_LVL" ]; then
           gb_write_maxlevel "$CEIL_LVL"
           log_throttled ceil_pwrlevel "ceil protect max_pwrlevel $RD -> $CEIL_LVL (${CEIL_MHZ}MHz)"
         fi ;;
    esac
  fi
  if [ -f "$GB_GPU_CLASS/max_clock_mhz" ]; then
    rd "$GB_GPU_CLASS/max_clock_mhz"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" -lt "$CEIL_MHZ" ]; then
           gb_write_maxclock_mhz "$CEIL_MHZ"
           log_throttled ceil_maxclock "ceil protect max_clock_mhz $RD -> $CEIL_MHZ"
         fi ;;
    esac
  fi
  if [ -f "$GB_GPU_CLASS/max_gpuclk" ]; then
    want_hz=$((CEIL_MHZ * 1000000))
    rd "$GB_GPU_CLASS/max_gpuclk"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" -lt "$want_hz" ]; then
           gb_write_maxgpuclk "$want_hz"
           log_throttled ceil_maxgpuclk "ceil protect max_gpuclk $RD -> $want_hz"
         fi ;;
    esac
  fi
  if [ -n "$GB_DF" ] && [ -f "$GB_DF/max_freq" ]; then
    want_hz=$((CEIL_MHZ * 1000000))
    rd "$GB_DF/max_freq"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" -lt "$want_hz" ]; then
           gb_write_maxfreq "$want_hz"
           log_throttled ceil_maxfreq "ceil protect max_freq $RD -> $want_hz"
         fi ;;
    esac
  fi
  if [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/gpu_max_clock" ]; then
    rd "$GB_GPU_KERNEL/gpu_max_clock"
    case "$RD" in
      ''|*[!0-9]*) ;;
      *) if [ "$RD" -lt "$CEIL_MHZ" ]; then
           gb_write_gpumax "$CEIL_MHZ"
           log_throttled ceil_gpumax "ceil protect gpu_max_clock $RD -> $CEIL_MHZ"
         fi ;;
    esac
  fi
  return 0
}

# ================= 启动 =================
log "=== g750-boost v2.1.3 start pid=$$ ==="

GB_GPU_CACHE_FILE=$GPU_PATH_CACHE
gb_gpu_probe
gb_platform_detect
log "platform=$GB_PLATFORM ($GB_PLATFORM_NAME) supported=$GB_SUPPORTED gpu_mode=$GB_GPU_MODE cache=$GPU_PATH_CACHE"

# 节点可用性诊断（8g3 / 8e / 8e5 同一套逻辑，节点不存在自动跳过）
_nodes=""
for _f in min_pwrlevel min_clock_mhz max_pwrlevel max_clock_mhz max_gpuclk min_gpuclk; do
  [ -f "$GB_GPU_CLASS/$_f" ] && _nodes="$_nodes $_f"
done
[ -n "$GB_DF" ] && _nodes="$_nodes devfreq(min_freq,max_freq)"
_k=""
for _f in gpu_min_clock gpu_max_clock; do
  [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/$_f" ] && _k="$_k $_f"
done
log "gpu nodes:${_nodes:- none} | kernel/gpu:${_k:- none}"

if ! gb_load_freqs; then
  log "fatal: no available_frequencies, exit"
  exit 1
fi

# 等 boot 完成
boot_i=0
while [ $boot_i -lt 60 ]; do
  [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
  sleep 2
  boot_i=$((boot_i + 1))
done
sleep 3

# WebUI 服务（自带单实例锁）
nohup sh "$MODDIR/webdaemon.sh" >/dev/null 2>&1 &

# 安全模式：未知平台 或 无可用 GPU 节点
if [ "$GB_SUPPORTED" != "1" ] || [ "$GB_GPU_MODE" = "none" ]; then
  log "idle mode (unsupported platform or no gpu node)"
  echo "unsupported" > "$STATE_DIR/state"
  echo "no" > "$STATE_DIR/game"
  while :; do
    if [ -f "$MODDIR/disable" ]; then log "disabled"; exit 0; fi
    if [ -f "$MODDIR/remove" ]; then log "removed"; exit 0; fi
    sleep 10 &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
  done
fi

# 原始档位 = 系统默认最低档（KGSL 默认 min_pwrlevel = num_pwrlevels-1）
NUM_LEVELS=$(cat "$GB_GPU_CLASS/num_pwrlevels" 2>/dev/null)
case "$NUM_LEVELS" in
  ''|*[!0-9]*) NUM_LEVELS=$(echo $GB_FREQS | wc -w) ;;
esac
ORIG_LEVEL=$((NUM_LEVELS - 1))
echo "$ORIG_LEVEL" > "$STATE_DIR/orig_level"

# 记录原始上限档位（系统默认通常为 0 = 最高）
ORIG_MAXLEVEL=$(gb_read_maxlevel)
case "$ORIG_MAXLEVEL" in
  ''|*[!0-9]*) ORIG_MAXLEVEL=0 ;;
esac
echo "$ORIG_MAXLEVEL" > "$STATE_DIR/orig_maxlevel"

# 清理上次异常退出的残留
if [ "$GB_GPU_MODE" = "pwrlevel" ]; then
  cur_pw=$(gb_read_pwrlevel)
  if [ "$cur_pw" != "$ORIG_LEVEL" ]; then
    log "cleanup stale pwrlevel $cur_pw -> $ORIG_LEVEL"
    gb_write_pwrlevel "$ORIG_LEVEL"
  fi
fi

# 事件监听（start + died 双事件）
if [ -f "$MODDIR/proc_monitor.sh" ]; then
  kill_monitor_tree   # 先清残留实例，避免每次重启累积孤儿进程
  sh "$MODDIR/proc_monitor.sh" "$MODDIR" "$STATE_DIR" "$LOG" &
  MONITOR_PID=$!
  echo "$MONITOR_PID" > "$STATE_DIR/monitor_pid"
  log "proc monitor started pid=$MONITOR_PID"
fi

echo "idle" > "$STATE_DIR/state"
echo "no" > "$STATE_DIR/game"
discover_existing_games
STATE=idle

# ================= 主循环 =================
# 节拍设计（游戏轮询统一 0.3s）：
#   - 地板只读校验 + 进程存活快速路径：每轮执行（0 fork 化）
#   - 配置重算 / 上限护栏 / devfreq 与 kernel 同步：低节拍（2s）
#   - 游戏态由 state/game_proc 事件缓存驱动（每轮读，0 fork）；仅在缓存缺失时低频兜底扫描
#   - 时间用 mksh 内置 $SECONDS（单调秒）做进程内节拍；仅在写 state/last_seen 时取 epoch
# 状态文件只在目标变化时写（避免游戏 0.3s 时每轮 4 次写文件）
NOW=0
FLOOR_LVL=0
FLOOR_MHZ=0
CEIL_LVL=0
CEIL_MHZ=0
GB_CEIL_OK=1

# 预载配置 + 初始档位映射
cfg_load
cfg_resolve
gb_map_floor "$CFG_FLOOR"
FLOOR_LVL=$GB_MAP_LEVEL
FLOOR_MHZ=$GB_MAP_MHZ
gb_top_display
TOP_MHZ=$GB_TOP_DISPLAY
if [ -z "$CFG_CEIL" ] || [ "$CFG_CEIL" -le 0 ]; then
  CEIL_LVL=0
  CEIL_MHZ=$TOP_MHZ
else
  gb_map_ceil "$CFG_CEIL"
  CEIL_LVL=$GB_MAP_LEVEL
  CEIL_MHZ=$GB_MAP_MHZ
fi
if [ "$FLOOR_LVL" -lt "$CEIL_LVL" ]; then
  FLOOR_LVL=$CEIL_LVL
  gb_level_to_mhz "$FLOOR_LVL"
  FLOOR_MHZ=$GB_LEVEL_MHZ
fi
echo "$FLOOR_LVL" > "$STATE_DIR/floor_level"; STATE_LVL=$FLOOR_LVL
echo "$FLOOR_MHZ" > "$STATE_DIR/floor_mhz";  STATE_MHZ=$FLOOR_MHZ
echo "$CEIL_LVL" > "$STATE_DIR/ceil_level";  STATE_CEIL_LVL=$CEIL_LVL
echo "$CEIL_MHZ" > "$STATE_DIR/ceil_mhz";    STATE_CEIL_MHZ=$CEIL_MHZ

while :; do
  if [ -f "$MODDIR/disable" ]; then
    restore_orig
    log "disabled -> restore"
    exit 0
  fi
  if [ -f "$MODDIR/remove" ]; then
    restore_orig
    log "removed -> restore"
    exit 0
  fi

  NOW=$SECONDS

  # ---- 路径缓存失效检测（~2s 节拍；命中缓存时零扫描，失效才重探测）----
  if [ "$NOW" -ge "$PROBE_NEXT" ]; then
    PROBE_NEXT=$((NOW + 2))
    _bad=0
    [ -n "$GB_GPU_CLASS" ] && [ ! -d "$GB_GPU_CLASS" ] && _bad=1
    [ -n "$GB_DF" ] && [ ! -d "$GB_DF" ] && _bad=1
    [ -n "$GB_FREQ_FILE" ] && [ ! -r "$GB_FREQ_FILE" ] && _bad=1
    [ -n "$GB_GPU_KERNEL" ] && [ ! -d "$GB_GPU_KERNEL" ] && _bad=1
    if [ "$_bad" = "1" ]; then
      GB_FORCE_PROBE=1
      gb_gpu_probe
      GB_FORCE_PROBE=""
      log "gpu path re-probe -> class=$GB_GPU_CLASS df=$GB_DF mode=$GB_GPU_MODE"
    fi
  fi

  # ---- 低频段：配置热加载 + 档位重算（~2s 一次；WebUI 改动 2s 内生效）----
  if [ "$NOW" -ge "$CFG_NEXT" ]; then
    CFG_NEXT=$((NOW + 2))
    cfg_load
    cfg_resolve
    gb_map_floor "$CFG_FLOOR"
    FLOOR_LVL=$GB_MAP_LEVEL
    FLOOR_MHZ=$GB_MAP_MHZ
    gb_top_display
    TOP_MHZ=$GB_TOP_DISPLAY
    if [ -z "$CFG_CEIL" ] || [ "$CFG_CEIL" -le 0 ]; then
      CEIL_LVL=0
      CEIL_MHZ=$TOP_MHZ
    else
      gb_map_ceil "$CFG_CEIL"
      CEIL_LVL=$GB_MAP_LEVEL
      CEIL_MHZ=$GB_MAP_MHZ
    fi
    if [ "$FLOOR_LVL" -lt "$CEIL_LVL" ]; then
      FLOOR_LVL=$CEIL_LVL
      gb_level_to_mhz "$FLOOR_LVL"
      FLOOR_MHZ=$GB_LEVEL_MHZ
    fi
    # state 状态文件：只在目标变化时写
    [ "$FLOOR_LVL" = "$STATE_LVL" ] || { echo "$FLOOR_LVL" > "$STATE_DIR/floor_level"; STATE_LVL=$FLOOR_LVL; }
    [ "$FLOOR_MHZ" = "$STATE_MHZ" ] || { echo "$FLOOR_MHZ" > "$STATE_DIR/floor_mhz";  STATE_MHZ=$FLOOR_MHZ; }
    [ "$CEIL_LVL" = "$STATE_CEIL_LVL" ] || { echo "$CEIL_LVL" > "$STATE_DIR/ceil_level";  STATE_CEIL_LVL=$CEIL_LVL; }
    [ "$CEIL_MHZ" = "$STATE_CEIL_MHZ" ] || { echo "$CEIL_MHZ" > "$STATE_DIR/ceil_mhz";    STATE_CEIL_MHZ=$CEIL_MHZ; }
  fi

  # ---- 游戏检测：读事件缓存（proc_monitor 写/删），每轮 0 fork ----
  # 权威来源 = am_proc_start / am_proc_died 事件：
  #   主进程启动 -> proc_monitor 写 state/game_proc("pkg pid")
  #   主进程退出 -> proc_monitor 删 state/game_proc
  # 主循环只读该文件 + 校验 pid 存活，不再轮询 pidof。
  is_game=0
  game_info=""
  if [ -f "$STATE_DIR/force_game" ]; then
    is_game=1
    game_info="TEST(force_game)"
  else
    _gpid=""
    _gpkg=""
    if [ -f "$STATE_DIR/game_proc" ]; then
      rd "$STATE_DIR/game_proc"
      _gpkg=${RD%% *}
      _gpid=${RD##* }
      if [ -n "$_gpid" ] && [ -d "/proc/$_gpid" ]; then
        # 每 10 轮校验一次 cmdline（防 pid 复用，仍 0 fork）
        CHECK_TICK=$((CHECK_TICK + 1))
        if [ $((CHECK_TICK % 10)) -eq 0 ]; then
          _c=""
          IFS= read -r -d '' _c < "/proc/$_gpid/cmdline" 2>/dev/null
          [ "$_c" = "$_gpkg" ] || _gpid=""
        fi
      else
        _gpid=""
      fi
      [ -n "$_gpid" ] || rm -f "$STATE_DIR/game_proc"
    fi
    if [ -n "$_gpid" ]; then
      is_game=1
      GAME_PID=$_gpid
      GAME_PKG=$_gpkg
      game_info="$_gpkg $_gpid"
    else
      GAME_PID=""
      GAME_PKG=""
      # 兜底：monitor 未运行 / 服务重启时游戏已在跑（无 start 事件）-> 低频扫一次
      if [ "$NOW" -ge "$PID_SCAN_NEXT" ]; then
        PID_SCAN_NEXT=$((NOW + 5))
        if check_game_running; then
          is_game=1
          game_info="$GAME_PKG $GAME_PID"
          printf '%s %s\n' "$GAME_PKG" "$GAME_PID" > "$STATE_DIR/game_proc"
        fi
      fi
    fi
  fi

  # ---- 地板写入 / 校验 / 上限护栏 ----
  if [ $is_game -eq 1 ]; then
    if [ "$STATE" != "game" ]; then
      # 进入游戏：统一写入所有存在的下限节点，再统一守护所有上限节点。
      # 不按平台/GB_GPU_MODE 分支；8g3 / 8e / 8e5 都按实际节点执行。
      rm -f "$STATE_DIR/last_died"
      guard_floor
      log "GAME RUNNING $game_info -> floor ${FLOOR_MHZ}MHz (level $FLOOR_LVL) ceil ${CEIL_MHZ}MHz"
      rd "$GB_GPU_CLASS/min_pwrlevel"
      if [ -n "$RD" ] && [ "$RD" != "$FLOOR_LVL" ]; then
        log "WARN floor write rejected: min_pwrlevel=$RD want=$FLOOR_LVL (driver gated)"
      fi
      guard_ceiling

      STATE=game
      [ "$GAME_FILE_STATE" = "yes" ] || { echo "yes" > "$STATE_DIR/game"; GAME_FILE_STATE=yes; }
      echo "game" > "$STATE_DIR/state"
      NOW_EPOCH=$(date +%s); echo "$NOW_EPOCH" > "$STATE_DIR/last_seen"
      LAST_SEEN_GAME=$NOW
    else
      # 游戏运行中：所有下限节点 + 所有上限节点每轮统一检查，偏离才写回。
      guard_floor
      guard_ceiling

      # last_seen 文件（~5s 节拍写，减少 IO）
      if [ "$NOW" -ge "$EPOCH_NEXT" ]; then
        EPOCH_NEXT=$((NOW + 5))
        NOW_EPOCH=$(date +%s); echo "$NOW_EPOCH" > "$STATE_DIR/last_seen"
        LAST_SEEN_GAME=$NOW
      fi
    fi
  else
    [ "$GAME_FILE_STATE" = "no" ] || { echo "no" > "$STATE_DIR/game"; GAME_FILE_STATE=no; }

    if [ "$STATE" = "game" ]; then
      # 精确迟滞：用进程内最后存活时间（$SECONDS 单调秒），0 fork
      if [ $((NOW - LAST_SEEN_GAME)) -ge $HYSTERESIS ]; then
        restore_orig
        log "GAME EXIT (idle ${HYSTERESIS}s) -> restore pwrlevel $ORIG_LEVEL (+max_pwrlevel, min_freq)"
        STATE=idle
        echo "idle" > "$STATE_DIR/state"
      fi
    fi
  fi

  # 轮询节拍：游戏中统一 0.3s（零 fork 热路径，开销极低），空闲 5s
  if [ "$STATE" = "game" ]; then
    sleep_interv=$GAME_POLL
  else
    sleep_interv=$POLL
  fi
  sleep "$sleep_interv" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
done