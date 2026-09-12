SKIPUNZIP=0
ui_print "- G750 Boost v2.0.0"
ui_print "- Snapdragon GPU floor booster (min_pwrlevel)"
ui_print " "

# ============ 平台识别（区分安装） ============
SOC=$(getprop ro.soc.model 2>/dev/null)
BP=$(getprop ro.board.platform 2>/dev/null)
case "$SOC" in
  SM8650*) PNAME="8 Gen3 (Adreno750)"; DEF=680; SUPPORT=1 ;;
  SM8750*) PNAME="8 Elite (Adreno830)"; DEF=680; SUPPORT=1 ;;
  SM8850*) PNAME="8 Elite Gen5 (Adreno840)"; DEF=680; SUPPORT=1 ;;
  *)
    case "$BP" in
      pineapple*) PNAME="8 Gen3 (pineapple)"; DEF=680; SUPPORT=1 ;;
      sun*)       PNAME="8 Elite (sun)"; DEF=680; SUPPORT=1 ;;
      canoe*)     PNAME="8 Elite Gen5 (canoe)"; DEF=680; SUPPORT=1 ;;
      *)          PNAME="未知 ($SOC/$BP)"; DEF=680; SUPPORT=0 ;;
    esac
    ;;
esac

ui_print "- 当前平台: $PNAME"
if [ $SUPPORT -eq 0 ]; then
  ui_print "! 未适配平台：安装后进入安全模式（不写入 GPU）"
else
  ui_print "- 默认目标档位: ${DEF}MHz（安装后可在 WebUI 修改）"
fi

# ============ GPU 节点探测 ============
if [ ! -e /sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies ]; then
  ui_print "! 警告: 未检测到 KGSL devfreq 节点，可能与设备不兼容"
  ui_print "! 继续安装（安全模式下不会写入 GPU）"
else
  if [ -e /sys/class/kgsl/kgsl-3d0/min_pwrlevel ]; then
    ui_print "- 主通道 min_pwrlevel: 可用"
  else
    ui_print "- 主通道 min_pwrlevel: 不可用，将自动回退 min_freq 模式"
  fi
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
  "game_floor_mhz=$DEF" > "$MODPATH/config/settings.conf"

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