#!/system/bin/sh
# G750 Boost service.sh v2.1.1
# - 游戏地板档位接管（min_pwrlevel 主通道 / min_freq 回退通道）
# - 上限档位（max_pwrlevel）常驻保护，防止其他模块/应用拉低
# - 平台自适配: SM8650 / SM8750 / SM8850（运行时探测，不硬编码）
# - 游戏运行期间每 5s 只读校验，偏离才重写（最小开销）
# - 退出 / 禁用 / 卸载 / 异常退出均恢复系统默认档位
# 作者: 雨色

MODDIR=${0%/*}
LOCK=/dev/.g750boost.lock
LOG=$MODDIR/boost.log
STATE_DIR=$MODDIR/state
CONFIG=$MODDIR/config/settings.conf

DEFAULT_FLOOR=680
DEFAULT_CEIL=0
POLL=5
GAME_POLL=1
HYSTERESIS=8

MONITOR_PID=""
SLEEP_PID=""
STATE=idle
ORIG_LEVEL=""
ORIG_MAXLEVEL=""
LAST_SEEN_GAME=0

. "$MODDIR/lib/platform.sh"
. "$MODDIR/lib/freq.sh"

log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null; }
log_throttled() { # $1=key $2=msg $3=秒(默认30)
  _secs=${3:-30}
  _f="$STATE_DIR/ts_$1"
  _slot=$(( $(date +%s) / _secs ))
  [ "$(cat "$_f" 2>/dev/null)" = "$_slot" ] && return 0
  echo "$_slot" > "$_f" 2>/dev/null
  log "$2"
}

# ---- 配置读取（容错：非法值回退默认；模式感知） ----
default_floor() {
  if [ "$GB_LIST_SRC" = "level" ]; then
    echo "${GB_LEVEL_MAX:-0}"
  else
    echo "$DEFAULT_FLOOR"
  fi
}

cfg_floor() {
  v=$(grep '^game_floor_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
  case "$v" in
    ''|*[!0-9]*) default_floor; return ;;
  esac
  if [ "$GB_LIST_SRC" = "level" ]; then
    if [ "$v" -ge 0 ] && [ "$v" -le "${GB_LEVEL_MAX:-0}" ]; then echo "$v"; else default_floor; fi
  else
    if [ "$v" -ge 100 ] && [ "$v" -le 2000 ]; then echo "$v"; else echo "$DEFAULT_FLOOR"; fi
  fi
}

# 上限目标；0 或非法值 = 不限制（运行时按最高档解析）
cfg_ceil() {
  v=$(grep '^game_ceil_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
  case "$v" in
    ''|*[!0-9]*) echo "$DEFAULT_CEIL" ;;
    *)
      if [ "$GB_LIST_SRC" = "level" ]; then
        if [ "$v" -ge 0 ] && [ "$v" -le "${GB_LEVEL_MAX:-0}" ]; then echo "$v"; else echo "$DEFAULT_CEIL"; fi
      else
        if [ "$v" -eq 0 ]; then echo 0; elif [ "$v" -ge 100 ] && [ "$v" -le 3000 ]; then echo "$v"; else echo "$DEFAULT_CEIL"; fi
      fi
      ;;
  esac
}

# ---- 恢复系统默认档位（幂等，含上限；8g3 / 8e / 8e5 同一逻辑）----
restore_orig() {
  if [ "$GB_GPU_MODE" = "pwrlevel" ] && [ -n "$ORIG_LEVEL" ]; then
    cur=$(gb_read_pwrlevel)
    if [ "$cur" != "$ORIG_LEVEL" ]; then
      gb_write_pwrlevel "$ORIG_LEVEL"
      log "restore pwrlevel $cur -> $ORIG_LEVEL"
    fi
  fi
  if [ -n "$ORIG_MAXLEVEL" ] && [ -f "$GB_GPU_CLASS/max_pwrlevel" ]; then
    cm=$(gb_read_maxlevel)
    if [ "$cm" != "$ORIG_MAXLEVEL" ]; then
      gb_write_maxlevel "$ORIG_MAXLEVEL"
      log "restore max_pwrlevel $cm -> $ORIG_MAXLEVEL"
    fi
  fi
  # 恢复 devfreq 软下限：放到底档，交还内核 QoS / governor
  if [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
    bottom=$(echo "$GB_FREQS" | awk '{print $NF}')
    case "$bottom" in
      ''|*[!0-9]*) ;;
      *) gb_write_minfreq "$bottom" ;;
    esac
  fi
  # 恢复 /sys/kernel/gpu（MHz 通道）
  if [ -n "$GB_GPU_KERNEL" ]; then
    bottom_mhz=$(( $(echo "$GB_FREQS" | awk '{print $NF}') / 1000000 ))
    top_m=$(gb_top_display)
    [ "$bottom_mhz" -gt 0 ] 2>/dev/null && gb_write_gpumin "$bottom_mhz"
    case "$top_m" in
      ''|*[!0-9]*) ;;
      *) [ "$top_m" -gt 0 ] && gb_write_gpumax "$top_m" ;;
    esac
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

# ---- 目标进程校验（cmdline 精确匹配主包名） ----
check_game_pid() {
  pkg=$1
  pid=$2
  [ -n "$pkg" ] && [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  set -- $cmdline
  cmdline=$1
  [ "$cmdline" = "$pkg" ] || return 1
  proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  case "$proc_state" in
    ""|Z|z) return 1 ;;
  esac
  printf '%s %s\n' "$pkg" "$pid" > "$STATE_DIR/game_process"
  return 0
}

check_event_pids() {
  for marker in "$STATE_DIR/events"/*; do
    [ -f "$marker" ] || continue
    pid=${marker##*/}
    pkg=$(cat "$marker" 2>/dev/null)
    if check_game_pid "$pkg" "$pid"; then
      return 0
    fi
    rm -f "$marker"
  done
  return 1
}

