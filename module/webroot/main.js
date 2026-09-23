/* G750 Boost WebUI main.js v2.2.0 (v3.1)
   主通道：KSU 内嵌（ksu.exec）；降级通道：浏览器 127.0.0.1:8778
   v2.2.0 新增：主题三态 / 壁纸（相册 · 目录 · 手输）/ 透明度持久化 / 液态玻璃底栏
   硬约束：原 KSU 通道逻辑（HAS_KSU / ksuExecAsync / detectPath / __MODPATH__ / 8778 正则）语义不变

   v3.1 修正（相对 build 版）：
     1) 分块写入：任一块失败立即清理并终止（原实现 continue 跳过会拼出缺块损坏图）
     2) 外部路径统一 base64url token 化，杜绝 shell 注入（原实现直接拼接）
     3) 壁纸预览改用稳定路由 /wallpaper.jpg?v=mtime（原 /cgi-bin/wall.sh/raw 不存在）
     4) 壁纸存在性以 wall_present 为准；wall.sh 子命令 set-file → commit 与后端统一
*/
"use strict";
const MOD_CANDIDATES = ["/data/adb/modules/g750-boost", "/data/adb/modules_update/g750-boost"];
const CGI_BASE = "http://127.0.0.1:8778";
const HAS_KSU = (typeof ksu !== "undefined" && ksu && ksu.exec);
let MODPATH = null;
let cbCount = 0;

/* ⚠ KernelSU 的 ksu.exec 并发调用存在竞态（回调串台 / 输出交叉），
   而本版里 detectPath / 主流程 / 诊断【都】走这里。若不串行，
   诊断本身就会成为新的失败源 —— 这是必须修的硬缺陷（v2.2.2 修复）。 */
