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

  # GPU 型号：只在平台识别阶段读取一次；路径按实际设备树候选探测。
  # 不假设 8g3/8e/8e5 共用 /sys/class/kgsl/kgsl-3d0 的物理路径。
  gpu=""
  for c in \
    "${GB_GPU_CLASS:-}" \
    /sys/class/kgsl/kgsl-3d0 \
    /sys/class/kgsl/kgsl-* \
    /sys/devices/platform/*/kgsl/kgsl-* \
    /sys/devices/platform/soc/*/kgsl/kgsl-*; do
    [ -n "$c" ] && [ -f "$c/gpu_model" ] || continue
    gpu=$(cat "$c/gpu_model" 2>/dev/null)
    [ -n "$gpu" ] && break
  done
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

# GPU 节点能力探测（实际路径 + 可选缓存）
# pwrlevel = 主通道 (min_pwrlevel 可用)
# freq     = 回退通道 (仅 devfreq/min_freq)
# none     = 不可用
#
# 调用方可设置 GB_GPU_CACHE_FILE：
#   缓存有效时只读取缓存，不扫描 sysfs；
#   缓存路径失效或 GB_FORCE_PROBE=1 时才重新扫描并覆盖缓存。
gb_gpu_probe() {
  GB_GPU_CLASS=""
  GB_DF=""
  GB_FREQ_FILE=""
  GB_GPU_KERNEL=""
  _cache_ok=0

  if [ -n "$GB_GPU_CACHE_FILE" ] && [ -r "$GB_GPU_CACHE_FILE" ] && [ "$GB_FORCE_PROBE" != "1" ]; then
    _cache_class=""
    _cache_df=""
    _cache_freq=""
    _cache_kernel=""
    while IFS='=' read -r _k _v || [ -n "$_k" ]; do
      case "$_k" in
        GB_GPU_CLASS)  _cache_class=$_v ;;
        GB_DF)         _cache_df=$_v ;;
        GB_FREQ_FILE)  _cache_freq=$_v ;;
        GB_GPU_KERNEL) _cache_kernel=$_v ;;
      esac
    done < "$GB_GPU_CACHE_FILE"

    # 至少有一个设备锚点，且缓存中的非空路径仍然存在。
    if { [ -n "$_cache_class" ] && [ -d "$_cache_class" ]; } ||
       { [ -n "$_cache_df" ] && [ -d "$_cache_df" ]; } ||
       { [ -n "$_cache_kernel" ] && [ -d "$_cache_kernel" ]; }; then
      _cache_ok=1
    fi
    [ -n "$_cache_class" ] && [ ! -d "$_cache_class" ] && _cache_ok=0
    [ -n "$_cache_df" ] && [ ! -d "$_cache_df" ] && _cache_ok=0
    [ -n "$_cache_freq" ] && [ ! -r "$_cache_freq" ] && _cache_ok=0
    [ -n "$_cache_kernel" ] && [ ! -d "$_cache_kernel" ] && _cache_ok=0

    if [ "$_cache_ok" = "1" ]; then
      GB_GPU_CLASS=$_cache_class
      GB_DF=$_cache_df
      GB_FREQ_FILE=$_cache_freq
      GB_GPU_KERNEL=$_cache_kernel
    fi
  fi

  if [ "$_cache_ok" != "1" ]; then
    # 先找真实 KGSL 设备目录，不假设 SoC 的 platform 路径。
    for c in \
      /sys/class/kgsl/kgsl-3d0 \
      /sys/class/kgsl/kgsl-* \
      /sys/devices/platform/*/kgsl/kgsl-* \
      /sys/devices/platform/soc/*/kgsl/kgsl-*; do
      [ -d "$c" ] || continue
      if [ -f "$c/min_pwrlevel" ] || [ -f "$c/num_pwrlevels" ]; then
        # 保留 class 稳定别名（/sys/class/...）而非解析为物理路径：
        # 物理路径含 SoC 地址（如 3d00000.qcom,kgsl-3d0），跨平台会变；
        # class 别名由内核维护，8g3 / 8e / 8e5 通用，缓存更稳定。
        GB_GPU_CLASS=$c
        break
      fi
    done

    # 频率表优先取实际 KGSL 设备的节点；再取 GPU 核心 devfreq。
    if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/devfreq/available_frequencies" ]; then
      GB_FREQ_FILE=$GB_GPU_CLASS/devfreq/available_frequencies
    elif [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/gpu_available_frequencies" ]; then
      GB_FREQ_FILE=$GB_GPU_CLASS/gpu_available_frequencies
    elif [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/freq_table_mhz" ]; then
      GB_FREQ_FILE=$GB_GPU_CLASS/freq_table_mhz
    fi

    _core_df=""
    # 名称优先匹配 GPU 核心设备，明确跳过 kgsl-busmon 带宽设备。
    for d in /sys/class/devfreq/*kgsl-3d0* /sys/class/devfreq/*gpu*; do
      [ -d "$d" ] || continue
      case "${d##*/}" in *busmon*|*gpubw*|*bw*) continue ;; esac
      _core_df=$d
      break
    done
    # 某些驱动设备名不含 kgsl-3d0，使用 device 真实链接确认归属。
    if [ -z "$_core_df" ]; then
      for d in /sys/class/devfreq/*; do
        [ -d "$d" ] || continue
        case "${d##*/}" in *busmon*|*gpubw*|*bw*) continue ;; esac
        _dev=$(readlink -f "$d/device" 2>/dev/null)
        case "$_dev" in *kgsl-3d0*|*qcom,kgsl*) _core_df=$d; break ;; esac
      done
    fi

    if [ -z "$GB_FREQ_FILE" ] && [ -n "$_core_df" ] && [ -f "$_core_df/available_frequencies" ]; then
      GB_FREQ_FILE=$_core_df/available_frequencies
    fi

    # devfreq 目录只在真实暴露 min_freq 时启用；8e5 空壳保持为空。
    if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/devfreq/min_freq" ]; then
      GB_DF=$GB_GPU_CLASS/devfreq
    elif [ -n "$_core_df" ] && [ -f "$_core_df/min_freq" ]; then
      GB_DF=$_core_df
    fi

    # 第三套接口仍按实际目录存在性启用。
    [ -d /sys/kernel/gpu ] && GB_GPU_KERNEL=/sys/kernel/gpu

    if [ -n "$GB_GPU_CACHE_FILE" ]; then
      _cache_dir=${GB_GPU_CACHE_FILE%/*}
      [ -d "$_cache_dir" ] || mkdir -p "$_cache_dir"
      _cache_tmp=$GB_GPU_CACHE_FILE.tmp
      {
        printf 'GB_GPU_CLASS=%s\n' "$GB_GPU_CLASS"
        printf 'GB_DF=%s\n' "$GB_DF"
        printf 'GB_FREQ_FILE=%s\n' "$GB_FREQ_FILE"
        printf 'GB_GPU_KERNEL=%s\n' "$GB_GPU_KERNEL"
      } > "$_cache_tmp" 2>/dev/null && mv -f "$_cache_tmp" "$GB_GPU_CACHE_FILE" 2>/dev/null
    fi
  fi

  # 主通道：有 min_pwrlevel 即视为档位模式。
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
