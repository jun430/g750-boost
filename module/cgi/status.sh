#!/system/bin/sh
# G750 Boost CGI status v2.1.0 - 只读实时状态
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR=$MODDIR/state

. "$MODDIR/lib/platform.sh"

# 与 service 共用同一份路径缓存：命中则零扫描；失效才回退全量探测。
GB_GPU_CACHE_FILE=$MODDIR/config/gpu_paths.conf
gb_gpu_probe
gb_platform_detect

# 兜底路径跟随实际探测结果，避免硬编码某一代平台的物理路径。
GPU=${GB_GPU_CLASS:-/sys/class/kgsl/kgsl-3d0}
DF=${GB_DF:-$GPU/devfreq}

soc=$(getprop ro.soc.model 2>/dev/null)
platform_name="${GB_PLATFORM_NAME:-unknown}"

freqs=$(cat "$GB_FREQ_FILE" 2>/dev/null)
[ -z "$freqs" ] && freqs=$(cat "$DF/available_frequencies" 2>/dev/null)
# 顺序归一化：与 lib/freq.sh 口径一致，强制降序（index0 = 最高频）。
# 否则"由 min_pwrlevel 反查 MHz"会在某些平台（表为升序）整体错位。
freqs=$(printf '%s\n' $freqs | tr -d '\r' | grep -E '^[0-9]+$' | sort -nr | tr '\n' ' ')
min=$(awk '{printf "%d", $1/1000000}' "$DF/min_freq" 2>/dev/null)
cur=$(awk '{printf "%d", $1/1000000}' "$DF/cur_freq" 2>/dev/null)
max=$(awk '{printf "%d", $1/1000000}' "$DF/max_freq" 2>/dev/null)

# 无 devfreq 平台（如 8e5）回退到 kgsl-3d0 时钟节点
if [ -z "$cur" ]; then
  cur=$(cat "$GPU/clock_mhz" 2>/dev/null)
  [ -z "$cur" ] && cur=$(awk '{printf "%d", $1/1000000}' "$GPU/gpuclk" 2>/dev/null)
fi
if [ -z "$max" ]; then
  _m=$(cat "$GPU/max_gpuclk" 2>/dev/null)
  [ -n "$_m" ] && max=$((_m / 1000000))
  [ -z "$max" ] && max=$(cat "$GPU/max_clock_mhz" 2>/dev/null)
fi
if [ -z "$min" ]; then
  _m=$(cat "$GPU/min_gpuclk" 2>/dev/null)
  [ -n "$_m" ] && min=$((_m / 1000000))
  [ -z "$min" ] && min=$(cat "$GPU/min_clock_mhz" 2>/dev/null)
fi
# GPU 温度：动态探测（不同平台 zone 编号/名称不同，不能硬编码 zone0）
#   - gpuss-* 为 Adreno GPU 传感器；缓存到 config/thermal_zone 避免重复遍历
TZ_CACHE=$MODDIR/config/thermal_zone
TZ=""
if [ -r "$TZ_CACHE" ]; then
  read -r TZ < "$TZ_CACHE" 2>/dev/null
  [ -n "$TZ" ] && [ -f "$TZ/temp" ] || TZ=""
fi
if [ -z "$TZ" ]; then
  # 第一优先：gpuss-0 / gpu-0（精确名称）
  for z in /sys/class/thermal/thermal_zone*; do
    ty=$(cat "$z/type" 2>/dev/null)
    case "$ty" in
      gpuss-0|gpu-0|gpu) TZ=$z; break ;;
    esac
  done
fi
if [ -z "$TZ" ]; then
  # 第二优先：含 gpu / kgsl / adreno / gfx 语义
  for z in /sys/class/thermal/thermal_zone*; do
    ty=$(cat "$z/type" 2>/dev/null)
    case "$ty" in
      *gpu*|*kgsl*|*adreno*|*gfx*) TZ=$z; break ;;
    esac
  done
fi
if [ -z "$TZ" ]; then
  # 兜底：zone0（部分平台 zone0 即真实温度）
  TZ=/sys/class/thermal/thermal_zone0
fi
echo "$TZ" > "$TZ_CACHE" 2>/dev/null
temp=$(awk '{printf "%d", $1/1000}' "$TZ/temp" 2>/dev/null)