let execChain = Promise.resolve();
function ksuExecAsync(cmd) {
  const run = () => new Promise((resolve) => {
    const cb = `gb_cb_${Date.now()}_${cbCount++}`;
    let fin = false;
    const done = (o) => { if (fin) return; fin = true; try { delete window[cb]; } catch (e) {} resolve(o); };
    window[cb] = (errno, stdout, stderr) => done({ errno, stdout, stderr });
    try { ksu.exec(cmd, "{}", cb); }
    catch (e) { done({ errno: 1, stdout: "", stderr: String(e) }); }
  });
  const p = execChain.then(run, run);
  execChain = p.then(() => {}, () => {});
  return p;
}
async function detectPath() {
  if (MODPATH) return MODPATH;
  for (const p of MOD_CANDIDATES) {
    const r = await ksuExecAsync(`[ -f ${p}/games.txt ] && echo OK`);
    if (r.errno === 0 && r.stdout.includes("OK")) { MODPATH = p; return p; }
  }
  MODPATH = MOD_CANDIDATES[0];
  return MODPATH;
}
async function sh(cmd) {
  if (HAS_KSU) {
    await detectPath();
    return ksuExecAsync(cmd.replace(/__MODPATH__/g, MODPATH));
  }
  // 浏览器降级通道：必须先做同样的路径替换。
  // 否则 __MODPATH__ 原样残留 → 下面的正则匹配失败 → 所有调用
  // （包括 config.sh 的读/存）都会被静默降级成 status.sh，
  // 表现为"下拉框没有档位 / 保存了但没生效"。
  const flat = cmd.replace(/__MODPATH__/g, MOD_CANDIDATES[0]);
  const rel = flat.replace(/^sh\s+\/data\/adb\/modules[_update]*\/g750-boost\//, "");
  const m = rel.match(/^cgi\/([\w.]+\.sh)\s*(.*)$/);
  const script = m ? m[1] : "status.sh";
  // v3.1：wall.sh 走 path-info 传参（/cgi-bin/wall.sh/<op>[/<token>]）。
  // 8778 端只做 `tr '&' ' '`、无 URL 解码，且 path 中不能出现空格；
  // 因此把参数间的空白统一换成 "/"，路径参数此时已是 base64url token
  // （字符集 [A-Za-z0-9_-]），整条 URL 不含任何需转义字符。
  if (script === "wall.sh") {
    let rest = m && m[2] ? m[2].trim() : "";
    rest = rest.replace(/\s+/g, "/").replace(/^\/+/, "").replace(/\/+$/, "");
    const url = CGI_BASE + "/cgi-bin/wall.sh" + (rest ? "/" + rest : "");
    return httpGet(url);
  }
  const args = m && m[2].trim() ? "?" + m[2].trim().split(/\s+/).map(a => encodeURIComponent(a)).join("&") : "";
  const url = CGI_BASE + "/cgi-bin/" + script + args;
  return httpGet(url);
}
async function httpGet(url) {
  let lastErr = null;
  for (let i = 0; i < 5; i++) {
    try {
      const resp = await fetch(url, { cache: "no-store" });
      const text = await resp.text();
      if (text && text.trim()) return { errno: 0, stdout: text, stderr: "" };
      lastErr = new Error("empty");
    } catch (e) { lastErr = e; }
    await new Promise(r => setTimeout(r, 300 * (i + 1)));
  }
  return { errno: 1, stdout: "", stderr: String(lastErr) };
}
const $ = s => document.querySelector(s);
function toast(m) { if (HAS_KSU && ksu.toast) ksu.toast(m); else console.log(m); }

/* ===================== 诊断（v3.3） =====================
   目的：壁纸链路失败时，把确切原因写进模块日志，root 侧可直接读。
   在此之前只能靠用户截图 + 猜测，效率低且容易误判。
   纪律：诊断本身【绝不能】影响主流程 —— 只 fire-and-forget，异常一律吞掉。 */
const GB_BUILD = "2.2.11";
let diagSeq = 0;
let diagChain = Promise.resolve();
/* 诊断串行队列：KernelSU 的 ksu.exec 不适合并发调用，
   若诊断与主流程并发，诊断本身就会成为新的失败源。故全部排队执行。 */
function gbDiag(msg) {
  if (!HAS_KSU) return;          // 浏览器 8778 模式没有写日志通道
  try {
    const s = String(msg).replace(/['"\r\n\\]/g, " ").slice(0, 300);
    diagSeq++;
    diagChain = diagChain
      .then(() => sh("printf '%s\\n' '[" + GB_BUILD + " #" + diagSeq + "] " + s + "' >> __MODPATH__/webui_debug.log"))
      .catch(() => {});
  } catch (e) { /* 诊断失败绝不影响主流程 */ }
}
/* 同步等待诊断队列排空（仅在需要「失败后立刻回读日志」时调用） */
function gbDiagFlush() { try { return diagChain; } catch (e) { return Promise.resolve(); } }
/* 读取诊断尾部：失败时直接把原因带回页面，避免「只看提示、原因在别处」 */
async function gbDiagTail(lines) {
  try {
    await gbDiagFlush();
    const r = await sh("tail -n " + (lines || 10) + " __MODPATH__/webui_debug.log 2>/dev/null");
    return String((r && r.stdout) || "").trim();
  } catch (e) { return ""; }
}
function gbDiagEnv() {
  try {
    gbDiag("build=" + GB_BUILD
      + " | ua=" + (navigator.userAgent || "?")
      + " | ksu=" + HAS_KSU
      + " | dpr=" + (window.devicePixelRatio || 0)
      + " | 2d=" + (!!document.createElement("canvas").getContext("2d"))
      + " | fileReader=" + (typeof FileReader !== "undefined")
      + " | bitmap=" + (typeof createImageBitmap)
      + " | objURL=" + (typeof URL !== "undefined" && typeof URL.createObjectURL === "function"));
  } catch (e) {}
}
/* 清空上次运行的诊断，保证每次只看到本轮（同样入队，避免与主流程并发 ksu.exec） */
function gbDiagReset() {
  if (!HAS_KSU) return;
  try {
    diagSeq = 0;
    diagChain = diagChain
      .then(() => sh(": > __MODPATH__/webui_debug.log"))
      .then(() => sh("printf '%s\\n' '[" + GB_BUILD + " #0] === WebUI pick session ===' >> __MODPATH__/webui_debug.log"))
      .catch(() => {});
    diagChain = diagChain.then(() => {
      const env = "[" + GB_BUILD + " #env] "
        + "ua=" + (navigator.userAgent || "?")
        + " | ksu=" + HAS_KSU
        + " | 2d=" + (!!document.createElement("canvas").getContext("2d"))
        + " | fileReader=" + (typeof FileReader !== "undefined")
        + " | bitmap=" + (typeof createImageBitmap)
        + " | objURL=" + (typeof URL !== "undefined" && typeof URL.createObjectURL === "function");
      return sh("printf '%s\\n' '" + env.replace(/['"\r\n\\]/g, " ").slice(0, 300) + "' >> __MODPATH__/webui_debug.log");
    }).catch(() => {});
  } catch (e) {}
}
function fmtMHz(v) { return (v === undefined || v === null || v === "" || v === 0) ? "-- MHz" : (v + " MHz"); }

/* UTF-8 → base64url（[A-Za-z0-9_-]），用于一切外部路径入参。
   作用：把空格 / 引号 / 分号 / $ / 反引号 / 斜杠 全部从命令与 URL 中消除。 */
function b64url(str) {
  const bytes = new TextEncoder().encode(String(str));
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  // 必须去掉 '=' padding：后端 token 白名单只接受 [A-Za-z0-9_-]，
  // 带 '=' 会被 wall.sh 判为非法 token 并直接拒绝（bad-path-token）。
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/* ===================== 状态 / 配置 / 日志（原语义不动） ===================== */

async function refreshStatus({ silent = true } = {}) {
  try {
    const j = JSON.parse(await (await sh("sh __MODPATH__/cgi/status.sh")).stdout);
    $("#sPlatform").textContent = j.platform || "--";
    $("#sLiveFloor").textContent = fmtMHz(j.live_floor);
    // v2.1.5: 把"目标地板"拆成两组，避免"配置值 vs 运行态缓存"混淆：
    //   配置目标 = cfg_floor_mhz（status.sh 直接从 config 现算，非游戏态也准确）
    //   当前生效 = floor_mhz    （state 缓存，仅游戏态刷新）
    const elCfg = $("#sCfgFloor");
    if (elCfg) {
      const cl = (typeof j.cfg_floor_level === "number" && j.cfg_floor_level >= 0)
        ? (" · 档位 " + j.cfg_floor_level) : "";
      elCfg.textContent = fmtMHz(j.cfg_floor_mhz) + cl;
    }
    $("#sFloor").textContent = fmtMHz(j.floor_mhz);
    $("#sCeil").textContent = fmtMHz(j.ceil_mhz);
    $("#sCur").textContent = fmtMHz(j.cur);
    $("#sMax").textContent = fmtMHz(j.max);
    if (j.game === "yes") {
      $("#sGame").textContent = "游戏中" + (j.process ? " · " + j.process : "");
    } else if (j.state === "unsupported") {
      $("#sGame").textContent = "未适配平台";
    } else {
      $("#sGame").textContent = "空闲";
    }
    $("#sTemp").textContent = (j.temp === undefined || j.temp === null) ? "-- °C" : (j.temp + " °C");
    const elLvl = $("#sFloorLvl");
    if (elLvl) {
      elLvl.textContent = (j.pwrlevel === undefined || j.pwrlevel === null)
        ? "--"
        : ("档位 " + j.pwrlevel + ((j.num_levels ? " / " + (j.num_levels - 1) : "")));
    }
    $("#sLiveFloor").style.color = (j.game === "yes" && j.live_floor === j.floor_mhz) ? "var(--acc)" : "";
  } catch (e) { if (!silent) toast("刷新失败: " + e.message); }
}

let LIST_UNIT = "MHz";
const labelVal = (v) => (LIST_UNIT === "MHz" ? (v + " MHz") : ("档位 " + v));

async function loadConfig() {
  try {
    const j = JSON.parse(await (await sh("sh __MODPATH__/cgi/config.sh")).stdout);
    const list = Array.isArray(j.list) ? j.list : [];
    LIST_UNIT = j.unit || "MHz";
    const sel = $("#selFloor");
    const selC = $("#selCeil");

    // 关键：按【档位下标】命中，而不是按 MHz 值匹配。
    // 按值匹配在"配置值不在设备频表里"时一个 option 都命中不了，
    // 浏览器会静默选中第一项（= 最高频），与用户意图完全相反。
    const floorLvl = (typeof j.floor_level === "number" && j.floor_level >= 0) ? j.floor_level : -1;
    const ceilLvl  = (typeof j.ceil_level  === "number" && j.ceil_level  >= 0) ? j.ceil_level  : -1;

    if (sel && list.length) {
      sel.innerHTML = "";
      list.forEach((v, i) => {
        const o = document.createElement("option");
        o.value = v;
        o.textContent = labelVal(v) + " · 档位 " + i;
        if (i === floorLvl) o.selected = true;
        sel.appendChild(o);
      });
    }
    if (selC && list.length) {
      selC.innerHTML = "";
      const oTop = document.createElement("option");
      oTop.value = 0;
      oTop.textContent = "不限制（最高 " + labelVal(list[0]) + "）";
      if (ceilLvl < 0) oTop.selected = true;
      selC.appendChild(oTop);
      list.forEach((v, i) => {
        const o = document.createElement("option");
        o.value = v;
        o.textContent = labelVal(v) + " · 档位 " + i;
        if (i === ceilLvl) o.selected = true;
        selC.appendChild(o);
      });
    }

    const effFloor = (j.floor_eff === undefined) ? j.floor : j.floor_eff;
    const effCeil  = (j.ceil_eff  === undefined) ? j.ceil  : j.ceil_eff;
    const ceilTxt = (ceilLvl < 0) ? "不限制" : labelVal(effCeil);
    let hint = "当前地板 " + labelVal(effFloor) + "（档位 " + floorLvl + "）· 上限 " + ceilTxt;
    if (j.floor_mismatch || j.ceil_mismatch || j.list_mismatch) {
      hint = "⚠ 配置值与设备档位不一致 —— " + hint + "。点「保存档位」会自动吸附到设备真实档位。";
    }
    if (sel) $("#saveHint").textContent = hint;
  } catch (e) { console.log("loadConfig failed: " + e); }
}

async function saveCfg() {
  const selF = $("#selFloor");
  const selC = $("#selCeil");
  if (!selF) return;
  const btn = $("#btnSave");
  const floor = selF.value;
  const ceil = selC ? selC.value : 0;
  if (btn) { btn.disabled = true; btn.textContent = "保存中…"; }
  let r;
  try {
    r = await sh("sh __MODPATH__/cgi/config.sh save " + floor + " " + ceil);
  } catch (e) {
    r = { errno: 1, stdout: "", stderr: String(e) };
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = "保存档位"; }
  }
  let ok = false, f = floor, c = ceil, fl = null, cl = null, fclamp = 0;
  try {
    const j = JSON.parse(r.stdout);
    ok = !!j.ok;
    f = (j.floor === undefined) ? floor : j.floor;      // 后端【吸附后】的值
    c = (j.ceil  === undefined) ? ceil  : j.ceil;
    fl = (j.floor_level === undefined) ? null : j.floor_level;
    cl = (j.ceil_level  === undefined) ? null : j.ceil_level;
    fclamp = j.floor_clamped || 0;
  } catch (e) {}
  if (ok) {
    const ceilTxt = (!c || c == 0) ? "不限制" : labelVal(c);
    let msg = "已保存并生效：地板 " + labelVal(f)
            + (fl !== null ? "（档位 " + fl + "）" : "")
            + " · 上限 " + ceilTxt + (cl !== null && cl >= 0 ? "（档位 " + cl + "）" : "");
    if (String(f) !== String(floor) || String(c) !== String(ceil)) {
      msg += " ｜已自动吸附到设备真实档位";
    }
    if (fclamp) {
      msg += "。⚠ 上限档位高于地板，窗口为空，地板已对齐上限（等效锁频）";
    }
    $("#saveHint").textContent = msg;
    toast("已保存 地板 " + labelVal(f) + " / 上限 " + ceilTxt);
    await loadConfig();   // 回读生效值，让下拉框停在真实档位上
  } else {
    // 禁止静默失败：把通道错误原文也带到页面上
    const why = r && r.stderr ? ("（" + r.stderr + "）") : "";
    $("#saveHint").textContent = "保存失败，请重试" + why;
    toast("保存失败" + why);
  }
  await refreshStatus({ silent: true });
}

async function refreshLog() {
  try {
    const t = await (await sh("sh __MODPATH__/cgi/log.sh")).stdout;
    const el = $("#logView");
    if (!el) return;
    el.textContent = t || "(空)";
    el.scrollTop = el.scrollHeight;
  } catch (e) { const el = $("#logView"); if (el) el.textContent = "读取失败: " + e.message; }
}

/* ===================== 主题三态（light 默认 / dark / auto） ===================== */

const THEMES = ["light", "dark", "auto"];
const THEME_META = {
  light: { icon: "☀", label: "日间" },
  dark:  { icon: "☾", label: "暗色" },
  auto:  { icon: "◐", label: "跟随" }
};
let theme = "light";
try { theme = localStorage.getItem("gb_theme") || "light"; } catch (e) { theme = "light"; }
if (THEMES.indexOf(theme) < 0) theme = "light";

function applyTheme(t, persist) {
  theme = t;
  document.documentElement.dataset.theme = t;
  const meta = THEME_META[t] || THEME_META.light;
  const ic = $("#themeIcon"), lb = $("#themeLabel");
  if (ic) ic.textContent = meta.icon;
  if (lb) lb.textContent = meta.label;
  if (persist) { try { localStorage.setItem("gb_theme", t); } catch (e) { console.log("theme persist failed: " + e); } }
}
function cycleTheme() {
  const i = THEMES.indexOf(theme);
  applyTheme(THEMES[(i + 1) % THEMES.length], true);
}
applyTheme(theme, false);

/* ===================== 壁纸（相册主通道 + 目录 / 手输降级） =====================
   失败一律可见：wallHint（页面）+ toast。禁止只 console.log。 */

const MAX_W = 1440;        // canvas 压缩时的最大宽度
const QUALITY = 0.82;      // canvas 压缩时的 JPEG 质量
const RAW_MAX = 12 * 1024 * 1024;  // 直传上限 12MB（base64 后约 16MB，再大则走压缩）
/* 单块 base64 字符数：Linux 单参数上限 MAX_ARG_STRLEN = 131072 字节，
   65536 留 2x 余量。块越大，ksu.exec 往返次数越少（4MB 图约 90 块）。 */
const CHUNK = 65536;

let wallOp = 35;           // 壁纸透明度 0~100
let wallGlass = 50;        // 液态玻璃透明度 0~100（越高越透）
let wallBlur = 24;         // 玻璃模糊 0~40px
let wallSet = false;       // 是否已设置壁纸
let wallShownUrl = "";     // 当前已显示的壁纸 URL（用于避免首屏预热后重复加载）

function setWallHint(msg, bad) {
  const el = $("#wallHint");
  if (!el) return;
  el.textContent = msg || "";
  if (bad) el.classList.add("bad"); else el.classList.remove("bad");
}
/* 失败一律可见：页面（wallHint）+ toast。
   v2.2.2：再【异步补齐诊断尾部】并直接显示在页面上 ——
   这样无需 root 读日志，你在管理器里就能看到确切失败环节（截图即可定位）。
   注意：必须保持同步返回 false，且异步块异常不得外泄，否则会影响主流程。 */
function wallFail(msg) {
  setWallHint(msg, true);
  toast("壁纸操作失败: " + msg);
  if (HAS_KSU) {
    try {
      gbDiagTail(10).then(function (t) {
        if (t) setWallHint(msg + "\n—— 诊断尾部 ——\n" + t, true);
      }).catch(function () {});
    } catch (e) {}
  }
  return false;
}
function wallOK(msg) { setWallHint(msg, false); toast(msg); return true; }
function setWallTag(on) {
  const t = $("#wallTag");
  if (t) t.textContent = on ? "已设置" : "未设置";
}
function numOr(v, d) { const n = parseInt(v, 10); return (isNaN(n) ? d : n); }

function applyWallOpacity(v) {
  const n = Math.max(0, Math.min(100, numOr(v, 35)));
  wallOp = n;
  document.documentElement.style.setProperty("--wall-op", String(n / 100));
  const hint = $("#wallOpacityHint");
  if (hint) hint.textContent = n + "%";
  const sl = $("#wallOpacity");
  if (sl && String(sl.value) !== String(n)) sl.value = String(n);
}
/* 「液态玻璃透明度」滑杆：值越高越透明。
   映射：0 → alpha 1.0（几乎不透明，最实）
         100 → alpha 0.06（几乎全透）
   公式：alpha = 1.0 - v/100 * 0.94
   说明：为什么不直接 alpha = 1 - v/100？因为 alpha=0 会让文字彻底失去承载，
        极难看清；留 0.06 下限保证最低可读性。 */
function glassAlphaOf(v) {
  const n = Math.max(0, Math.min(100, numOr(v, 50)));
  // v2.2.5：上限完全放开 —— 100% → alpha 0（玻璃底衬消失，仅剩边框与文字）
  return Math.max(0, Math.min(1, 1 - n / 100));
}
function applyGlass(v) {
  const n = Math.max(0, Math.min(100, numOr(v, 50)));
  wallGlass = n;
  document.documentElement.style.setProperty("--glassA", String(glassAlphaOf(n)));
  const hint = $("#glassHint");
  if (hint) hint.textContent = n + "%（越高越透，100% 全透）";
  const sl = $("#glassOpacity");
  if (sl && String(sl.value) !== String(n)) sl.value = String(n);
}
/* 「玻璃模糊」滑杆：0–40px，作用于底部浮动按钮的 backdrop-filter。
   0px = 无模糊（纯透明玻璃，完全靠 alpha 与边框区分层次）
   越高越磨砂（背景被高斯模糊，文字更清晰） */
function applyBlur(v) {
  const n = Math.max(0, Math.min(40, numOr(v, 24)));
  wallBlur = n;
  document.documentElement.style.setProperty("--glassBlur", n + "px");
  const hint = $("#blurHint");
  if (hint) hint.textContent = n + "px" + (n === 0 ? "（无模糊）" : "");
  const sl = $("#glassBlur");
  if (sl && String(sl.value) !== String(n)) sl.value = String(n);
}
function applyWallpaper(url) {
  if (url) {
    document.documentElement.style.setProperty("--wall-img", 'url("' + url + '")');
    wallSet = true;
    wallShownUrl = url;
  } else {
    document.documentElement.style.setProperty("--wall-img", "none");
    wallSet = false;
    wallShownUrl = "";
  }
  setWallTag(wallSet);
}
/* ===================== 首屏壁纸预热（v2.2.6） =====================
   实测瓶颈：`wall.sh get` 需 0.6~1.0s（shell 多次 fork + 8778 的 nc 单请求串行）。
   原实现必须等 get 返回才知道 wall_mtime，才能拼出 /wallpaper.jpg?v=<mtime> URL
   → 首屏白等近 1 秒才开始请求图片，用户观感就是「打开有几秒不加载壁纸」。
   对策：把上次成功的 present/mtime 缓存进 localStorage，首屏立刻用缓存 URL 显示；
   get 返回后再校正（内容未变则复用同一 URL，已变则换成新 URL 触发重取）。
   注意：localStorage 在 KSU WebUI 可用（宿主已 setDomStorageEnabled）。 */
const WALL_CACHE_KEY = "gb_wall_cache_v1";
/* v2.2.9：缓存扩展为同时保存三个滑杆值。
   原因：配置本身早已持久化在模块 config/wall.conf（重启不丢），
   但前端首屏只能等 wall.sh get（~0.3s）才知道用户实际值，
   期间会用默认值 35/50/24 渲染 → 界面先闪一下再跳到 100/100/0。
   把滑杆值一起缓存后，首屏即用真实值渲染，不再闪。 */
function primeWallFromCache() {
  try {
    const raw = localStorage.getItem(WALL_CACHE_KEY);
    if (!raw) return false;
    const c = JSON.parse(raw);
    if (!c) return false;
    // 1) 先用缓存的滑杆值（真实用户值）覆盖默认值，避免首屏闪跳
    if (c.op !== undefined) applyWallOpacity(c.op);
    if (c.gl !== undefined) applyGlass(c.gl);
    if (c.bl !== undefined) applyBlur(c.bl);
    // 2) 再显示壁纸
    if (c.present !== 1) return false;
    applyWallpaper(CGI_BASE + "/wallpaper.jpg?v=" + (c.mtime || 0));
    gbDiag("首屏预热: 缓存 mtime=" + (c.mtime || 0)
      + " op=" + (c.op !== undefined ? c.op : "?")
      + " gl=" + (c.gl !== undefined ? c.gl : "?")
      + " bl=" + (c.bl !== undefined ? c.bl : "?"));
    return true;
  } catch (e) { return false; }
}
/* 合并写入：保留已有字段（present/mtime/op/gl/bl 各自独立更新，互不覆盖） */
function saveWallCache(patch) {
  try {
    let cur = {};
    try { cur = JSON.parse(localStorage.getItem(WALL_CACHE_KEY) || "{}") || {}; } catch (e) { cur = {}; }
    if (patch && typeof patch === "object") {
      for (const k in patch) { if (Object.prototype.hasOwnProperty.call(patch, k)) cur[k] = patch[k]; }
    }
    localStorage.setItem(WALL_CACHE_KEY, JSON.stringify(cur));
  } catch (e) {}
}
/* 滑杆值单独更新（三个滑杆 change 成功后调用，保证下次首屏用最新值） */
function saveSliderCache() {
  saveWallCache({
    op: (typeof wallOp === "number" ? wallOp : undefined),
    gl: (typeof wallGlass === "number" ? wallGlass : undefined),
    bl: (typeof wallBlur === "number" ? wallBlur : undefined),
  });
}

/* 探测可用的壁纸 URL：优先 8778 路由，失败回退 file:// 本地路径（KSU 模式）。 */
function probeWall(primary, fallback, onDone) {
  const im = new Image();
  im.onload = () => { applyWallpaper(primary); if (onDone) onDone(true); };
  im.onerror = () => { applyWallpaper(fallback || ""); if (onDone) onDone(!!fallback); };
  im.src = primary;
}

/* wall.sh get → wall_present / wall_path / wall_src / wall_opacity / wall_mtime
   v2.2.7：slidersOnly=true 时只同步三个滑杆的值，不动壁纸（打开设置页时用，
   避免重复触发图片加载/闪烁）。 */
async function wallInit(slidersOnly) {
  try {
    const r = await wallSh("get");
    const out = (r && r.stdout) ? r.stdout : "";
    if (!out.trim() || /^ERR/.test(out.trim())) {
      if (!slidersOnly) applyWallpaper("");
      return;
    }
    const mp = out.match(/^wall_present=(.*)$/m);
    const mo = out.match(/^wall_opacity=(.*)$/m);
    const mg = out.match(/^wall_glass=(.*)$/m);
    const mb = out.match(/^wall_blur=(.*)$/m);
    const mt = out.match(/^wall_mtime=(.*)$/m);
    if (mo) applyWallOpacity(mo[1]);
    if (mg) applyGlass(mg[1]);
    if (mb) applyBlur(mb[1]);
    if (slidersOnly) return;
    const present = !!(mp && mp[1].trim() === "1");
    const v = mt ? mt[1].trim() : "0";
    saveWallCache({ present: present ? 1 : 0, mtime: v });   // 供下次首屏预热
    // v2.2.9：把服务端权威值同步进滑杆缓存，保证下次首屏就用真实值
    saveSliderCache();
    if (!present) { applyWallpaper(""); return; }
    const http = CGI_BASE + "/wallpaper.jpg?v=" + v;
    const local = (HAS_KSU && MODPATH) ? ("file://" + MODPATH + "/webroot/bg/wall.jpg?v=" + v) : "";
    // 若首屏预热已用相同 mtime 显示过，无需重复设置（避免二次解码/闪烁）
    if (wallSet && wallShownUrl === http) { gbDiag("wallInit: 与预热 URL 相同，跳过重复加载"); return; }
    if (local) probeWall(http, local); else applyWallpaper(http);
  } catch (e) {
    setWallHint("壁纸配置读取失败: " + e.message, true);
  }
}

/* 复用 sh() 通道调用 wall.sh 子命令。
   isPath=true 时 arg 会被 base64url token 化（禁止把裸路径拼进命令/URL）。 */
function wallSh(op, arg, isPath) {
  let a = (arg === undefined || arg === null) ? "" : String(arg);
  if (a && isPath) a = b64url(a);
  const cmd = "sh __MODPATH__/cgi/wall.sh " + op + (a ? " " + a : "");
  return sh(cmd);
}

/* ---- 主通道：系统相册 / 文件管理器 ----
   v3.2 修复「图片解码失败」：
   原实现只用 createImageBitmap(file)，而该方法在部分 Android WebView 内核上
   对 File 对象直接 reject（实测触发），且无任何兜底 → 一次失败整条链路断。
   改为三级解码降级，任一成功即用，全失败才报错并把三级错误原文带回页面：
     ① FileReader.readAsDataURL → Image.onload   （走 WebView 图片解码器，兼容性最好，首选）
     ② createImageBitmap(file)                    （支持时更快）
     ③ URL.createObjectURL → Image.onload         （兜底，用完即时 revoke） */

function loadImageViaDataURL(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error("FileReader 读取失败"));
    fr.onload = () => {
      const im = new Image();
      im.onerror = () => reject(new Error("Image 解码失败(dataURL)"));
      im.onload = () => (im.width > 0 ? resolve(im) : reject(new Error("尺寸为 0(dataURL)")));
      im.src = String(fr.result);
    };
    fr.readAsDataURL(file);
  });
}
function loadImageViaBitmap(file) {
  if (typeof createImageBitmap !== "function") {
    return Promise.reject(new Error("不支持 createImageBitmap"));
  }
  return createImageBitmap(file).then((im) => {
    if (!im || !im.width) throw new Error("尺寸为 0(bitmap)");
    return im;
  });
}
function loadImageViaObjectURL(file) {
  return new Promise((resolve, reject) => {
    let url = "";
    try { url = URL.createObjectURL(file); }
    catch (e) { reject(new Error("createObjectURL 失败")); return; }
    const im = new Image();
    im.onerror = () => {
      try { URL.revokeObjectURL(url); } catch (e) {}
      reject(new Error("Image 解码失败(objectURL)"));
    };
    im.onload = () => {
      try { URL.revokeObjectURL(url); } catch (e) {}
      im.width > 0 ? resolve(im) : reject(new Error("尺寸为 0(objectURL)"));
    };
    im.src = url;
  });
}
async function decodeImage(file) {
  const errs = [];
  const names = ["dataURL", "bitmap", "objectURL"];
  const chain = [loadImageViaDataURL, loadImageViaBitmap, loadImageViaObjectURL];
  for (let i = 0; i < chain.length; i++) {
    try {
      const im = await chain[i](file);
      gbDiag("decode OK via " + names[i] + " " + (im && im.width) + "x" + (im && im.height));
      return im;
    } catch (e) {
      const m = (e && e.message) || String(e);
      errs.push((i + 1) + ")" + m);
      gbDiag("decode FAIL " + names[i] + ": " + m);   // 逐级可见，锁定到底哪级挂了
    }
  }
  throw new Error("三级解码均失败 → " + errs.join(" ｜ "));
}

/* canvas 编码：JPEG 失败自动降尺寸重试（最多 3 次），仍失败退 PNG。
   v3.3：① getContext 未判空（原代码 ctx 为 null 时直接抛 TypeError）
         ② 每一级失败都写诊断，不再只说「编码失败」 */
async function compressToBase64(file) {
  const img = await decodeImage(file);
  const w0 = img.width, h0 = img.height;
  gbDiag("decoded: " + w0 + "x" + h0);
  let scale = Math.min(1, MAX_W / w0);
  const cv = document.createElement("canvas");
  const ctx = cv.getContext("2d");
  if (!ctx) { gbDiag("FATAL: canvas.getContext('2d') 返回 null"); throw new Error("canvas 2d 上下文不可用（getContext 返回 null）"); }
  const errs = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const W = Math.max(1, Math.round(w0 * scale));
    const H = Math.max(1, Math.round(h0 * scale));
    cv.width = W; cv.height = H;
    try {
      ctx.clearRect(0, 0, W, H);
      ctx.drawImage(img, 0, 0, W, H);
    } catch (e) {
      errs.push("draw#" + (attempt + 1) + ":" + ((e && e.message) || e));
    }
    let b64 = "";
    try { b64 = (cv.toDataURL("image/jpeg", QUALITY) || "").split(",")[1] || ""; }
    catch (e) { errs.push("jpeg#" + (attempt + 1) + ":" + ((e && e.message) || e)); }
    if (b64 && b64.length > 128) {
      gbDiag("canvas jpeg OK: " + W + "x" + H + " b64=" + b64.length + " attempt=" + (attempt + 1));
      if (typeof img.close === "function") { try { img.close(); } catch (e) {} }
      return { b64: b64, w: W, h: H };
    }
    errs.push("jpeg#" + (attempt + 1) + ":empty(" + b64.length + ")");
    scale *= 0.7;
  }
  try {
    const bp = (cv.toDataURL("image/png") || "").split(",")[1] || "";
    if (bp && bp.length > 128) {
      gbDiag("canvas png OK: " + cv.width + "x" + cv.height + " b64=" + bp.length);
      if (typeof img.close === "function") { try { img.close(); } catch (e) {} }
      return { b64: bp, w: cv.width, h: cv.height };
    }
    errs.push("png:empty(" + bp.length + ")");
  } catch (e) { errs.push("png:" + ((e && e.message) || e)); }
  gbDiag("canvas FAIL: " + errs.join(" | ").slice(0, 240));
  throw new Error("canvas 编码失败（" + errs.slice(-4).join(" ｜ ") + "）");
}

/* ===================== 直传通道 v2（定稿）：root 直读，绕开 File 空壳 =====================
   实测根因（webui_debug.log + MediaStore 对照铁证）：
     宿主 SuKiSU Ultra 的 onShowFileChooser → FileChooserParams.parseResult()
     交给 WebView 的 File 是【空壳】：
       name = MediaStore _id（如 "1005543534.jpg"，不是磁盘文件名）
       size = 0
       无字节流 → FileReader / createImageBitmap / createObjectURL 三条通道全挂
     对照真实文件：1,523,141 字节、magic ffd8ffe1、root 可读。
   结论：前端解码链路再多降级也救不了「水源是空的」。唯一正解 =
   既然 ksu.exec 本来就是 root，就不该绕 WebView —— 直接用 _id 解析真实路径，
   root 侧 cp 进模块，再交后端 magic 校验 + 原子替换。 */

/* POSIX 单引号转义：把任意字符串安全嵌进单引号内（文件名可能含空格/中文/引号） */
function sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

/* 从 file.name 提取 MediaStore _id。
   ⚠ 严格白名单：仅接受「纯数字」或「数字.扩展名」，杜绝把文件名拼进 shell 造成注入。
   返回 "" 表示不是 ID 形式（调用方回落 FileReader 通道）。 */
function extractMediaId(file) {
  const nm = String(file.name || "").replace(/^\s+|\s+$/g, "");
  const m = nm.match(/^([0-9]{2,})(\.[A-Za-z0-9]{1,8})?$/);
  return m ? m[1] : "";
}

/* ===================== 大图瘦身（v2.2.6） =====================
   为什么要做：相册原图常为 3072×4096（12.6MP / 11MB）。WebView 每次打开都要
   解码这张巨图，实测「打开 WebUI 数秒不显示壁纸」的主因之一就是它。
   壁纸在手机屏幕上最多占 ~1080×2400，无需 4096 高的原图。
   策略：优先用系统自带工具无损/近无损降采样；全部不可用时原样保留（不阻断功能）。
   返回：瘦身后的字节数，-1 表示未瘦身。 */
async function shrinkIfHuge(path) {
  const st = await sh("wc -c < " + sq(path));
  const sz = parseInt(((st && st.stdout) || "").trim(), 10);
  if (isNaN(sz) || sz < 2 * 1024 * 1024) { gbDiag("瘦身: 跳过（" + (isNaN(sz) ? "?" : sz) + "B < 2MB）"); return -1; }
  gbDiag("瘦身: 原图 " + (sz / 1024 / 1024).toFixed(2) + "MB，尝试降采样");
  const tmp = path + ".small";
  // 逐级尝试可用的系统工具（Android 常见：toybox/magisk ffmpeg/screencap 均不可用于 jpeg 缩放，
  // 故主要依赖下面两条：① busybox 无图片 applet 时走 ② 的 media 工具）
  const tries = [
    // ① ImageMagick（少数 ROM / 模块自带）
    "convert " + sq(path) + " -resize 1440x1440\\> -quality 88 " + sq(tmp),
    // ② ffmpeg（若设备装了）
    "ffmpeg -y -i " + sq(path) + " -vf scale='min(1440,iw)':-2 -q:v 4 " + sq(tmp),
  ];
  for (let i = 0; i < tries.length; i++) {
    const r = await sh(tries[i] + " >/dev/null 2>&1 && [ -s " + sq(tmp) + " ] && echo OK");
    if (r && r.errno === 0 && /OK/.test(r.stdout || "")) {
      const ck = await sh("wc -c < " + sq(tmp));
      const ns = parseInt(((ck && ck.stdout) || "").trim(), 10);
      const mg = await sh("od -An -tx1 -N3 " + sq(tmp));
      const magic = String((mg && mg.stdout) || "").replace(/\\s+/g, "");
      if (!isNaN(ns) && ns > 64 && /^ffd8ff/.test(magic) && ns < sz) {
        const mv = await sh("mv -f " + sq(tmp) + " " + sq(path) + " && echo OK");
        if (mv && mv.errno === 0 && /OK/.test(mv.stdout || "")) {
          gbDiag("瘦身: 成功 " + (sz / 1024 / 1024).toFixed(2) + "MB → " + (ns / 1024 / 1024).toFixed(2) + "MB");
          return ns;
        }
      }
      await sh("rm -f " + sq(tmp));
    }
  }
  await sh("rm -f " + sq(tmp));
  gbDiag("瘦身: 无可用图片工具，保留原图（不影响功能）");
  return -1;
}

/* root 直读：MediaStore _id → 真实路径 → 直接写进模块 webroot/bg/wall.new.jpg
   返回写入的新文件路径；返回 "" 表示失败（调用方回落 / 报错）。 */
async function passthroughByMediaId(file) {
  const id = extractMediaId(file);
  if (!id) { gbDiag("root直读: name 非 MediaStore ID（name=" + (file.name || "?") + "），跳过"); return ""; }
  gbDiag("root直读: MediaStore _id=" + id);

  const bg = MODPATH + "/webroot/bg";
  const nw = bg + "/wall.new.jpg";
  let r = await sh("[ -d " + bg + "] || mkdir -p " + bg);
  if (r.errno !== 0) { gbDiag("root直读: mkdir FAIL " + (r.stderr || "?")); return ""; }

  // ---- 方式 A：解析 _data 真实路径 → cp（已验证与源 md5 一致）----
  let real = "";
  for (const tbl of ["images/media", "files/media"]) {
    const q = await sh("content query --uri content://media/external/" + tbl
      + " --projection _data --where '_id=" + id + "' 2>/dev/null"
      + " | sed -n 's/.*_data=\\([^,]*\\).*/\\1/p' | head -1");
    const p = ((q && q.stdout) || "").trim();
    if (p && p.charAt(0) === "/") { real = p; break; }
  }
  if (real) {
    gbDiag("root直读: 真实路径=" + real);
    const cp = await sh("cp -f " + sq(real) + " " + sq(nw) + " && echo OK");
    if (cp && cp.errno === 0 && /OK/.test(cp.stdout || "")) {
      const ck = await sh("wc -c < " + nw);
      const sz = parseInt(((ck && ck.stdout) || "").trim(), 10);
      const mg = await sh("od -An -tx1 -N4 " + nw);
      gbDiag("root直读(cp): bytes=" + (isNaN(sz) ? "?" : sz)
        + " magic=" + String((mg && mg.stdout) || "?").replace(/\s+/g, ""));
      if (!isNaN(sz) && sz > 64) { await shrinkIfHuge(nw); return nw; }
      gbDiag("root直读(cp): 结果过小，判定失败");
    } else {
      gbDiag("root直读(cp) FAIL: " + ((cp && cp.stderr) || "?"));
    }
  }

  // ---- 方式 B 兜底：content read 直接把 URI 流写进文件（不依赖 _data 列）----
  gbDiag("root直读: _data 不可用，改用 content read 流式读取");
  const rd = await sh("content read --uri content://media/external/images/media/" + id
    + " > " + sq(nw) + " 2>/dev/null && echo OK");
  if (rd && rd.errno === 0 && /OK/.test(rd.stdout || "")) {
    const ck = await sh("wc -c < " + nw);
    const sz = parseInt(((ck && ck.stdout) || "").trim(), 10);
    const mg = await sh("od -An -tx1 -N4 " + nw);
    gbDiag("root直读(read): bytes=" + (isNaN(sz) ? "?" : sz)
      + " magic=" + String((mg && mg.stdout) || "?").replace(/\s+/g, ""));
    if (!isNaN(sz) && sz > 64) return nw;
  } else {
    gbDiag("root直读(read) FAIL: " + ((rd && rd.stderr) || "?"));
  }
  await sh("rm -f " + nw);
  return "";
}
function fileToRawBase64(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error("FileReader 读取原始字节失败"));
    fr.onload = () => {
      const s = String(fr.result || "");
      const i = s.indexOf(",");
      if (i < 0) { reject(new Error("dataURL 格式异常")); return; }
      const b64 = s.slice(i + 1);
      if (!b64 || b64.length <= 128) { reject(new Error("原始字节为空（b64=" + b64.length + "）")); return; }
      // 上限兜底：真正以【读出的实际长度】判定（file.size 不可信）
      const realBytes = Math.floor(b64.length * 3 / 4);
      if (realBytes > RAW_MAX) {
        reject(new Error("原图 " + (realBytes / 1024 / 1024).toFixed(2) + "MB 超过直传上限 "
          + (RAW_MAX / 1024 / 1024) + "MB，改走压缩通道"));
        return;
      }
      resolve(b64);
    };
    fr.readAsDataURL(file);
  });
}
/* 保留兼容：v2.2.2 起直传不再依赖此判定（仅用于日志说明） */
function canPassThrough(file) {
  const t = String(file.type || "").toLowerCase();
  const n = String(file.name || "").toLowerCase();
  const mimes = ["image/jpeg", "image/jpg", "image/pjpeg", "image/png", "image/webp"];
  const exts = [".jpg", ".jpeg", ".png", ".webp"];
  return (mimes.indexOf(t) >= 0) || exts.some((e) => n.endsWith(e));
}

