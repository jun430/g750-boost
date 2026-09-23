#!/system/bin/sh
# G750 Boost webdaemon v3.0.0 - 极简 HTTP（8778 端口）
# v2.0.0: 统一调用 cgi/ 脚本（status/config/log），减少重复实现
# v3.0.0: 新增壁纸路由 /cgi-bin/wall.sh/<op>[/<arg>] 与二进制 /wallpaper.jpg
#         并将 Content-Length 由字符数改为字节数（wc -c），修正中文截断
#   ⚠ 本脚本每次启动都会用 heredoc 重写 .whandler.sh，
#     因此路由改动必须【同时】落在本文件与 .whandler.sh，否则重启即回滚。
MODDIR=/data/adb/modules/g750-boost
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules_update/g750-boost
LOG=$MODDIR/boost.log
LOCK=/dev/.g750boostweb.lock

detect_bb() {
  for p in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v busybox 2>/dev/null || echo ""
}
BB=$(detect_bb)

mkdir "$LOCK" 2>/dev/null || { o=$(cat "$LOCK/pid" 2>/dev/null); [ -n "$o" ] && [ -d /proc/$o ] && exit 0; rm -rf "$LOCK"; mkdir "$LOCK"; }
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"; exit 0' INT TERM EXIT

# handler: 读请求行 → 分发（统一转发到 cgi/ 脚本）
cat > "$MODDIR/.whandler.sh" <<'HEOF'
#!/system/bin/sh
MODDIR=/data/adb/modules/g750-boost
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules_update/g750-boost
reqline=$(head -n 1)
path=$(printf '%s' "$reqline" | awk '{print $2}')
# Content-Length 按【字节】计算（wc -c）：log/list 等含中文时若按字符数会偏小，
# 浏览器按 Content-Length 截断 → JSON/日志被截断。禁止用 ${#body}。
resp() {
  _b="$2"
  _n=$(printf '%s' "$_b" | wc -c 2>/dev/null | tr -d ' \r\n')
  [ -n "$_n" ] || _n=0
  printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' "$1" "$_n" "$_b"
}
case "$path" in
  /|/index.html|/index.html?*|/'?'*) body=$(cat "$MODDIR/webroot/index.html" 2>/dev/null); resp "text/html; charset=utf-8" "$body" ;;
  /main.js|/main.js?*)      body=$(cat "$MODDIR/webroot/main.js" 2>/dev/null);      resp "application/javascript" "$body" ;;
  /style.css|/style.css?*)    body=$(cat "$MODDIR/webroot/style.css" 2>/dev/null);    resp "text/css" "$body" ;;
  /cgi-bin/status.sh)
    body=$(sh "$MODDIR/cgi/status.sh" 2>/dev/null)
    resp "application/json" "$body" ;;
  /cgi-bin/config.sh*)
    q="${path#*\?}"
    [ "$q" = "$path" ] && q=""
    body=$(sh "$MODDIR/cgi/config.sh" $(printf '%s' "$q" | tr '&' ' '))
    resp "application/json" "$body" ;;
  /cgi-bin/log.sh)
    body=$(sh "$MODDIR/cgi/log.sh" 2>/dev/null)
    resp "text/plain; charset=utf-8" "$body" ;;
  /cgi-bin/wall.sh*)
    _pi="${path#/cgi-bin/wall.sh}"
    _pi="${_pi#/}"
    _op="${_pi%%/*}"
    _arg="${_pi#*/}"
    [ "$_arg" = "$_pi" ] && _arg=""
    body=$(sh "$MODDIR/cgi/wall.sh" "$_op" "$_arg" 2>/dev/null)
    resp "text/plain; charset=utf-8" "$body" ;;
  /wallpaper.jpg*)
    _wp="$MODDIR/webroot/bg/wall.jpg"
    if [ -f "$_wp" ]; then
      _sz=$(wc -c < "$_wp" 2>/dev/null | tr -d ' \r\n')
      printf 'HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$_sz"
      cat "$_wp"
    else
      printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
    fi ;;
  *) printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' ;;
esac
HEOF
chmod 755 "$MODDIR/.whandler.sh"

# ---- v2.1.5: service.sh 自愈守护 ----
# service.sh 自身没有看门狗（trap 只做退出清理），被强杀/OOM 后不会自行恢复。
# 这里用独立后台循环每 10s 探活一次：lock_pid 缺失或进程消失 → setsid 拉起。
# 注意：模块被 disable/remove 时绝不拉起，避免无限重启。
(
  _fails=0
  while :; do
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      sleep 10
      continue
    fi
    _svcp=$(cat /dev/.g750boost.lock/pid 2>/dev/null)
    if [ -z "$_svcp" ] || [ ! -d "/proc/$_svcp" ]; then
      _fails=$((_fails + 1))
      echo "$(date '+%m-%d %H:%M:%S') [webdaemon] service.sh dead (lock_pid=${_svcp:-none}) -> respawn #$_fails" >> "$LOG" 2>/dev/null
      setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 < /dev/null &
      # 退避：service.sh 启动即崩时不疯狂重启（前 2 次 15s，之后 60s）
      if [ "$_fails" -ge 3 ]; then sleep 60; else sleep 15; fi
    else
      _fails=0
      sleep 10
    fi
  done
) &

while :; do
  "$BB" nc -lk -p 8778 -e "$MODDIR/.whandler.sh" 2>/dev/null
  sleep 0.1
done