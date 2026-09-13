SKIPUNZIP=0
ui_print "- G750 Boost v2.1.2"
ui_print "- Snapdragon GPU floor booster (min_pwrlevel / min_freq / kernel gpu)"
ui_print " "

# ============ 处理器识别（GPU 优先，多判据交叉） ============
# 依据：骁龙 GPU 控制接口由高通 KGSL 驱动提供，跨品牌完全一致
#       （一加/OPPO/真我/小米等骁龙机型节点均为 /sys/class/kgsl/kgsl-3d0/min_pwrlevel）
# 判据顺序：GPU 硬件型号 > ro.soc.model > ro.board.platform
#   —— 厂商 ROM 的 ro.soc.model 命名可能不准（8e5 被写成 SM8750），故 GPU 型号优先
SOC=$(getprop ro.soc.model 2>/dev/null)
BP=$(getprop ro.board.platform 2>/dev/null)
GPU_MODEL=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null)
[ -z "$GPU_MODEL" ] && GPU_MODEL=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/gpu_model 2>/dev/null)
[ -z "$GPU_MODEL" ] && GPU_MODEL=$(cat /sys/kernel/gpu/gpu_model 2>/dev/null)

PNAME=""; SUPPORT=0; DEF=680
# 判据 1: GPU 硬件型号
case "$GPU_MODEL" in
  *750*) PNAME="8 Gen3 (Adreno750)";       SUPPORT=1 ;;
  *830*) PNAME="8 Elite (Adreno830)";      SUPPORT=1 ;;
  *840*) PNAME="8 Elite Gen5 (Adreno840)"; SUPPORT=1 ;;
esac
# 判据 2: ro.soc.model
if [ $SUPPORT -eq 0 ]; then
  case "$SOC" in
    SM8650*) PNAME="8 Gen3 (Adreno750)";       SUPPORT=1 ;;
    SM8750*) PNAME="8 Elite (Adreno830)";      SUPPORT=1 ;;
    SM8850*) PNAME="8 Elite Gen5 (Adreno840)"; SUPPORT=1 ;;
  esac
fi
# 判据 3: board.platform 代号
if [ $SUPPORT -eq 0 ]; then
  case "$BP" in
    pineapple*) PNAME="8 Gen3 (pineapple)";       SUPPORT=1 ;;
    canoe*)     PNAME="8 Elite Gen5 (canoe)";     SUPPORT=1 ;;
    sun*)       PNAME="8 Elite (sun)";            SUPPORT=1 ;;
  esac
fi
[ $SUPPORT -eq 0 ] && PNAME="不支持 ($SOC / $BP / gpu=$GPU_MODEL)"

ui_print "- GPU 型号: ${GPU_MODEL:-未读取到}"
ui_print "- 当前处理器: $PNAME"
if [ $SUPPORT -eq 0 ]; then
  ui_print "! 仅支持 SM8650 / SM8750 / SM8850"
  ui_print "! 当前处理器不在支持范围，拒绝安装"
  abort "! 不支持的处理器平台"
fi
ui_print "- 默认目标档位: ${DEF}MHz（安装后可在 WebUI 修改）"

# ============ GPU 节点探测（按实际处理器对应的路径） ============
# 不同平台节点布局不同，不能固定探测单一路径：
#   8g3 (SM8650) → <kgsl>/{min_pwrlevel,max_pwrlevel,...}
#                  + <kgsl>/devfreq/{min_freq,max_freq,available_frequencies}
#                  + /sys/kernel/gpu/{gpu_min_clock,gpu_max_clock}
#   8e5 (SM8850) → <kgsl>/{min_pwrlevel,max_pwrlevel,min_clock_mhz,...}
#                  + /sys/kernel/gpu/{gpu_min_clock,gpu_max_clock}
#                  （<kgsl>/devfreq 设备存在但无频率节点：gen8 调频由 GMU DCVS 接管，属正常）
# 做法：直接复用运行时引擎 lib/platform.sh（多路径探测 + 平台自适应），
#       保证「安装期判定 == 运行期判定」，避免装机时误报。
if [ -f "$MODPATH/lib/platform.sh" ]; then
  . "$MODPATH/lib/platform.sh"
  gb_platform_detect
  gb_gpu_probe
fi

ui_print "- 节点探测（按实际平台路径；仅提示，不阻断安装）"

# 通道 1：KGSL 主通道（档位号）
if [ -n "$GB_GPU_CLASS" ] && [ -f "$GB_GPU_CLASS/min_pwrlevel" ]; then
  ui_print "    [主通道] $GB_GPU_CLASS/min_pwrlevel"
  HAVE_MAIN=1
