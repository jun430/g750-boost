#!/system/bin/sh
# g750-boost 频率表与档位映射引擎 v2.1.0
# 依赖: GB_GPU_CLASS / GB_DF / GB_FREQ_FILE 已由 gb_gpu_probe 设置
#
# 两种列表来源（GB_LIST_SRC）:
#   freq  = 读到频率表 → 显示 MHz，index 与 KGSL pwrlevel 一一对应
#   level = 读不到频率表，但有 num_pwrlevels → 显示"档位号"（0=最高）
#   none  = 都不可用

# 加载档位列表
gb_load_freqs() {
  GB_LIST_SRC=none
  GB_LIST_MISMATCH=0
  GB_LEVEL_MAX=-1
  GB_FREQS=""
  GB_TOP_HZ=0
  GB_BOTTOM_HZ=0
  GB_TOP_MHZ=0
  GB_BOTTOM_MHZ=0

  if [ -n "$GB_FREQ_FILE" ] && [ -r "$GB_FREQ_FILE" ]; then
    raw=$(cat "$GB_FREQ_FILE" 2>/dev/null)
    first=$(echo $raw | awk '{print $1}')
    case "$first" in
      ''|*[!0-9]*) raw="" ;;
    esac
    if [ -n "$raw" ]; then
      # 单位归一化：< 100000 视为 MHz，否则视为 Hz
      if [ "$first" -lt 100000 ]; then
        GB_FREQS=$(echo $raw | awk '{for(i=1;i<=NF;i++) printf "%d\n", $i*1000000}')
      else
        GB_FREQS=$(echo $raw | tr ' ' '\n')
      fi
      # 顺序归一化：强制降序，保证 index0 = 最高频 = KGSL pwrlevel 0。
      # 各 SoC 的 available_frequencies 顺序不保证（devfreq 表常见升序），
      # 不归一化会让"显示的档位"与"实际 pwrlevel 下标"整体错位。
      GB_FREQS=$(printf '%s\n' $GB_FREQS | tr -d '\r' | grep -E '^[0-9]+$' | sort -nr | tr '\n' ' ')
      [ -n "$GB_FREQS" ] && GB_LIST_SRC=freq
    fi
  fi

  if [ "$GB_LIST_SRC" = "freq" ] && [ -n "$GB_FREQS" ]; then
    n=0
    for x in $GB_FREQS; do
      [ "$n" -eq 0 ] && GB_TOP_HZ=$x
      GB_BOTTOM_HZ=$x
      n=$((n + 1))
    done
    GB_LEVEL_MAX=$((n - 1))
    GB_TOP_MHZ=$((GB_TOP_HZ / 1000000))
    GB_BOTTOM_MHZ=$((GB_BOTTOM_HZ / 1000000))
    # 与 num_pwrlevels 对齐校验：条目数不一致 → 这张表不是 pwrlevel 表，
    # WebUI 应据此提示"档位可能错位"，而不是静默按下标处理。
    if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/num_pwrlevels" ]; then
      _np=$(cat "$GB_GPU_CLASS/num_pwrlevels" 2>/dev/null)
      case "$_np" in
        ''|*[!0-9]*) ;;
        *) [ "$_np" -ne "$n" ] && GB_LIST_MISMATCH=1 ;;
      esac
    fi
    return 0
  fi

  # 降级：用档位号
  if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/num_pwrlevels" ]; then
    n=$(cat "$GB_GPU_CLASS/num_pwrlevels" 2>/dev/null)
    case "$n" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$n" -ge 1 ]; then
          GB_LIST_SRC=level
          GB_LEVEL_MAX=$((n - 1))
          GB_FREQS=""
          return 0
        fi
        ;;
    esac
  fi

  GB_LIST_SRC=none
  return 1
}

# 映射结果写入 GB_MAP_LEVEL / GB_MAP_MHZ，避免 command substitution fork。
#   freq 模式: floor 目标选 >= 目标的最小档；ceil 目标选 <= 目标的最大档
#   level 模式: 目标直接按档位号处理
GB_MAP_LEVEL=""
GB_MAP_MHZ=""
GB_LEVEL_MHZ=""
GB_TOP_DISPLAY=""

gb_map_floor() {
  target=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    lvl=$target
    case "$lvl" in ''|*[!0-9]*) lvl=$GB_LEVEL_MAX ;; esac
    [ "$lvl" -gt "$GB_LEVEL_MAX" ] && lvl=$GB_LEVEL_MAX
    GB_MAP_LEVEL=$lvl
    GB_MAP_MHZ=$lvl
    return 0
  fi

  best_level=-1
  best_freq=0
  i=0
  for f in $GB_FREQS; do
    fmhz=$((f / 1000000))
    if [ "$fmhz" -ge "$target" ]; then
      if [ "$best_level" -lt 0 ] || [ "$fmhz" -lt "$best_freq" ]; then
        best_level=$i
        best_freq=$fmhz
      fi
    fi
    i=$((i + 1))
  done
  if [ "$best_level" -lt 0 ]; then
    best_level=0
    best_freq=$GB_TOP_MHZ
  fi
  GB_MAP_LEVEL=$best_level
  GB_MAP_MHZ=$best_freq
  return 0
}

