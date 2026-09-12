#!/system/bin/sh
# G750 Boost CGI config v2.0.0
# 用法:
#   无参数       读取配置 + 频率表
#   save <floor> 保存目标档位 (MHz)
# 供 KSU 通道与 webdaemon 通道共用
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=$MODDIR/config/settings.conf
DF=/sys/class/kgsl/kgsl-3d0/devfreq
DEFAULT_FLOOR=680

arg1=$1
arg2=$2

if [ "$arg1" = "save" ]; then
  floor=$arg2
  case "$floor" in
    ''|*[!0-9]*) floor=$DEFAULT_FLOOR ;;
  esac
  if [ "$floor" -lt 100 ] || [ "$floor" -gt 2000 ]; then
    floor=$DEFAULT_FLOOR
  fi

  printf '%s\n' \
    "# g750-boost settings" \
    "# 游戏地板目标频率 (MHz)，WebUI 可改" \
    "game_floor_mhz=$floor" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"

  echo "{\"ok\":true,\"floor\":$floor}"
else
  floor=$(grep '^game_floor_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
  case "$floor" in
    ''|*[!0-9]*) floor=$DEFAULT_FLOOR ;;
  esac
  soc=$(getprop ro.soc.model 2>/dev/null)
  freqs=$(cat $DF/available_frequencies 2>/dev/null)
  json_freqs=$(echo $freqs | awk '{for(i=1;i<=NF;i++){printf "%d", $i/1000000; if(i<NF) printf ","}}')
  echo "{\"floor\":$floor,\"soc\":\"$soc\",\"freqs\":[${json_freqs}]}"
fi