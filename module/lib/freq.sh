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
  GB_LEVEL_MAX=-1
  GB_FREQS=""

  if [ -n "$GB_FREQ_FILE" ] && [ -r "$GB_FREQ_FILE" ]; then
    raw=$(cat "$GB_FREQ_FILE" 2>/dev/null)
    first=$(echo $raw | awk '{print $1}')
    case "$first" in
      ''|*[!0-9]*) raw="" ;;
    esac
    if [ -n "$raw" ]; then
      # 单位归一化：< 100000 视为 MHz，否则视为 Hz
      if [ "$first" -lt 100000 ]; then
        GB_FREQS=$(echo $raw | awk '{for(i=1;i<=NF;i++) printf "%d ", $i*1000000}')
      else
        GB_FREQS=$raw
      fi
      GB_LIST_SRC=freq
    fi
  fi

  if [ "$GB_LIST_SRC" = "freq" ] && [ -n "$GB_FREQS" ]; then
    n=0
    for x in $GB_FREQS; do n=$((n + 1)); done
    GB_LEVEL_MAX=$((n - 1))
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

# 目标 -> "level display"
#   freq 模式: target = MHz，选 >= 目标的最小档（保性能）
#   level 模式: target = 档位号，直接使用
gb_map_floor() {
  target=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    lvl=$target
    case "$lvl" in ''|*[!0-9]*) lvl=$GB_LEVEL_MAX ;; esac
    [ "$lvl" -gt "$GB_LEVEL_MAX" ] && lvl=$GB_LEVEL_MAX
    echo "$lvl $lvl"
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
    first=$(echo $GB_FREQS | awk '{print $1}')
    best_level=0
    best_freq=$((first / 1000000))
  fi
  echo "$best_level $best_freq"
  return 0
}

# 上限语义：目标 -> "level display"
#   freq 模式: target = MHz，选 <= 目标的最大档
#   level 模式: target = 档位号
gb_map_ceil() {
  target=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    lvl=$target
    case "$lvl" in ''|*[!0-9]*) lvl=0 ;; esac
    [ "$lvl" -lt 0 ] && lvl=0
    [ "$lvl" -gt "$GB_LEVEL_MAX" ] && lvl=$GB_LEVEL_MAX
    echo "$lvl $lvl"
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
    best_freq=$(gb_level_to_mhz "$best_level")
  fi
  echo "$best_level $best_freq"
  return 0
}

# 档位号 -> 显示值（freq 模式为 MHz；level 模式为档位号）
gb_level_to_mhz() {
  lvl=$1
  if [ "$GB_LIST_SRC" = "level" ]; then
    echo "$lvl"
    return 0
  fi
  i=0
  for f in $GB_FREQS; do
    if [ "$i" -eq "$lvl" ]; then
      echo $((f / 1000000))
      return 0
    fi
    i=$((i + 1))
  done
  echo 0
  return 1
}

# 最高档显示值
gb_top_display() {
  if [ "$GB_LIST_SRC" = "level" ]; then
    echo 0
    return 0
  fi
  first=$(echo $GB_FREQS | awk '{print $1}')
  echo $((first / 1000000))
}

# 写 min_pwrlevel
gb_write_pwrlevel() {
  lvl=$1
  chmod 644 "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
  echo "$lvl" > "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
}

# 读 min_pwrlevel
gb_read_pwrlevel() {
  cat "$GB_GPU_CLASS/min_pwrlevel" 2>/dev/null
}

# 写 max_pwrlevel
gb_write_maxlevel() {
  lvl=$1
  chmod 644 "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
  echo "$lvl" > "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
}

# 读 max_pwrlevel
gb_read_maxlevel() {
  cat "$GB_GPU_CLASS/max_pwrlevel" 2>/dev/null
}

# 回退通道: 写 devfreq/min_freq
gb_write_minfreq() {
  freq=$1
  chmod 644 "$GB_DF/min_freq" 2>/dev/null
  echo "$freq" > "$GB_DF/min_freq" 2>/dev/null
}

# 回退通道: 写 devfreq/max_freq
gb_write_maxfreq() {
  freq=$1
  chmod 644 "$GB_DF/max_freq" 2>/dev/null
  echo "$freq" > "$GB_DF/max_freq" 2>/dev/null
}