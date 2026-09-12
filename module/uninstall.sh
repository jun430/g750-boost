#!/system/bin/sh
# G750 Boost uninstall — 杀进程 + 还原 GPU 地板 + 清锁
MODDIR=${0%/*}
case "$MODDIR" in
  ''|/|/data) exit 1 ;;
esac

# 杀模块相关进程
for p in $(pidof sh 2>/dev/null) $(pidof busybox 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  case "$c" in
    *g750-boost*|*g750boost*) kill "$p" 2>/dev/null ;;
  esac
done

# 还原 min_pwrlevel 到系统默认最低档
GPU=/sys/class/kgsl/kgsl-3d0
if [ -e $GPU/min_pwrlevel ]; then
  num=$(cat $GPU/num_pwrlevels 2>/dev/null)
  case "$num" in
    ''|*[!0-9]*) num=12 ;;
  esac
  echo $((num - 1)) > $GPU/min_pwrlevel 2>/dev/null
fi

# 还原 min_freq 到最低档频率
if [ -e $GPU/devfreq/min_freq ]; then
  LOW=$(cat $GPU/devfreq/available_frequencies 2>/dev/null | awk '{print $NF}')
  [ -n "$LOW" ] && echo "$LOW" > $GPU/devfreq/min_freq 2>/dev/null
fi

rm -rf /dev/.g750boost.lock /dev/.g750boostweb.lock
rm -rf "$MODDIR/log"
echo "G750 Boost 已卸载, GPU 地板已还原"
exit 0