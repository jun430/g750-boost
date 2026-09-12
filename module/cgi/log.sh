#!/system/bin/sh
# G750 Boost CGI log — 供 ksu.exec 通道调用
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
tail -n 60 "$MODDIR/boost.log" 2>/dev/null || echo "(no log)"