function setProg(pct) {
  const wrap = $("#wallProgWrap"), el = $("#wallProg");
  if (wrap) wrap.hidden = (pct === null);
  if (el && pct !== null) el.textContent = pct + "%";
}
/* 分块写 base64 → base64 -d → 校验 → commit（旧壁纸保留到新文件成功为止）
   v3.1：任一块失败立即清理并终止；绝不跳过块（跳过会拼出缺块损坏图）。
   v3.3：chunk 提到 64KB；每次失败都写诊断；失败提示不再指向已删除的 UI。 */
async function writeBase64ToFile(b64, file) {
  if (!MODPATH) return wallFail("模块路径未知（MODPATH 为空），已拒绝写入");
  const mp = MODPATH;
  const bg = mp + "/webroot/bg";
  const tmp = bg + "/.wall.b64";
  const nw = bg + "/wall.new.jpg";

  let r = await sh("[ -d " + bg + " ] || mkdir -p " + bg);
  if (r.errno !== 0) { gbDiag("mkdir FAIL: " + (r.stderr || "?")); return wallFail("无法创建 " + bg + "：" + (r.stderr || "未知错误")); }

  r = await sh(": > " + tmp);
  if (r.errno !== 0) { gbDiag("touch tmp FAIL: " + (r.stderr || "?")); return wallFail("无法创建临时文件：" + (r.stderr || "未知错误")); }

  // ---- 分块写入（自适应：主用 CHUNK，失败自动降到 8192 整段重试一次）----
  // 不同 WebView/宿主对单条命令长度容忍度不同；硬编码单值时，
  // 一旦环境偏严就会「某块失败 → 整张图作废」。降级重试可自愈这类差异。
  async function doChunks(chunkSize) {
    await sh(": > " + tmp);
    const total = Math.ceil(b64.length / chunkSize);
    gbDiag("write: b64=" + b64.length + " chunks=" + total + " chunkSize=" + chunkSize);
    const t0 = Date.now();
    for (let i = 0; i < total; i++) {
      const seg = b64.substr(i * chunkSize, chunkSize);
      // base64 字符集安全（A-Za-z0-9+/=），用单引号包裹；不含 ' 故无闭合风险
      let rr;
      try {
        rr = await sh("printf '%s' '" + seg + "' >> " + tmp);
      } catch (e) {
        rr = { errno: 1, stdout: "", stderr: String(e) };
      }
      if (!rr || rr.errno !== 0) {
        gbDiag("chunk " + (i + 1) + "/" + total + " FAIL(chunk=" + chunkSize + "): errno=" + (rr && rr.errno)
          + " stderr=" + ((rr && rr.stderr) || "?").slice(0, 120));
        return { ok: false, at: i + 1, total: total, err: (rr && rr.stderr) || "未知错误" };
      }
      if (i % 16 === 0) setProg(Math.round(((i + 1) / total) * 100));
      if ((i & 63) === 0 && Date.now() - t0 > 180000) {
        // 超长耗时保护：不静默卡死，直接报告并清理（直传大图放宽到 3 分钟）
        gbDiag("write timeout at chunk " + (i + 1) + "/" + total);
        return { ok: false, at: i + 1, total: total, err: "写入超时", timeout: true };
      }
    }
    // 长度校验：防截断（b64 字符集无换行）
    const rw = await sh("wc -c < " + tmp);
    const got = parseInt(((rw && rw.stdout) || "").trim(), 10);
    if (isNaN(got) || got !== b64.length) {
      gbDiag("size mismatch: expect=" + b64.length + " got=" + (isNaN(got) ? "?" : got));
      return { ok: false, at: total, total: total, err: "长度校验失败（预期 " + b64.length + "，实际 " + (isNaN(got) ? "?" : got) + "）", sizeMismatch: true };
    }
    return { ok: true, total: total, got: got };
  }

  let wr = await doChunks(CHUNK);
  if (!wr.ok && !wr.timeout) {
    gbDiag("块写入失败(chunk=" + CHUNK + ") → 降级 8192 重试: " + wr.err);
    await sh("rm -f " + tmp);
    setProg(0);
    wr = await doChunks(8192);
    if (wr.ok) gbDiag("降级 8192 写入成功（该环境对大块命令不友好，已自愈）");
  }
  if (!wr.ok) {
    await sh("rm -f " + tmp);
    setProg(null);
    if (wr.timeout) return wallFail("写入超时（已写 " + wr.at + "/" + wr.total + " 块），临时文件已清理，原壁纸保留");
    return wallFail("写入失败（第 " + wr.at + "/" + wr.total + " 块）：" + wr.err + " ｜临时文件已清理，原壁纸保留");
  }
  gbDiag("size OK: " + wr.got);

  // 解码 → 新文件（不覆盖旧 wall.jpg）
  r = await sh("base64 -d " + tmp + " > " + nw + " && rm -f " + tmp + " && echo OK");
  if (!r || r.errno !== 0 || !/OK/.test(r.stdout || "")) {
    gbDiag("base64 -d FAIL: errno=" + (r && r.errno) + " stderr=" + ((r && r.stderr) || "?").slice(0, 120));
    await sh("rm -f " + tmp + " " + nw);
    setProg(null);
    return wallFail("base64 解码失败：" + ((r && r.stderr) || "未知错误") + "，原壁纸未改动");
  }
  const nsz = await sh("wc -c < " + nw);
  const mg = await sh("od -An -tx1 -N4 " + nw);
  gbDiag("decoded bytes=" + String((nsz && nsz.stdout) || "?").trim()
    + " magic=" + String((mg && mg.stdout) || "?").replace(/\s+/g, ""));

  // 交给后端校验 magic 并原子替换（此时才覆盖旧壁纸）
  r = await wallSh("commit");
  if (!r || r.errno !== 0 || !/^OK/.test((r.stdout || "").trim())) {
    gbDiag("commit FAIL: stdout=" + ((r && r.stdout) || "").slice(0, 120) + " stderr=" + ((r && r.stderr) || "").slice(0, 80));
    await sh("rm -f " + nw);
    setProg(null);
    return wallFail("提交壁纸失败：" + ((r && r.stdout) || "") + ((r && r.stderr) || "未知错误"));
  }
  gbDiag("commit OK: " + ((r && r.stdout) || "").trim().slice(0, 60));
  setProg(null);
  await wallInit();
  return wallOK("壁纸已更新");
}

