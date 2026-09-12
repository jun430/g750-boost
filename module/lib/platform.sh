#!/system/bin/sh
# g750-boost 平台识别引擎
# 用法: . lib/platform.sh 后调用 gb_platform_detect / gb_gpu_probe
# 输出变量: GB_PLATFORM / GB_PLATFORM_NAME / GB_SUPPORTED
#           GB_GPU_CLASS / GB_DF / GB_GPU_MODE

gb_platform_detect() {
  soc=$(getprop ro.soc.model 2>/dev/null)
  bp=$(getprop ro.board.platform 2>/dev/null)

  case "$soc" in
    SM8650*) GB_PLATFORM=sdm8g3; GB_PLATFORM_NAME="8 Gen3 (Adreno750)"; GB_SUPPORTED=1 ;;
    SM8750*) GB_PLATFORM=sdm8e;  GB_PLATFORM_NAME="8 Elite (Adreno830)"; GB_SUPPORTED=1 ;;
    SM8850*) GB_PLATFORM=sdm8e5; GB_PLATFORM_NAME="8 Elite Gen5 (Adreno840)"; GB_SUPPORTED=1 ;;
    *)
      # 备用二判：board.platform 代号
      case "$bp" in
        pineapple*) GB_PLATFORM=sdm8g3; GB_PLATFORM_NAME="8 Gen3 (pineapple)"; GB_SUPPORTED=1 ;;
        sun*)       GB_PLATFORM=sdm8e;  GB_PLATFORM_NAME="8 Elite (sun)"; GB_SUPPORTED=1 ;;
        canoe*)     GB_PLATFORM=sdm8e5; GB_PLATFORM_NAME="8 Elite Gen5 (canoe)"; GB_SUPPORTED=1 ;;
        *)          GB_PLATFORM=unknown; GB_PLATFORM_NAME="未知 ($soc/$bp)"; GB_SUPPORTED=0 ;;
      esac
      ;;
  esac

  export GB_PLATFORM GB_PLATFORM_NAME GB_SUPPORTED
  return 0
}

# GPU 节点能力探测
# pwrlevel = 主通道 (min_pwrlevel 可用)
# freq     = 回退通道 (仅 devfreq/min_freq)
# none     = 不可用
gb_gpu_probe() {
  GB_GPU_CLASS=/sys/class/kgsl/kgsl-3d0
  GB_DF=$GB_GPU_CLASS/devfreq

  if [ -f "$GB_GPU_CLASS/min_pwrlevel" ] && [ -f "$GB_DF/available_frequencies" ]; then
    GB_GPU_MODE=pwrlevel
  elif [ -f "$GB_DF/min_freq" ]; then
    GB_GPU_MODE=freq
  else
    GB_GPU_MODE=none
  fi

  export GB_GPU_CLASS GB_DF GB_GPU_MODE
  return 0
}