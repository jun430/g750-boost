#!/system/bin/sh
# g750-boost 平台识别引擎 v2.1.0
# 用法: . lib/platform.sh 后调用 gb_platform_detect / gb_gpu_probe
#
# 识别优先级（从高到低）:
#   1) GPU 硬件型号 /sys/class/kgsl/kgsl-3d0/gpu_model  ← 物理事实，最可靠
#      厂商 ROM 的 ro.soc.model 命名可能不准确（8e5 被写成 SM8750），必须绕过
#   2) ro.soc.model
#   3) ro.board.platform 代号
#
# 输出变量: GB_PLATFORM / GB_PLATFORM_NAME / GB_SUPPORTED
#           GB_DETECT_SRC (判据来源) / GB_GPU_MODEL / GB_DF / GB_GPU_MODE
gb_platform_detect() {
  GB_PLATFORM=unknown GB_PLATFORM_NAME="未知"
  GB_SUPPORTED=0 GB_DETECT_SRC=none

  local soc bp gpu
  soc=$(getprop ro.soc.model 2>/dev/null)
  bp=$(getprop ro.board.platform 2>/dev/null)

  # GPU 型号：多路径探测（不同平台/驱动版本节点位置可能不同）
  gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null)
  [ -z "$gpu" ] && gpu=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/gpu_model 2>/dev/null)
  [ -z "$gpu" ] && gpu=$(cat /sys/kernel/gpu/gpu_model 2>/dev/null)
  GB_GPU_MODEL=$gpu

  # --- 判据 1: GPU 硬件型号（最可靠，不受厂商属性命名污染）---
  case "$gpu" in
    *750*) GB_PLATFORM=sdm8g3; GB_PLATFORM_NAME="8 Gen3 (Adreno750)";       GB_SUPPORTED=1; GB_DETECT_SRC=gpu ;;
    *830*) GB_PLATFORM=sdm8e;  GB_PLATFORM_NAME="8 Elite (Adreno830)";      GB_SUPPORTED=1; GB_DETECT_SRC=gpu ;;
    *840*) GB_PLATFORM=sdm8e5; GB_PLATFORM_NAME="8 Elite Gen5 (Adreno840)"; GB_SUPPORTED=1; GB_DETECT_SRC=gpu ;;
  esac

  # --- 判据 2: ro.soc.model ---
  if [ "$GB_SUPPORTED" = "0" ]; then
    case "$soc" in
      SM8650*) GB_PLATFORM=sdm8g3; GB_PLATFORM_NAME="8 Gen3 (Adreno750)";       GB_SUPPORTED=1; GB_DETECT_SRC=soc ;;
      SM8750*) GB_PLATFORM=sdm8e;  GB_PLATFORM_NAME="8 Elite (Adreno830)";      GB_SUPPORTED=1; GB_DETECT_SRC=soc ;;
      SM8850*) GB_PLATFORM=sdm8e5; GB_PLATFORM_NAME="8 Elite Gen5 (Adreno840)"; GB_SUPPORTED=1; GB_DETECT_SRC=soc ;;
    esac
  fi

  # --- 判据 3: board.platform 代号（兜底，最不可靠）---
  if [ "$GB_SUPPORTED" = "0" ]; then
    case "$bp" in
      pineapple*) GB_PLATFORM=sdm8g3; GB_PLATFORM_NAME="8 Gen3 (pineapple)";       GB_SUPPORTED=1; GB_DETECT_SRC=bp ;;
      canoe*)     GB_PLATFORM=sdm8e5; GB_PLATFORM_NAME="8 Elite Gen5 (canoe)";     GB_SUPPORTED=1; GB_DETECT_SRC=bp ;;
      sun*)       GB_PLATFORM=sdm8e;  GB_PLATFORM_NAME="8 Elite (sun)";            GB_SUPPORTED=1; GB_DETECT_SRC=bp ;;
    esac
  fi

  [ "$GB_SUPPORTED" = "0" ] && GB_PLATFORM_NAME="不支持的平台 (soc=$soc bp=$bp gpu=$gpu)"

  export GB_PLATFORM GB_PLATFORM_NAME GB_SUPPORTED GB_DETECT_SRC GB_GPU_MODEL
  return 0
}

# GPU 节点能力探测（支持多路径）
# pwrlevel = 主通道 (min_pwrlevel 可用)
# freq     = 回退通道 (仅 devfreq/min_freq)
# none     = 不可用
gb_gpu_probe() {
  GB_GPU_CLASS=""
  for c in /sys/class/kgsl/kgsl-3d0 /sys/devices/platform/kgsl-3d0.0/kgsl/kgsl-3d0; do
    [ -d "$c" ] && { GB_GPU_CLASS=$c; break; }
  done
  [ -d "$GB_GPU_CLASS" ] || GB_GPU_CLASS=""

  # 频率表文件（多路径，覆盖 8g3 / 8e / 8e5）：
  #   8g3(SM8650) → <kgsl-3d0>/devfreq/available_frequencies
  #   8e5(SM8850) → <kgsl-3d0>/gpu_available_frequencies
  #   兜底       → <kgsl-3d0>/freq_table_mhz 或 /sys/class/devfreq/*kgsl*/available_frequencies
  GB_FREQ_FILE=""
  if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/devfreq/available_frequencies" ]; then
    GB_FREQ_FILE=$GB_GPU_CLASS/devfreq/available_frequencies
  elif [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/gpu_available_frequencies" ]; then
    GB_FREQ_FILE=$GB_GPU_CLASS/gpu_available_frequencies
  elif [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/freq_table_mhz" ]; then
    GB_FREQ_FILE=$GB_GPU_CLASS/freq_table_mhz
  else
    for d in /sys/class/devfreq/*kgsl*; do
      [ -f "$d/available_frequencies" ] && { GB_FREQ_FILE=$d/available_frequencies; break; }
    done
  fi

  # devfreq 目录（仅回退通道 min_freq/max_freq 需要；8e5 没有）
  GB_DF=""
  if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/devfreq/min_freq" ]; then
    GB_DF=$GB_GPU_CLASS/devfreq
  else
    for d in /sys/class/devfreq/*kgsl*; do
      [ -f "$d/min_freq" ] && { GB_DF=$d; break; }
    done
  fi

  # 第三套接口: /sys/kernel/gpu（msm_perf / 性能工具常用的 MHz 单位节点）
  #   8g3 / 8e / 8e5 均存在；含 gpu_min_clock / gpu_max_clock（可写，MHz）
  GB_GPU_KERNEL=""
  [ -d /sys/kernel/gpu ] && GB_GPU_KERNEL=/sys/kernel/gpu

  # 主通道：有 min_pwrlevel 即视为档位模式（pwrlevel）
  #   能读到频率表 → 用 MHz 显示；读不到但有 num_pwrlevels → 降级为"档位号"显示
  GB_GPU_MODE=none
  if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/min_pwrlevel" ]; then
    if [ -n "$GB_FREQ_FILE" ] || [ -f "$GB_GPU_CLASS/num_pwrlevels" ]; then
      GB_GPU_MODE=pwrlevel
    fi
  fi
  if [ "$GB_GPU_MODE" = "none" ] && [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
    GB_GPU_MODE=freq
  fi

  export GB_GPU_CLASS GB_DF GB_GPU_MODE GB_FREQ_FILE GB_GPU_KERNEL
  return 0
}