async function persistWallFromFile(file) {
  if (!file) return false;
  // 放宽：部分 content provider 不提供 MIME（file.type 为空），不得因此拒绝。
  // 只在明确是非图片 MIME 时才拦（如 video/*、text/*），空值放行交给解码判定。
  if (file.type && !/^image\//.test(file.type)) {
    gbDiag("reject: non-image mime=" + file.type);
    return wallFail("选择的不是图片文件（" + file.type + "）");
  }
  gbDiag("picked: name=" + (file.name || "?") + " type=" + (file.type || "(empty)")
    + " size=" + (file.size === undefined ? "?" : file.size));
  if (!MODPATH) { await detectPath(); }
  if (!MODPATH) return wallFail("模块路径未知（MODPATH 为空），已拒绝写入");

  // ---- 通道 ①（首选）：root 直读，绕开 WebView File 空壳 ----
  // 实测：宿主交给 WebView 的 File 只有 MediaStore _id + size=0，三通道全挂。
  // 而 ksu.exec 本就是 root，直接按 _id 解析真实路径读盘最可靠。
  if (HAS_KSU) {
    const isIdForm = !!extractMediaId(file);
    if (isIdForm || !canPassThrough(file)) {
      setWallHint("读取中…", false);
      const nwPath = await passthroughByMediaId(file);
      if (nwPath) {
        setWallHint("提交中…", false);
        const c = await wallSh("commit");
        const out = ((c && c.stdout) || "").trim();
        if (c && c.errno === 0 && /^OK/.test(out)) {
          gbDiag("root直读 commit OK: " + out.slice(0, 60));
          setProg(null);
          await wallInit();
          return wallOK("壁纸已更新（原图直传）");
        }
        gbDiag("root直读 commit FAIL: stdout=" + out.slice(0, 120)
          + " stderr=" + ((c && c.stderr) || "?").slice(0, 80));
        await sh("rm -f " + nwPath);
        setProg(null);
        return wallFail("提交壁纸失败：" + out + ((c && c.stderr) || ""));
      }
      gbDiag("root直读未成功，回落 FileReader 通道");
    }
  }

  // ---- 通道 ②：FileReader 原图直传（零 canvas）----
  if (HAS_KSU && canPassThrough(file)) {
    setWallHint("读取图片中…", false);
    let raw = "";
    try {
      raw = await fileToRawBase64(file);
    } catch (e) {
      gbDiag("passthrough read FAIL: " + (e && e.message ? e.message : e) + " → 转压缩通道");
      raw = "";
    }
    if (raw) {
      const mb = (raw.length / 1024 / 1024).toFixed(2);
      gbDiag("passthrough: b64=" + raw.length + " (" + mb + "MB) → 直传写盘");
      setWallHint("写入中（直传原图 " + mb + "MB）…", false);
      const okRaw = await writeBase64ToFile(raw, file);
      if (okRaw) return true;
      gbDiag("passthrough write FAIL → 转压缩通道重试");
      setWallHint("直传失败，改用压缩通道重试…", false);
    }
  }

  // ---- 通道 ③：canvas 压缩（HEIC / 超大体量 / 以上均失败）----
  setWallHint("压缩中…", false);
  let pack;
  try {
    pack = await compressToBase64(file);
  } catch (e) {
    // 把解码/编码的原文 + 诊断尾部一起带到页面，禁止只说「解码失败」
    const tail = await gbDiagTail(8);
    return wallFail("图片处理失败：" + (e && e.message ? e.message : e)
      + (tail ? " ｜诊断：\n" + tail : ""));
  }
  const b64 = pack.b64;
  if (!b64) return wallFail("压缩结果为空");
  if (!HAS_KSU) {
    // 8778 端为 nc 单请求模型，读不到 POST body，无法上传文件
    setProg(null);
    setWallHint("浏览器模式（127.0.0.1:8778）无法上传图片：该通道不支持 POST。"
      + "请在 KernelSU 管理器内打开 WebUI（可直接调起系统相册选图）。", true);
    toast("浏览器模式不支持上传，请用管理器内嵌 WebUI");
    return false;
  }
  setProg(0);
  return writeBase64ToFile(b64, file);
}

