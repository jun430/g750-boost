#!/system/bin/sh
# G750 Boost CGI status v2.1.0 - 只读实时状态
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR=$MODDIR/state

. "$MODDIR/lib/platform.sh"
gb_platform_detect
gb_gpu_probe

DF=${GB_DF:-/sys/class/kgsl/kgsl-3d0/devfreq}
GPU=${GB_GPU_CLASS:-/sys/class/kgsl/kgsl-3d0}

soc=$(getprop ro.soc.model 2>/dev/null)
platform_name="${GB_PLATFORM_NAME:-unknown}"

freqs=$(cat "$GB_FREQ_FILE" 2>/dev/null)
[ -z "$freqs" ] && freqs=$(cat "$DF/available_frequencies" 2>/dev/null)
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
temp=$(awk '{printf "%d", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)

pwrlevel=$(cat "$GPU/min_pwrlevel" 2>/dev/null)
num_levels=$(cat "$GPU/num_pwrlevels" 2>/dev/null)
orig_level=$(cat "$STATE_DIR/orig_level" 2>/dev/null)
floor_level=$(cat "$STATE_DIR/floor_level" 2>/dev/null)
floor_mhz=$(cat "$STATE_DIR/floor_mhz" 2>/dev/null)
ceil_level=$(cat "$STATE_DIR/ceil_level" 2>/dev/null)
ceil_mhz=$(cat "$STATE_DIR/ceil_mhz" 2>/dev/null)
game=$(cat "$STATE_DIR/game" 2>/dev/null)
state=$(cat "$STATE_DIR/state" 2>/dev/null)
process=$(cat "$STATE_DIR/game_process" 2>/dev/null)
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

printf '{"soc":"%s","platform":"%s","mode":"%s","min":%s,"cur":%s,"max":%s,"pwrlevel":%s,"num_levels":%s,"orig_level":%s,"floor_level":%s,"floor_mhz":%s,"ceil_level":%s,"ceil_mhz":%s,"live_floor":%s,"game":"%s","state":"%s","process":"%s","monitor":"%s","temp":%s}' \
  "$soc" "$platform_name" "${GB_GPU_MODE:-none}" "${min:-0}" "${cur:-0}" "${max:-0}" "${pwrlevel:-0}" "${num_levels:-0}" "${orig_level:-0}" "${floor_level:-0}" "${floor_mhz:-0}" "${ceil_level:-0}" "${ceil_mhz:-0}" "${live_floor:-0}" "${game:-no}" "${state:-idle}" "$process" "$monitor" "${temp:-0}"