else
  ui_print "    [主通道] 未找到 min_pwrlevel"
  HAVE_MAIN=0
fi

# 通道 2：devfreq 软下限（Hz）
if [ -n "$GB_DF" ] && [ -f "$GB_DF/min_freq" ]; then
  ui_print "    [devfreq] $GB_DF/min_freq"
  HAVE_DF=1
else
  HAVE_DF=0
  _dfdev=""
  # 优先取 GPU 核心频率设备（*kgsl-3d0*），再退回任意 kgsl 设备
  for d in /sys/class/devfreq/*kgsl-3d0*; do
    [ -d "$d" ] && _dfdev=$d
  done
  if [ -z "$_dfdev" ]; then
    for d in /sys/class/devfreq/*kgsl*; do
      [ -d "$d" ] && _dfdev=$d
    done
  fi
  if [ -n "$_dfdev" ]; then
    ui_print "    [devfreq] 设备存在（$_dfdev）但无 min_freq 节点"
    ui_print "              gen8 平台调频由 GMU DCVS 接管，无需该节点（正常）"
  else
    ui_print "    [devfreq] 未找到 devfreq 频率节点"
  fi
fi

# 通道 3：/sys/kernel/gpu（MHz）
if [ -n "$GB_GPU_KERNEL" ] && [ -f "$GB_GPU_KERNEL/gpu_min_clock" ]; then
  ui_print "    [kernel]  $GB_GPU_KERNEL/gpu_min_clock"
  HAVE_KERNEL=1
else
  HAVE_KERNEL=0
  ui_print "    [kernel]  未找到 gpu_min_clock"
fi

# 频率表（多路径）
if [ -n "$GB_FREQ_FILE" ] && [ -r "$GB_FREQ_FILE" ]; then
  _nfreq=$(wc -w < "$GB_FREQ_FILE" 2>/dev/null)
  ui_print "    [频率表]  $GB_FREQ_FILE (${_nfreq:-?} 档)"
else
  ui_print "    [频率表]  未找到（运行时将降级为档位号模式）"
fi

# 结论
if [ "$HAVE_MAIN" = "1" ]; then
  ui_print "- 接管通道就绪：主通道 min_pwrlevel 可用，重启后即生效"
elif [ "$HAVE_DF" = "1" ]; then
  ui_print "- 主通道不可用，将自动使用 devfreq min_freq 回退模式"
else
  ui_print "! 安装环境未读到可用的 GPU 频率节点"
  ui_print "! 已继续安装；开机后由运行时引擎按实际路径重新探测"
fi

# ============ 音量键确认 ============
wait_for_volume_key() {
    local timeout=${1:-30} start_time=$(date +%s)
    while true; do
        [ $(($(date +%s) - start_time)) -ge $timeout ] && { echo "3"; return; }
        local event=$(getevent -lqc 1 2>/dev/null | {
            while read -r line; do
                case "$line" in
                    *KEY_VOLUMEDOWN*DOWN*) echo "2" && break ;;
                    *KEY_VOLUMEUP*DOWN*)   echo "1" && break ;;
                esac
            done
        })
        [ -n "$event" ] && { echo "$event"; return; }
        if command -v usleep >/dev/null 2>&1; then usleep 50000; else sleep 0.05; fi
    done
}
ui_print " "
ui_print "! 音量上 = 安装 / 音量下 = 取消 / 15秒超时=安装"
vol=$(wait_for_volume_key 15)
case "$vol" in
  2) ui_print "! 已取消"; abort "! 用户取消" ;;
  *) ui_print "- 确认安装 (vol=$vol)" ;;
esac

# ============ 写平台档案（默认档位） ============
mkdir -p "$MODPATH/config"
printf '%s\n' \
  "# g750-boost settings" \
  "# 游戏地板目标频率 (MHz)，WebUI 可改" \
  "game_floor_mhz=$DEF" \
  "# 游戏上限目标频率 (MHz)，0=不限制（最高档）" \
  "game_ceil_mhz=0" > "$MODPATH/config/settings.conf"

# ============ 权限 ============
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/proc_monitor.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/webdaemon.sh" 0 0 0755
set_perm "$MODPATH/cgi/status.sh" 0 0 0755
set_perm "$MODPATH/cgi/log.sh" 0 0 0755
set_perm "$MODPATH/cgi/config.sh" 0 0 0755

ui_print " "
ui_print "=== 安装完成 ==="
ui_print "· 重启生效；游戏中 GPU 地板升至目标档位"
ui_print "· WebUI: 浏览器 http://127.0.0.1:8778"
ui_print "· 日志: $MODPATH/boost.log"