/* ---- 需求：仅保留相册入口（v3.2 已移除目录选择 / 手动路径 UI）----
   后端 wall.sh 的 list / set 子命令仍保留（CLI 可用），前端不再暴露。 */



async function wallClear() {
  setWallHint("清除中…", false);
  const r = await wallSh("clear");
  const out = (r && r.stdout) ? r.stdout.trim() : "";
  if (r && r.errno === 0 && /^OK/.test(out)) {
    applyWallpaper("");
    await wallInit();
    return wallOK("壁纸已清除");
  }
  return wallFail(out || (r && r.stderr) || "未知错误");
}

/* ===================== 事件绑定 ===================== */

const elRefresh = $("#btnRefresh");
if (elRefresh) elRefresh.addEventListener("click", () => { refreshStatus({ silent: false }); refreshLog(); });
const elSave = $("#btnSave");
if (elSave) elSave.addEventListener("click", saveCfg);
const elLog = $("#btnLog");
if (elLog) elLog.addEventListener("click", refreshLog);

const elTheme = $("#btnTheme");
if (elTheme) elTheme.addEventListener("click", cycleTheme);

const elPick = $("#wallPick");
const elPickBtn = $("#btnWallPick");
/* ===================== 分页切换（v2.2.11） =====================
   首页 #page-home（状态 / 档位配置 / 日志）与 壁纸 #page-wall 是两个独立分页，
   同一时刻只显示一个（.active）。

   ⚠ 刻意【不写 location.hash、不碰 history】：
     写 hash 属于同文档导航，会往 WebView 历史栈压记录，使宿主 canGoBack() 变 true，
     表现为「系统返回键/侧滑只回退到上一个分页，而不退出 WebUI」。
     v2.2.8~v2.2.10 就是这个缺陷。现在分页状态只存内存变量 curPage，
     WebView 历史栈始终保持只有 1 条 → 系统返回/侧滑直接退出 WebUI。 */