# ---- v2.1.5: 配置目标（读 config/settings.conf，不依赖 state）----
# cfg_*  = "你保存的目标"（非游戏态也准确）
# state/*= "当前生效"（service 运行态缓存；仅游戏态刷新）
cfg_floor=$(grep '^game_floor_mhz=' "$MODDIR/config/settings.conf" 2>/dev/null | tail -n 1 | cut -d= -f2)
case "$cfg_floor" in ''|*[!0-9]*) cfg_floor=0 ;; esac
cfg_ceil=$(grep '^game_ceil_mhz=' "$MODDIR/config/settings.conf" 2>/dev/null | tail -n 1 | cut -d= -f2)
case "$cfg_ceil" in ''|*[!0-9]*) cfg_ceil=0 ;; esac

# 档位号反查（freqs 为降序 Hz 表），语义与 lib/freq.sh 的 gb_map_floor/ceil 对齐：
#   floor: 取 >= 目标的最小档（表中最后一个 >= 目标项）
#   ceil : 取 <= 目标的最大档（表中第一个 <= 目标项）；ceil=0 → -1（不限制）
cfg_floor_level=-1
cfg_ceil_level=-1
if [ -n "$freqs" ]; then
  cfg_floor_level=$(echo $freqs | awk -v t="$cfg_floor" '{b=-1; for(i=1;i<=NF;i++) if($i/1000000>=t) b=i-1; print b}')
  [ "$cfg_floor_level" = "-1" ] && cfg_floor_level=0
  if [ "$cfg_ceil" != "0" ]; then
    cfg_ceil_level=$(echo $freqs | awk -v t="$cfg_ceil" '{b=-1; for(i=1;i<=NF;i++) if($i/1000000<=t){b=i-1;break} print b}')
  fi
fi

pwrlevel=$(cat "$GPU/min_pwrlevel" 2>/dev/null)
num_levels=$(cat "$GPU/num_pwrlevels" 2>/dev/null)
orig_level=$(cat "$STATE_DIR/orig_level" 2>/dev/null)
floor_level=$(cat "$STATE_DIR/floor_level" 2>/dev/null)
floor_mhz=$(cat "$STATE_DIR/floor_mhz" 2>/dev/null)
ceil_level=$(cat "$STATE_DIR/ceil_level" 2>/dev/null)
ceil_mhz=$(cat "$STATE_DIR/ceil_mhz" 2>/dev/null)
game=$(cat "$STATE_DIR/game" 2>/dev/null)
state=$(cat "$STATE_DIR/state" 2>/dev/null)
# 事件缓存 game_proc 为权威来源；game_process 为旧版遗留，仅作回退
process=$(cat "$STATE_DIR/game_proc" 2>/dev/null)
[ -z "$process" ] && process=$(cat "$STATE_DIR/game_process" 2>/dev/null)
monitor=$(cat "$STATE_DIR/monitor_pid" 2>/dev/null)

# 当前实际地板：优先由 min_pwrlevel 换算；无 pwrlevel 通道时用 min_freq
live_floor=""
case "$pwrlevel" in
  ''|*[!0-9]*) ;;
  *) live_floor=$(echo $freqs | awk -v l="$pwrlevel" '{for(i=1;i<=NF;i++) if(i-1==l){printf "%d", $i/1000000}}') ;;
esac
[ -z "$live_floor" ] && live_floor=${min:-0}

json_escape() { printf '%s' "$1" | sed 's/[\\]/\\\\/g; s/"/\\"/g'; }
process=$(json_escape "$process")

printf '{"soc":"%s","platform":"%s","mode":"%s","min":%s,"cur":%s,"max":%s,"pwrlevel":%s,"num_levels":%s,"orig_level":%s,"floor_level":%s,"floor_mhz":%s,"ceil_level":%s,"ceil_mhz":%s,"live_floor":%s,"cfg_floor_mhz":%s,"cfg_floor_level":%s,"cfg_ceil_mhz":%s,"cfg_ceil_level":%s,"game":"%s","state":"%s","process":"%s","monitor":"%s","temp":%s}' \
  "$soc" "$platform_name" "${GB_GPU_MODE:-none}" "${min:-0}" "${cur:-0}" "${max:-0}" "${pwrlevel:-0}" "${num_levels:-0}" "${orig_level:-0}" "${floor_level:-0}" "${floor_mhz:-0}" "${ceil_level:-0}" "${ceil_mhz:-0}" "${live_floor:-0}" "${cfg_floor:-0}" "${cfg_floor_level:--1}" "${cfg_ceil:-0}" "${cfg_ceil_level:--1}" "${game:-no}" "${state:-idle}" "$process" "$monitor" "${temp:-0}"