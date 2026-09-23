#!/system/bin/sh
# =============================================================
# G750 Boost CGI wall.sh v3.2.0
# 壁纸管理：get / list / set / commit / opacity / clear
# -------------------------------------------------------------
# 安全边界（所有外部输入都视为不可信）：
#  * 路径参数一律以 base64url token 传入（JS: UTF-8 → base64 → url-safe）。
#    token 字符集仅 [A-Za-z0-9_-]，从根上消除空格 / 引号 / 分号 / 换行 /
#    反引号 / $ / 通配符 / 斜杠 的拆参与注入问题；不依赖 %2F / URL decode。
#  * 兼容裸绝对路径（仅 CLI 冒烟测试用），仍必须通过 path_ok 严格白名单。
#  * 落盘目标恒为 $BG/wall.jpg（固定文件名），永不写入 $BG 之外。
#  * 扩展名白名单 jpg/jpeg/png/webp + magic 头校验 + 尺寸非空校验。
#  * 配置独立落在 config/wall.conf，tmp+mv 原子更新，
#    完全不触碰 settings.conf 的 game_floor_mhz / game_ceil_mhz。
#  * 失败一律清理中间文件并保留旧壁纸；响应以 ERR 开头供前端判定。
# 退出码恒为 0：HTTP 与 KSU 两条通道都以响应体判定，不依赖 exit code。
# -------------------------------------------------------------
# v3.2.0 相对 v3.1.0：
#  * do_set / do_commit 统一为「先写 NEW → 校验 → 写配置 → 再 mv 覆盖」，
#    配置落盘失败时旧壁纸不被破坏（fail-safe 顺序）。
#  * do_list 明确输出「原始路径|字节数」，供前端展示后再自行 token 化。
# =============================================================
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
BG=$MODDIR/webroot/bg
CONF=$MODDIR/config/wall.conf
DST=$BG/wall.jpg
NEW=$BG/wall.new.jpg
DEFAULT_OP=35
DEFAULT_GLASS=50
DEFAULT_BLUR=24
EXT_OK=" jpg jpeg png webp "
TOKEN_MAX=8192
SRC_MIN=64

mkdir -p "$BG" >/dev/null 2>&1
mkdir -p "$MODDIR/config" >/dev/null 2>&1

op=$1
arg=$2