const PAGE_IDS = { home: "page-home", wall: "page-wall" };
let curPage = "home";
function currentPageName() { return curPage; }
/* 当前实际激活的分页（用于跳过重复切换，避免多余的 wallInit(true)） */
function activePageName() {
  const w = document.getElementById(PAGE_IDS.wall);
  return (w && w.classList.contains("active")) ? "wall" : "home";
}
function showPage(name, force, skipSliderSync) {
  const want = (name === "wall") ? "wall" : "home";
  if (!force && want === activePageName()) return;
  // 1) 切页
  const home = document.getElementById(PAGE_IDS.home);
  const wall = document.getElementById(PAGE_IDS.wall);
  if (home) home.classList.toggle("active", want === "home");
  if (wall) wall.classList.toggle("active", want === "wall");
  // 2) 底栏高亮（当前分页）
  const nb = document.getElementById("btnNavHome");
  const nw = document.getElementById("btnNavWall");
  if (nb) nb.classList.toggle("active", want === "home");
  if (nw) nw.classList.toggle("active", want === "wall");
  // 3) 标题
  try { document.title = (want === "wall") ? "壁纸设置 · G750 Boost" : "G750 Boost"; } catch (e) {}
  try { window.scrollTo(0, 0); } catch (e) {}
  // 4) 进入壁纸分页时同步一次滑杆值（只读 get；初始化时由调用方统一调 wallInit，避免并发 ksu.exec）
  if (want === "wall" && !skipSliderSync) wallInit(true);
  // 5) 只记内存状态，不产生任何历史记录
  curPage = want;
}

