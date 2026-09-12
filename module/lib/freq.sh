#!/system/bin/sh
# g750-boost 频率表与档位映射引擎
# 依赖: GB_DF / GB_GPU_CLASS 已由 gb_gpu_probe 设置
# 说明: available_frequencies 为倒序表（index0 = 最高频），
#       档位号 index 与 KGSL 的 pwrlevel 一一对应。

# 读取频率表（Hz，空格分隔）
gb_load_freqs() {
  GB_FREQS=$(cat "$GB_DF/available_frequencies" 2>/dev/null)
  [ -n "$GB_FREQS" ]
}

# 目标MHz -> "level freq_mhz"
# 规则: 选 >= 目标的最小档位; 若目标高于最高档, 用最高档
gb_map_floor() {
  target=$1
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

# 档位号 -> MHz
gb_level_to_mhz() {
  lvl=$1
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

# 回退通道: 写 devfreq/min_freq
gb_write_minfreq() {
  freq=$1
  chmod 644 "$GB_DF/min_freq" 2>/dev/null
  echo "$freq" > "$GB_DF/min_freq" 2>/dev/null
}