check_game_running() {
  check_event_pids && return 0
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
        printf '%s\n' "$pkg" > "$STATE_DIR/events/$pid"
        break
      fi
    done
  done < "$MODDIR/games.txt"
}

# ================= 启动 =================
log "=== g750-boost v2.1.1 start pid=$$ ==="

gb_platform_detect
gb_gpu_probe
log "platform=$GB_PLATFORM ($GB_PLATFORM_NAME) supported=$GB_SUPPORTED gpu_mode=$GB_GPU_MODE"

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

  # 目标档位（配置热加载：WebUI 修改后 5 秒内生效）
  floor_mhz=$(cfg_floor)
  set -- $(gb_map_floor "$floor_mhz")
  out_lvl=$1
  out_mhz=$2
  case "$out_lvl" in
    ''|*[!0-9]*) out_lvl=$ORIG_LEVEL; out_mhz=$(gb_level_to_mhz "$out_lvl") ;;
  esac

  # 上限档位（0/空 = 不限制，取最高档）
  ceil_mhz=$(cfg_ceil)
  top_mhz=$(gb_top_display)
  if [ -z "$ceil_mhz" ] || [ "$ceil_mhz" -le 0 ]; then
    ceil_lvl=0
    ceil_mhz=$top_mhz
  else
    set -- $(gb_map_ceil "$ceil_mhz")
    ceil_lvl=$1
    ceil_mhz=$2
  fi
  case "$ceil_lvl" in
    ''|*[!0-9]*) ceil_lvl=0 ;;
  esac
  # 地板不能高于上限（pwrlevel 数字越小频率越高，故地板档位号须 >= 上限档位号）
  if [ "$out_lvl" -lt "$ceil_lvl" ]; then
    out_lvl=$ceil_lvl
    out_mhz=$(gb_level_to_mhz "$out_lvl")
  fi

  # 状态缓存：每轮更新（空闲时也显示当前配置的目标档位 / 上限）
  echo "$out_lvl" > "$STATE_DIR/floor_level"
  echo "$out_mhz" > "$STATE_DIR/floor_mhz"
  echo "$ceil_lvl" > "$STATE_DIR/ceil_level"
  echo "$ceil_mhz" > "$STATE_DIR/ceil_mhz"

  # 上限保护：每轮写回设定上限，防止其他模块/应用/游戏拉低
  # （8g3 / 8e / 8e5 同一逻辑；节点不存在自动跳过）
  if [ "$GB_GPU_MODE" = "pwrlevel" ]; then
    cur_max=$(gb_read_maxlevel)
    if [ "$cur_max" != "$ceil_lvl" ]; then
      gb_write_maxlevel "$ceil_lvl"
      log_throttled ceil_pwrlevel "ceil protect max_pwrlevel $cur_max -> $ceil_lvl (${ceil_mhz}MHz)"
    fi
    # devfreq/max_freq 护栏（有些游戏直接写 max_freq 拉低上限）
    if [ -n "$GB_DF" ] && [ -f "$GB_DF/max_freq" ]; then
      want_max=$((ceil_mhz * 1000000))
      cur_mf=$(cat "$GB_DF/max_freq" 2>/dev/null)
      if [ -n "$cur_mf" ] && [ "$cur_mf" -lt "$want_max" ]; then
        gb_write_maxfreq "$want_max"
        log_throttled ceil_maxfreq "ceil protect max_freq $cur_mf -> $want_max"
      fi
    fi
    # max_gpuclk 护栏（8g3/8e/8e5 均存在且可写，游戏可能写它拉低上限）
    if [ -f "$GB_GPU_CLASS/max_gpuclk" ]; then
      want_hz=$((ceil_mhz * 1000000))
      cur_gc=$(cat "$GB_GPU_CLASS/max_gpuclk" 2>/dev/null)
      if [ -n "$cur_gc" ] && [ "$cur_gc" -lt "$want_hz" ]; then
        chmod 644 "$GB_GPU_CLASS/max_gpuclk" 2>/dev/null
        echo "$want_hz" > "$GB_GPU_CLASS/max_gpuclk" 2>/dev/null
        log_throttled ceil_maxgpuclk "ceil protect max_gpuclk $cur_gc -> $want_hz"
      fi
    fi
  # /sys/kernel/gpu/gpu_max_clock 护栏（MHz；msm_perf / 性能工具路径）
    if [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/gpu_max_clock" ]; then
      cur_gk=$(gb_read_gpumax)
      case "$cur_gk" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$cur_gk" -lt "$ceil_mhz" ]; then
            gb_write_gpumax "$ceil_mhz"
            log_throttled ceil_gpumax "ceil protect gpu_max_clock $cur_gk -> $ceil_mhz"
          fi
          ;;
      esac
    fi
  else
    gb_write_maxfreq "$((ceil_mhz * 1000000))"
  fi

  now=$(date +%s)
  is_game=0
  game_info=""

  # 开发测试后门: state/force_game 存在时视为游戏运行（正式使用不受影响）
  if [ -f "$STATE_DIR/force_game" ]; then
    is_game=1
    game_info="TEST(force_game)"
  elif check_game_running; then
    is_game=1
    game_info=$(cat "$STATE_DIR/game_process" 2>/dev/null)
  fi

  if [ $is_game -eq 1 ]; then
    echo "yes" > "$STATE_DIR/game"
    echo "$now" > "$STATE_DIR/last_seen"
    LAST_SEEN_GAME=$now

    if [ "$STATE" != "game" ]; then
      # 进入游戏：写入目标地板（pwrlevel 主通道 + devfreq 软下限同步）
      # 8g3 / 8e / 8e5 同一逻辑
      rm -f "$STATE_DIR/last_died"
      if [ "$GB_GPU_MODE" = "pwrlevel" ]; then
        gb_write_pwrlevel "$out_lvl"
        gb_write_minfreq "$((out_mhz * 1000000))"
        gb_write_gpumin "$out_mhz"
        log "GAME RUNNING $game_info -> floor ${out_mhz}MHz (pwrlevel $out_lvl) ceil ${ceil_mhz}MHz"
        # 写后回读自检：被驱动丢弃则告警（8e5 已知现象）
        _pw=$(cat "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null)
        if [ -n "$_pw" ] && [ "$_pw" != "$out_lvl" ]; then
          log "WARN floor write rejected: min_pwrlevel=$_pw want=$out_lvl (driver gated)"
        fi
      else
        gb_write_minfreq "$((out_mhz * 1000000))"
        log "GAME RUNNING $game_info -> min_freq ${out_mhz}MHz (fallback) ceil ${ceil_mhz}MHz"
      fi
      STATE=game
      echo "game" > "$STATE_DIR/state"
    else
      # 运行中：只读校验，偏离才重写（8g3 / 8e / 8e5 同一逻辑）
      if [ "$GB_GPU_MODE" = "pwrlevel" ]; then
        cur_pw=$(gb_read_pwrlevel)
        if [ "$cur_pw" != "$out_lvl" ]; then
          gb_write_pwrlevel "$out_lvl"
          log_throttled floor_drift "floor drift $cur_pw -> $out_lvl (re-applied)"
        fi
        # devfreq/min_freq 同步护栏（内核 QoS 会周期性改写；日志 30s 节流）
        if [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
          want_minf=$((out_mhz * 1000000))
          cur_minf=$(cat "$GB_DF/min_freq" 2>/dev/null)
          if [ -n "$cur_minf" ] && [ "$cur_minf" != "$want_minf" ]; then
            gb_write_minfreq "$want_minf"
            log_throttled floor_minfreq "floor sync min_freq $cur_minf -> $want_minf"
          fi
        fi
        # /sys/kernel/gpu/gpu_min_clock 同步护栏（MHz；msm_perf / 性能工具路径）
        if [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/gpu_min_clock" ]; then
          cur_gk=$(gb_read_gpumin)
          case "$cur_gk" in
            ''|*[!0-9]*) ;;
            *)
              if [ "$cur_gk" != "$out_mhz" ]; then
                gb_write_gpumin "$out_mhz"
                log_throttled floor_gpumin "floor sync gpu_min_clock $cur_gk -> $out_mhz"
              fi
              ;;
          esac
        fi
        old_floor=$(cat "$STATE_DIR/floor_level" 2>/dev/null)
        if [ "$old_floor" != "$out_lvl" ]; then
          log "floor target updated: ${out_mhz}MHz (level $out_lvl)"
        fi
      else
        gb_write_minfreq "$((out_mhz * 1000000))"
      fi
    fi
  else
    echo "no" > "$STATE_DIR/game"
    rm -f "$STATE_DIR/game_process"

    if [ "$STATE" = "game" ]; then
      # 精确迟滞: 优先采用 am_proc_died 事件时间
      last_seen=$(cat "$STATE_DIR/last_seen" 2>/dev/null)
      [ -n "$last_seen" ] || last_seen=$now
      died_info=$(tail -n 1 "$STATE_DIR/last_died" 2>/dev/null)
      died_ts=${died_info%% *}
      case "$died_ts" in
        ''|*[!0-9]*) ;;
        *) [ "$died_ts" -ge "$last_seen" ] && last_seen=$died_ts ;;
      esac

      if [ $((now - last_seen)) -ge $HYSTERESIS ]; then
        restore_orig
        log "GAME EXIT (idle ${HYSTERESIS}s) -> restore pwrlevel $ORIG_LEVEL (+max_pwrlevel, min_freq)"
        STATE=idle
        echo "idle" > "$STATE_DIR/state"
      fi
    fi
  fi

  # 游戏运行中缩短校验周期（1s），空闲用默认周期（5s）
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