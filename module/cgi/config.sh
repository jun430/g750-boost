#!/system/bin/sh
# G750 Boost CGI config v2.1.0
# 用法:
#   无参数               读取配置 + 档位列表
#   save <floor> [ceil]  保存目标地板 / 上限
#     - freq 模式: 数值为 MHz
#     - level 模式: 数值为档位号
#     - ceil=0 表示不限制（最高档）
# 供 KSU 通道与 webdaemon 通道共用
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=$MODDIR/config/settings.conf
DEFAULT_FLOOR=680
DEFAULT_CEIL=0

. "$MODDIR/lib/platform.sh"
. "$MODDIR/lib/freq.sh"

is_num() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

arg1=$1
arg2=$2
arg3=$3

if [ "$arg1" = "save" ]; then
  floor=$arg2
  ceil=$arg3

  is_num "$floor" || floor=$DEFAULT_FLOOR
  is_num "$ceil" || ceil=$DEFAULT_CEIL

  printf '%s\n' \
    "# g750-boost settings" \
    "# 游戏地板目标值（freq 模式为 MHz；level 模式为档位号），WebUI 可改" \
    "game_floor_mhz=$floor" \
    "# 游戏上限目标值，0=不限制（最高档）" \
    "game_ceil_mhz=$ceil" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"

  echo "{\"ok\":true,\"floor\":$floor,\"ceil\":$ceil}"
else
  floor=$(grep '^game_floor_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
  is_num "$floor" || floor=$DEFAULT_FLOOR

  ceil=$(grep '^game_ceil_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
  is_num "$ceil" || ceil=$DEFAULT_CEIL

  # 与 service 共用路径缓存，避免每次 WebUI 轮询都重扫 sysfs
  GB_GPU_CACHE_FILE=$MODDIR/config/gpu_paths.conf
  gb_gpu_probe
  gb_platform_detect
  gb_load_freqs
  soc=$(getprop ro.soc.model 2>/dev/null)
  pname="${GB_PLATFORM_NAME:-unknown}"

  if [ "$GB_LIST_SRC" = "level" ]; then
    mode=level
    unit="档位"
    lmax=${GB_LEVEL_MAX:-0}
    json_list=$(awk -v m="$lmax" 'BEGIN{for(i=0;i<=m;i++){printf "%d", i; if(i<m) printf ","}}')
  else
    mode=freq
    unit="MHz"
    json_list=$(echo $GB_FREQS | awk '{for(i=1;i<=NF;i++){printf "%d", $i/1000000; if(i<NF) printf ","}}')
    lmax=${GB_LEVEL_MAX:-0}
  fi

  echo "{\"floor\":$floor,\"ceil\":$ceil,\"mode\":\"$mode\",\"unit\":\"$unit\",\"list\":[${json_list}],\"list_max\":$lmax,\"soc\":\"$soc\",\"platform\":\"$pname\"}"
fi