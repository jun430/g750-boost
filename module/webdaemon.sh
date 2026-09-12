#!/system/bin/sh
# G750 Boost webdaemon v2.0.0 - 极简 HTTP（8778 端口）
# v2.0.0: 统一调用 cgi/ 脚本（status/config/log），减少重复实现
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
resp() { printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$1" "${#2}" "$2"; }
case "$path" in
  /|/index.html) body=$(cat "$MODDIR/webroot/index.html" 2>/dev/null); resp "text/html; charset=utf-8" "$body" ;;
  /main.js)      body=$(cat "$MODDIR/webroot/main.js" 2>/dev/null);      resp "application/javascript" "$body" ;;
  /style.css)    body=$(cat "$MODDIR/webroot/style.css" 2>/dev/null);    resp "text/css" "$body" ;;
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
  *) printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n' ;;
esac
HEOF
chmod 755 "$MODDIR/.whandler.sh"

while :; do
  "$BB" nc -l -p 8778 -e "$MODDIR/.whandler.sh" 2>/dev/null
  sleep 0.1
done