die() { printf 'ERR %s\n' "$1"; exit 0; }
ok()  { printf 'OK %s\n' "$1"; exit 0; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ---------- 输入校验 ----------

# 绝对路径严格白名单：
#   1) 必须以 / 开头
#   2) 不得包含 ".."（拒绝一切目录穿越写法，含 "a..jpg" 这类保守拒绝）
#   3) 先剥离 >=0x80 的高字节（POSIX 八进制 tr 转义，busybox/toybox 均支持），
#      再用 LC_ALL=C 精确白名单校验剩余 ASCII：只允许 / A-Za-z0-9 . _ - 空格
#      → 引号 / 反引号 / $ / ; / | / & / < > / * ? [ ] { } ( ) / \ / # / ~ /
#        换行 / 制表 / % 全部被拒绝
#   剥离高字节永远不会"顺带"放过危险 ASCII（危险字符全是 ASCII），因此安全。
path_ok() {
  _p=$1
  [ -n "$_p" ] || return 1
  [ ${#_p} -le $TOKEN_MAX ] || return 1
  case "$_p" in /*) : ;; *) return 1 ;; esac
  case "$_p" in *..*) return 1 ;; esac
  _a=$(printf '%s' "$_p" | LC_ALL=C tr -d '\200-\377')
  case "$_a" in /*) : ;; *) return 1 ;; esac
  printf '%s' "$_a" | LC_ALL=C grep -q '^/[A-Za-z0-9/._ -]*$' || return 1
  return 0
}

ext_ok() {
  _e=$(printf '%s' "$1" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
  case "$EXT_OK" in *" $_e "*) return 0 ;; esac
  return 1
}

file_size() {
  _s=$(wc -c < "$1" 2>/dev/null | tr -d ' \r\n')
  case "$_s" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_s" ;; esac
}

# magic 头校验：JPEG(ffd8ff) / PNG(89504e470d0a1a0a) / WEBP(RIFF....WEBP)
magic_ok() {
  _f=$1
  _sz=$(file_size "$_f")
  [ "$_sz" -ge "$SRC_MIN" ] || return 1
  _h=$(od -An -tx1 -N 12 "$_f" 2>/dev/null | tr -d ' \r\n' | tr 'A-F' 'a-f')
  case "$_h" in
    ffd8ff*)                 return 0 ;;
    89504e470d0a1a0a*)       return 0 ;;
    52494646????????57454250*) return 0 ;;
  esac
  return 1
}

# base64url token → 原始字符串；非法则输出空串
# 返回空串是"拒绝"信号，调用方必须 die，不得回退裸路径。
token_dec() {
  _a=$1
  [ -n "$_a" ] || { printf ''; return 0; }
  [ ${#_a} -le $TOKEN_MAX ] || { printf ''; return 0; }
  case "$_a" in *[!A-Za-z0-9_-]*) printf ''; return 0 ;; esac
  command -v base64 >/dev/null 2>&1 || { printf ''; return 0; }
  _b=$(printf '%s' "$_a" | sed 'y|-_|+/|')
  case $(( ${#_b} % 4 )) in
    2) _b="${_b}==" ;;
    3) _b="${_b}=" ;;
    1) printf ''; return 0 ;;
  esac
  printf '%s' "$_b" | base64 -d 2>/dev/null
}

# 参数解析：token 优先；token 解码为空时才按裸绝对路径处理（CLI 测试通道）
resolve_path() {
  _raw=$1
  [ -n "$_raw" ] || { printf ''; return 0; }
  _d=$(token_dec "$_raw")
  if [ -z "$_d" ]; then
    case "$_raw" in
      /*) _d=$_raw ;;
    esac
  fi
  printf '%s' "$_d"
}

# ---------- 配置读写（独立文件 + 原子写） ----------

conf_get() {
  grep "^$1=" "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

conf_write() {
  _wp=$1
  _src=$2
  _opv=$3
  _gpv=$4
  _bpv=$5
  [ -n "$_gpv" ] || _gpv=$DEFAULT_GLASS
  [ -n "$_bpv" ] || _bpv=$DEFAULT_BLUR
  printf '%s\n' \
    "# g750-boost webui wallpaper config (managed by cgi/wall.sh)" \
    "# 实际生效壁纸文件（相对模块根），固定名" \
    "wall_path=$_wp" \
    "# 用户来源路径（仅展示）" \
    "wall_src=$_src" \
    "# 壁纸透明度 0-100" \
    "wall_opacity=$_opv" \
    "# 液态玻璃透明度 0-100（越高越透明，越低越实）" \
    "wall_glass=$_gpv" \
    "# 玻璃模糊半径 0-40px（0 = 无模糊）" \
    "wall_blur=$_bpv" > "$CONF.tmp" 2>/dev/null || return 1
  mv -f "$CONF.tmp" "$CONF" 2>/dev/null || { rm -f "$CONF.tmp" 2>/dev/null; return 1; }
  chmod 644 "$CONF" 2>/dev/null
  return 0
}

conf_opacity() {
  _v=$(conf_get wall_opacity)
  is_num "$_v" || _v=$DEFAULT_OP
  [ "$_v" -ge 0 ] 2>/dev/null || _v=$DEFAULT_OP
  [ "$_v" -le 100 ] 2>/dev/null || _v=$DEFAULT_OP
  printf '%s' "$_v"
}

conf_glass() {
  _v=$(conf_get wall_glass)
  is_num "$_v" || _v=$DEFAULT_GLASS
  [ "$_v" -ge 0 ] 2>/dev/null || _v=$DEFAULT_GLASS
  [ "$_v" -le 100 ] 2>/dev/null || _v=$DEFAULT_GLASS
  printf '%s' "$_v"
}

conf_blur() {
  _v=$(conf_get wall_blur)
  is_num "$_v" || _v=$DEFAULT_BLUR
  [ "$_v" -ge 0 ] 2>/dev/null || _v=$DEFAULT_BLUR
  [ "$_v" -le 40 ] 2>/dev/null || _v=$DEFAULT_BLUR
  printf '%s' "$_v"
}

conf_src() {
  _v=$(conf_get wall_src)
  [ -n "$_v" ] || _v=""
  printf '%s' "$_v"
}

# ---------- 核心提交：$NEW → $DST（先写配置，再原子替换，保旧壁纸） ----------
# 前置：$NEW 已生成且通过 magic 校验。
commit_new() {
  _src=$1
  [ -f "$NEW" ] || { rm -f "$NEW" 2>/dev/null; return 1; }
  _sz=$(file_size "$NEW")
  magic_ok "$NEW" || { rm -f "$NEW" 2>/dev/null; return 1; }
  # 1) 先写配置（失败则旧壁纸与配置均不受影响）
  conf_write "webroot/bg/wall.jpg" "$_src" "$(conf_opacity)" "$(conf_glass)" "$(conf_blur)" || { rm -f "$NEW" 2>/dev/null; return 1; }
  # 2) 再原子替换图片
  mv -f "$NEW" "$DST" 2>/dev/null || { rm -f "$NEW" 2>/dev/null; return 1; }
  chmod 644 "$DST" 2>/dev/null
  printf '%s' "$_sz"
  return 0
}

# ---------- 从任意已校验图片路径设置 ----------
do_set() {
  _src=$(resolve_path "$arg")
  [ -n "$_src" ] || die "bad-path-token"
  path_ok "$_src" || die "path rejected"
  [ -f "$_src" ] || die "source not a file"
  ext_ok "$_src" || die "ext not allowed (jpg/jpeg/png/webp)"
  _sz=$(file_size "$_src")
  [ "$_sz" -ge "$SRC_MIN" ] || die "source too small or empty"
  [ -r "$_src" ] || die "source not readable"
  rm -f "$NEW" 2>/dev/null
  cat "$_src" > "$NEW" 2>/dev/null || { rm -f "$NEW" 2>/dev/null; die "copy failed"; }
  _cp=$(file_size "$NEW")
  [ "$_cp" = "$_sz" ] || { rm -f "$NEW" 2>/dev/null; die "copy length mismatch"; }
  _got=$(commit_new "$_src") || die "commit failed"
  ok "wall=$_got"
}

# ---------- 提交相册上传产生的 pending 文件（前端分块写入 + base64 -d） ----------
do_commit() {
  [ -f "$NEW" ] || die "no-pending-file"
  _sz=$(file_size "$NEW")
  [ "$_sz" -ge "$SRC_MIN" ] || { rm -f "$NEW" 2>/dev/null; die "pending file too small ($_sz)"; }
  _src=$(conf_src)
  [ -n "$_src" ] || _src="相册上传"
  _got=$(commit_new "$_src") || die "commit failed"
  ok "wall=$_got"
}

do_list() {
  _dir=$(resolve_path "$arg")
  [ -n "$_dir" ] || die "bad-dir-token"
  path_ok "$_dir" || die "dir path rejected"
  [ -d "$_dir" ] || die "not a directory"
  _n=0
  for _f in "$_dir"/*.jpg "$_dir"/*.jpeg "$_dir"/*.JPG "$_dir"/*.JPEG \
            "$_dir"/*.png "$_dir"/*.PNG "$_dir"/*.webp "$_dir"/*.WEBP; do
    [ -f "$_f" ] || continue
    printf '%s|%s\n' "$_f" "$(file_size "$_f")"
    _n=$((_n + 1))
    [ "$_n" -ge 200 ] && break
  done
  [ "$_n" -gt 0 ] || printf 'ERR no image in directory\n'
  exit 0
}

do_get() {
  _present=0
  _fsz=0
  if [ -f "$DST" ]; then
    _fsz=$(wc -c < "$DST" 2>/dev/null | tr -d ' \r\n')
    case "$_fsz" in ''|*[!0-9]*) _fsz=0 ;; esac
    [ "$_fsz" -ge "$SRC_MIN" ] && _present=1
  fi
  _mt=0
  [ -f "$DST" ] && _mt=$(date -r "$DST" +%s 2>/dev/null)
  is_num "$_mt" || _mt=0

  # 性能（v2.2.6）：原实现 6 次 conf_get + 多次 wc，每次都是 grep/tail/cut 多进程管道，
  # 8778 的 nc 单请求模型下实测 0.6~1.0s，成为「打开 WebUI 数秒不出壁纸」的主因。
  # 改为：一次 grep 取全部键值 → 内建 read 循环解析，把进程数从 ~20 降到 ~3。
  _wp=""; _src=""; _op=""; _gl=""; _bl=""
  while IFS='=' read -r _k _v; do
    case "$_k" in
      wall_path)    _wp=$_v ;;
      wall_src)     _src=$_v ;;
      wall_opacity) _op=$_v ;;
      wall_glass)   _gl=$_v ;;
      wall_blur)    _bl=$_v ;;
    esac
  done <<EOF
$(grep -E '^wall_(path|src|opacity|glass|blur)=' "$CONF" 2>/dev/null)
EOF
  is_num "$_op" || _op=$DEFAULT_OP
  [ "$_op" -ge 0 ] 2>/dev/null || _op=$DEFAULT_OP
  [ "$_op" -le 100 ] 2>/dev/null || _op=$DEFAULT_OP
  is_num "$_gl" || _gl=$DEFAULT_GLASS
  [ "$_gl" -ge 0 ] 2>/dev/null || _gl=$DEFAULT_GLASS
  [ "$_gl" -le 100 ] 2>/dev/null || _gl=$DEFAULT_GLASS
  is_num "$_bl" || _bl=$DEFAULT_BLUR
  [ "$_bl" -ge 0 ] 2>/dev/null || _bl=$DEFAULT_BLUR
  [ "$_bl" -le 40 ] 2>/dev/null || _bl=$DEFAULT_BLUR

  printf 'wall_present=%s\n' "$_present"
  printf 'wall_path=%s\n' "$_wp"
  printf 'wall_src=%s\n' "$_src"
  printf 'wall_opacity=%s\n' "$_op"
  printf 'wall_glass=%s\n' "$_gl"
  printf 'wall_blur=%s\n' "$_bl"
  printf 'wall_mtime=%s\n' "$_mt"
  exit 0
}

do_opacity() {
  is_num "$arg" || die "opacity must be integer 0-100"
  [ "$arg" -ge 0 ] && [ "$arg" -le 100 ] || die "opacity out of range"
  conf_write "webroot/bg/wall.jpg" "$(conf_src)" "$arg" "$(conf_glass)" "$(conf_blur)" || die "config write failed"
  ok "opacity=$arg"
}

do_glass() {
  is_num "$arg" || die "glass must be integer 0-100"
  [ "$arg" -ge 0 ] && [ "$arg" -le 100 ] || die "glass out of range"
  conf_write "webroot/bg/wall.jpg" "$(conf_src)" "$(conf_opacity)" "$arg" "$(conf_blur)" || die "config write failed"
  ok "glass=$arg"
}

do_blur() {
  is_num "$arg" || die "blur must be integer 0-40"
  [ "$arg" -ge 0 ] && [ "$arg" -le 40 ] || die "blur out of range"
  conf_write "webroot/bg/wall.jpg" "$(conf_src)" "$(conf_opacity)" "$(conf_glass)" "$arg" || die "config write failed"
  ok "blur=$arg"
}

do_clear() {
  rm -f "$DST" "$NEW" "$BG/.wall.b64" 2>/dev/null
  conf_write "webroot/bg/wall.jpg" "" "$(conf_opacity)" "$(conf_glass)" "$(conf_blur)" || die "config write failed"
  ok "cleared"
}

case "$op" in
  get)      do_get ;;
  list)     do_list ;;
  set)      do_set ;;
  commit)   do_commit ;;
  opacity)  do_opacity ;;
  glass)    do_glass ;;
  blur)     do_blur ;;
  clear)    do_clear ;;
  *)        die "bad-op" ;;
esac