function openPicker() {
  // 点「选择壁纸」即新建诊断会话：即使后续连 change 都没触发（宿主没回调），
  // 也能从日志判断「按钮点了但选择器没起来」还是「选了图但处理失败」。
  gbDiagReset();
  gbDiag("openPicker() 已触发（等待 file chooser 回调）");
  if (elPick && typeof elPick.click === "function") {
    try { elPick.click(); }
    catch (e) { gbDiag("elPick.click() 抛错: " + ((e && e.message) || e)); toast("无法唤起选择器：" + ((e && e.message) || e)); }
  } else {
    gbDiag("elPick 不存在 → 宿主不支持 file input");
    toast("当前宿主不支持文件选择");
  }
}
if (elPickBtn) elPickBtn.addEventListener("click", openPicker);

/* v2.2.11：底栏导航 —— 首页 / 壁纸是分页切换（高亮当前页），刷新 / 主题是动作。
   全部只改内存状态，不写 hash / 不压历史栈 → 系统返回键直接退出 WebUI */
const elNavHome = $("#btnNavHome");
const elNavWall = $("#btnNavWall");
if (elNavHome) elNavHome.addEventListener("click", () => { showPage("home", true); });
if (elNavWall) elNavWall.addEventListener("click", () => { showPage("wall", true); });
// 壁纸分页内的「‹ 返回」按钮
const elWallBack = $("#btnWallBack");
if (elWallBack) elWallBack.addEventListener("click", () => { showPage("home", true); });