gb_map_ceil() {
  target=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    lvl=$target
    case "$lvl" in ''|*[!0-9]*) lvl=0 ;; esac
    [ "$lvl" -gt "$GB_LEVEL_MAX" ] && lvl=$GB_LEVEL_MAX
    GB_MAP_LEVEL=$lvl
    GB_MAP_MHZ=$lvl
    return 0
  fi

  best_level=-1
  best_freq=0
  i=0
  for f in $GB_FREQS; do
    fmhz=$((f / 1000000))
    if [ "$fmhz" -le "$target" ]; then
      if [ "$best_level" -lt 0 ] || [ "$fmhz" -gt "$best_freq" ]; then
        best_level=$i
        best_freq=$fmhz
      fi
    fi
    i=$((i + 1))
  done
  if [ "$best_level" -lt 0 ]; then
    best_level=$GB_LEVEL_MAX
    best_freq=$GB_BOTTOM_MHZ
  fi
  GB_MAP_LEVEL=$best_level
  GB_MAP_MHZ=$best_freq
  return 0
}

# 档位号 -> 显示值（结果写入 GB_LEVEL_MHZ）
gb_level_to_mhz() {
  lvl=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    GB_LEVEL_MHZ=$lvl
    return 0
  fi
  i=0
  for f in $GB_FREQS; do
    if [ "$i" -eq "$lvl" ]; then
      GB_LEVEL_MHZ=$((f / 1000000))
      return 0
    fi
    i=$((i + 1))
  done
  GB_LEVEL_MHZ=0
  return 1
}

# 最高档显示值（结果写入 GB_TOP_DISPLAY）
gb_top_display() {
  if [ "$GB_LIST_SRC" = "level" ]; then
    GB_TOP_DISPLAY=0
  else
    GB_TOP_DISPLAY=$GB_TOP_MHZ
  fi
  return 0
}

# 写 min_pwrlevel（节点不存在直接返回 —— 防止空变量展开成 /min_pwrlevel）
gb_write_pwrlevel() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/min_pwrlevel" ] || return 1
  lvl=$1
  chmod 644 "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
  echo "$lvl" > "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
}

# 读 min_pwrlevel
gb_read_pwrlevel() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  cat "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
}

# 写 max_pwrlevel（节点不存在直接返回）
gb_write_maxlevel() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/max_pwrlevel" ] || return 1
  lvl=$1
  chmod 644 "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
  echo "$lvl" > "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
}

# 读 max_pwrlevel
gb_read_maxlevel() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  cat "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
}

# 回退通道: 写 devfreq/min_freq
#   8e5 无 devfreq 节点（GB_DF 为空）→ 直接返回，避免误写根目录 /min_freq
gb_write_minfreq() {
  [ -n "$GB_DF" ] || return 1
  [ -f "$GB_DF/min_freq" ] || return 1
  freq=$1
  chmod 644 "$GB_DF/min_freq" 2>/dev/null
  echo "$freq" > "$GB_DF/min_freq" 2>/dev/null
}

# 回退通道: 写 devfreq/max_freq
gb_write_maxfreq() {
  [ -n "$GB_DF" ] || return 1
  [ -f "$GB_DF/max_freq" ] || return 1
  freq=$1
  chmod 644 "$GB_DF/max_freq" 2>/dev/null
  echo "$freq" > "$GB_DF/max_freq" 2>/dev/null
}

# ---- KGSL 镜像节点（单位：MHz / Hz；节点存在才写）----
# 不同高通/厂商驱动会暴露其中一部分；8g3 / 8e / 8e5 统一按节点存在性覆盖。
gb_write_minclock_mhz() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/min_clock_mhz" ] || return 1
  chmod 644 "$GB_GPU_CLASS/min_clock_mhz" 2>/dev/null
  echo "$1" > "$GB_GPU_CLASS/min_clock_mhz" 2>/dev/null
}

gb_write_mingpuclk() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/min_gpuclk" ] || return 1
  chmod 644 "$GB_GPU_CLASS/min_gpuclk" 2>/dev/null
  echo "$1" > "$GB_GPU_CLASS/min_gpuclk" 2>/dev/null
}

gb_write_maxclock_mhz() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/max_clock_mhz" ] || return 1
  chmod 644 "$GB_GPU_CLASS/max_clock_mhz" 2>/dev/null
  echo "$1" > "$GB_GPU_CLASS/max_clock_mhz" 2>/dev/null
}

gb_write_maxgpuclk() {
  [ -n "$GB_GPU_CLASS" ] || return 1
  [ -f "$GB_GPU_CLASS/max_gpuclk" ] || return 1
  chmod 644 "$GB_GPU_CLASS/max_gpuclk" 2>/dev/null
  echo "$1" > "$GB_GPU_CLASS/max_gpuclk" 2>/dev/null
}

# ---- /sys/kernel/gpu（MHz；msm_perf / 性能工具常用）----
gb_write_gpumin() {
  [ -n "$GB_GPU_KERNEL" ] || return 1
  [ -f "$GB_GPU_KERNEL/gpu_min_clock" ] || return 1
  chmod 644 "$GB_GPU_KERNEL/gpu_min_clock" 2>/dev/null
  echo "$1" > "$GB_GPU_KERNEL/gpu_min_clock" 2>/dev/null
}

gb_read_gpumin() {
  [ -n "$GB_GPU_KERNEL" ] && cat "$GB_GPU_KERNEL/gpu_min_clock" 2>/dev/null
}

gb_write_gpumax() {
  [ -n "$GB_GPU_KERNEL" ] || return 1
  [ -f "$GB_GPU_KERNEL/gpu_max_clock" ] || return 1
  chmod 644 "$GB_GPU_KERNEL/gpu_max_clock" 2>/dev/null
  echo "$1" > "$GB_GPU_KERNEL/gpu_max_clock" 2>/dev/null
}

gb_read_gpumax() {
  [ -n "$GB_GPU_KERNEL" ] && cat "$GB_GPU_KERNEL/gpu_max_clock" 2>/dev/null
}