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

GB_GPU_CACHE_FILE=$MODDIR/config/gpu_paths.conf
gb_gpu_probe
gb_platform_detect
gb_load_freqs
soc=$(getprop ro.soc.model 2>/dev/null)
pname="${GB_PLATFORM_NAME:-unknown}"

if [ "$arg1" = "save" ]; then
  floor=$arg2
  ceil=$arg3

  is_num "$floor" || floor=$DEFAULT_FLOOR
  is_num "$ceil" || ceil=$DEFAULT_CEIL

  floor_req=$floor
  ceil_req=$ceil

  # 吸附：把请求值落到设备真实档位（freq 模式=MHz；level 模式=档位号）。
  # 不吸附的话，写进配置的值可能不在频表里 → 前端 <select> 无 option 命中
  # → 浏览器静默选中第一项（= 最高频），与用户意图完全相反。
  gb_map_floor "$floor"
  floor=$GB_MAP_MHZ
  floor_level=$GB_MAP_LEVEL
  floor_clamped=0

  if [ "$ceil" = "0" ]; then
    ceil=0
    ceil_level=-1
  else
    gb_map_ceil "$ceil"
    ceil=$GB_MAP_MHZ
    ceil_level=$GB_MAP_LEVEL
  fi

  # 一致性保护：窗口必须满足 max_level <= min_level。
  # 若上限档位比地板还高（窗口为空）→ 把地板提到上限档位（等价锁频）。
  if [ "$ceil_level" -ge 0 ] && [ "$floor_level" -lt "$ceil_level" ]; then
    floor=$ceil
    floor_level=$ceil_level
    floor_clamped=1
  fi

  printf '%s\n' \
    "# g750-boost settings" \
    "# 游戏地板目标值（freq 模式为 MHz；level 模式为档位号），WebUI 可改" \
    "game_floor_mhz=$floor" \
    "# 游戏上限目标值，0=不限制（最高档）" \
    "game_ceil_mhz=$ceil" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"

  echo "{\"ok\":true,\"floor\":$floor,\"floor_req\":$floor_req,\"floor_level\":$floor_level,\"floor_clamped\":$floor_clamped,\"ceil\":$ceil,\"ceil_req\":$ceil_req,\"ceil_level\":$ceil_level}"
  exit 0
fi

floor=$(grep '^game_floor_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
is_num "$floor" || floor=$DEFAULT_FLOOR

ceil=$(grep '^game_ceil_mhz=' "$CONFIG" 2>/dev/null | tail -n 1 | cut -d= -f2)
is_num "$ceil" || ceil=$DEFAULT_CEIL

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

  # 配置值的真实落点（吸附后）：前端据此按下标命中 <option>，
  # 并在不命中时提示"配置值不在设备档位"，而不是静默选第一项。
  gb_map_floor "$floor"
  floor_level=$GB_MAP_LEVEL
  floor_eff=$GB_MAP_MHZ
  floor_mismatch=0
  [ "$mode" = "freq" ] && [ "$floor_eff" != "$floor" ] && floor_mismatch=1

  if [ "$ceil" = "0" ]; then
    ceil_level=-1
    ceil_eff=0
    ceil_mismatch=0
  else
    gb_map_ceil "$ceil"
    ceil_level=$GB_MAP_LEVEL
    ceil_eff=$GB_MAP_MHZ
    ceil_mismatch=0
    [ "$mode" = "freq" ] && [ "$ceil_eff" != "$ceil" ] && ceil_mismatch=1
  fi

  echo "{\"floor\":$floor,\"ceil\":$ceil,\"mode\":\"$mode\",\"unit\":\"$unit\",\"list\":[${json_list}],\"list_max\":$lmax,\"floor_level\":$floor_level,\"floor_eff\":$floor_eff,\"floor_mismatch\":$floor_mismatch,\"ceil_level\":$ceil_level,\"ceil_eff\":$ceil_eff,\"ceil_mismatch\":$ceil_mismatch,\"list_mismatch\":${GB_LIST_MISMATCH:-0},\"soc\":\"$soc\",\"platform\":\"$pname\"}"