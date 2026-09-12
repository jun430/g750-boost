#!/system/bin/sh
# G750 Boost CGI status v2.0.0 - 只读实时状态
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR=$MODDIR/state
GPU=/sys/class/kgsl/kgsl-3d0
DF=$GPU/devfreq

soc=$(getprop ro.soc.model 2>/dev/null)
platform_name=""
case "$soc" in
  SM8650*) platform_name="8 Gen3 (Adreno750)" ;;
  SM8750*) platform_name="8 Elite (Adreno830)" ;;
  SM8850*) platform_name="8 Elite Gen5 (Adreno840)" ;;
  *) platform_name="unknown" ;;
esac

freqs=$(cat $DF/available_frequencies 2>/dev/null)

min=$(awk '{printf "%d", $1/1000000}' "$DF/min_freq" 2>/dev/null)
cur=$(awk '{printf "%d", $1/1000000}' "$DF/cur_freq" 2>/dev/null)
max=$(awk '{printf "%d", $1/1000000}' "$DF/max_freq" 2>/dev/null)
temp=$(awk '{printf "%d", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)

pwrlevel=$(cat $GPU/min_pwrlevel 2>/dev/null)
num_levels=$(cat $GPU/num_pwrlevels 2>/dev/null)
orig_level=$(cat "$STATE_DIR/orig_level" 2>/dev/null)
floor_level=$(cat "$STATE_DIR/floor_level" 2>/dev/null)
floor_mhz=$(cat "$STATE_DIR/floor_mhz" 2>/dev/null)
game=$(cat "$STATE_DIR/game" 2>/dev/null)
state=$(cat "$STATE_DIR/state" 2>/dev/null)
process=$(cat "$STATE_DIR/game_process" 2>/dev/null)
monitor=$(cat "$STATE_DIR/monitor_pid" 2>/dev/null)

# 当前实际地板：由 min_pwrlevel 档位换算频率
live_floor=$(echo $freqs | awk -v l="$pwrlevel" '{for(i=1;i<=NF;i++) if(i-1==l){printf "%d", $i/1000000}}')

json_escape() { printf '%s' "$1" | sed 's/[\\]/\\\\/g; s/"/\\"/g'; }
process=$(json_escape "$process")

printf '{"soc":"%s","platform":"%s","min":%s,"cur":%s,"max":%s,"pwrlevel":%s,"num_levels":%s,"orig_level":%s,"floor_level":%s,"floor_mhz":%s,"live_floor":%s,"game":"%s","state":"%s","process":"%s","monitor":"%s","temp":%s}' \
  "$soc" "$platform_name" "${min:-0}" "${cur:-0}" "${max:-0}" "${pwrlevel:-0}" "${num_levels:-0}" "${orig_level:-0}" "${floor_level:-0}" "${floor_mhz:-0}" "${live_floor:-0}" "${game:-no}" "${state:-idle}" "$process" "$monitor" "${temp:-0}"