/* ⚠ 刻意不注册 hashchange / popstate：
   注册它们意味着依赖历史栈，而我们要的正是「返回键直接退出」。
   Esc 仅用于桌面键盘宿主，切回首页，同样不碰历史。 */
window.addEventListener("keydown", (e) => {
  if (e && e.key === "Escape" && currentPageName() === "wall") showPage("home", true);
});

if (elPick) {
  elPick.addEventListener("change", async (e) => {
    const f = e.target.files && e.target.files[0];
    gbDiag("change 事件：files=" + ((e.target.files && e.target.files.length) || 0) + " 有文件=" + !!f);
    if (!f) return;                       // 用户取消 → 静默返回，不算失败
    await persistWallFromFile(f);
    // 清空 value，允许重复选择同一文件
    try { elPick.value = ""; } catch (err) {}
  });
}

const elOp = $("#wallOpacity");
if (elOp) {
  elOp.addEventListener("input", (e) => { applyWallOpacity(e.target.value); });   // 实时预览
  elOp.addEventListener("change", async (e) => {                                   // 松手持久化
    const v = Math.max(0, Math.min(100, numOr(e.target.value, 35)));
    applyWallOpacity(v);        // v2.2.9：先落到内存变量，保证 saveSliderCache 取到新值
    const r = await wallSh("opacity", String(v));
    const out = (r && r.stdout) ? r.stdout.trim() : "";
    if (!(r && r.errno === 0 && /^OK/.test(out))) {
      setWallHint("透明度持久化失败：" + (out || (r && r.stderr) || "未知错误"), true);
      toast("透明度保存失败");
    } else {
      setWallHint("透明度已保存 " + v + "%", false);
      saveSliderCache();          // v2.2.9：同步 localStorage，下次首屏直接用真实值
    }
  });
}

/* 液态玻璃透明度滑杆：实时预览 + 松手持久化（wall_glass） */
const elGlass = $("#glassOpacity");
if (elGlass) {
  elGlass.addEventListener("input", (e) => { applyGlass(e.target.value); });
  elGlass.addEventListener("change", async (e) => {
    const v = Math.max(0, Math.min(100, numOr(e.target.value, 50)));
    applyGlass(v);              // v2.2.9：先落到内存变量
    const r = await wallSh("glass", String(v));
    const out = (r && r.stdout) ? r.stdout.trim() : "";
    if (!(r && r.errno === 0 && /^OK/.test(out))) {
      setWallHint("玻璃透明度持久化失败：" + (out || (r && r.stderr) || "未知错误"), true);
      toast("玻璃透明度保存失败");
    } else {
      setWallHint("玻璃透明度已保存 " + v + "%", false);
      saveSliderCache();          // v2.2.9：同步 localStorage
    }
  });
}

/* 玻璃模糊滑杆：实时预览 + 松手持久化（wall_blur） */
const elBlur = $("#glassBlur");
if (elBlur) {
  elBlur.addEventListener("input", (e) => { applyBlur(e.target.value); });
  elBlur.addEventListener("change", async (e) => {
    const v = Math.max(0, Math.min(40, numOr(e.target.value, 24)));
    applyBlur(v);               // v2.2.9：先落到内存变量
    const r = await wallSh("blur", String(v));
    const out = (r && r.stdout) ? r.stdout.trim() : "";
    if (!(r && r.errno === 0 && /^OK/.test(out))) {
      setWallHint("玻璃模糊持久化失败：" + (out || (r && r.stderr) || "未知错误"), true);
      toast("玻璃模糊保存失败");
    } else {
      setWallHint("玻璃模糊已保存 " + v + "px", false);
      saveSliderCache();          // v2.2.9：同步 localStorage
    }
  });
}

const elList = null, elApply = null;   // v3.2：目录/手输入口已移除
const elClear = $("#btnWallClear");
if (elClear) elClear.addEventListener("click", wallClear);

setInterval(() => { if (!document.hidden) { refreshStatus({ silent: true }); refreshLog(); } }, 4000);

if (!HAS_KSU) {
  document.body.insertAdjacentHTML("afterbegin",
    '<div class="modebar browser">浏览器模式 · 经 127.0.0.1:8778（选壁纸请到 KernelSU 管理器内打开 WebUI）</div>');
}

/* 初始化：顺序经过优化，目标是【首屏尽快出壁纸】
   v2.2.6 关键改动：先本地预热（0 延迟），再并行拉取配置；
   原先 wallInit() 排在最后并且内部要等 get 返回才设置壁纸 URL，
   导致首屏要等 ~1s 才开始请求图片。
   v2.2.11：分页启动恒为首页（不再按 hash 决定），且不产生任何历史记录。 */
applyWallOpacity(wallOp);
applyGlass(wallGlass);
applyBlur(wallBlur);
primeWallFromCache();          // ← 立即用缓存显示壁纸（无网络/无 shell 等待）
showPage("home", true, true);  // 恒从首页开始（不读 hash、不压历史）
loadConfig();
refreshStatus({ silent: false });
refreshLog();
wallInit();                    // get 回来后校正（mtime 未变则跳过重复加载）+ 同步三个滑杆
