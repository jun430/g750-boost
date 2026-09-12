/* G750 Boost main.js v2.0.0 — WebUI 主通道:
   KSU 内嵌通道优先（ksu.exec），浏览器降级 127.0.0.1:8778 */
"use strict";
const MOD_CANDIDATES = ["/data/adb/modules/g750-boost", "/data/adb/modules_update/g750-boost"];
const CGI_BASE = "http://127.0.0.1:8778";
const HAS_KSU = (typeof ksu !== "undefined" && ksu && ksu.exec);
let MODPATH = null;
let cbCount = 0;

function ksuExecAsync(cmd) {
  return new Promise((resolve) => {
    const cb = `gb_cb_${Date.now()}_${cbCount++}`;
    window[cb] = (errno, stdout, stderr) => { resolve({ errno, stdout, stderr }); delete window[cb]; };
    try { ksu.exec(cmd, "{}", cb); } catch (e) { delete window[cb]; resolve({ errno: 1, stdout: "", stderr: String(e) }); }
  });
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
  const rel = cmd.replace(/^sh\s+\/data\/adb\/modules[_update]*\/g750-boost\//, "");
  const m = rel.match(/^cgi\/([\w.]+\.sh)\s*(.*)$/);
  const script = m ? m[1] : "status.sh";
  const args = m && m[2].trim() ? "?" + m[2].trim().split(/\s+/).map(a => encodeURIComponent(a)).join("&") : "";
  const url = CGI_BASE + "/cgi-bin/" + script + args;
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
function fmtMHz(v) { return (v === undefined || v === null || v === "" || v === 0) ? "-- MHz" : (v + " MHz"); }

async function refreshStatus({ silent = true } = {}) {
  try {
    const j = JSON.parse(await (await sh("sh __MODPATH__/cgi/status.sh")).stdout);
    $("#sPlatform").textContent = j.platform || "--";
    $("#sLiveFloor").textContent = fmtMHz(j.live_floor);
    $("#sFloor").textContent = fmtMHz(j.floor_mhz);
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
    $("#sLiveFloor").style.color = (j.game === "yes" && j.live_floor === j.floor_mhz) ? "var(--acc)" : "";
  } catch (e) { if (!silent) toast("刷新失败: " + e.message); }
}

async function loadConfig() {
  try {
    const j = JSON.parse(await (await sh("sh __MODPATH__/cgi/config.sh")).stdout);
    const sel = $("#selFloor");
    if (sel && Array.isArray(j.freqs) && j.freqs.length) {
      sel.innerHTML = "";
      for (const f of j.freqs) {
        const o = document.createElement("option");
        o.value = f;
        o.textContent = f + " MHz";
        if (f == j.floor) o.selected = true;
        sel.appendChild(o);
      }
      $("#saveHint").textContent = "当前目标：" + j.floor + " MHz";
    }
  } catch (e) { console.log("loadConfig failed: " + e); }
}

async function saveFloor() {
  const sel = $("#selFloor");
  if (!sel) return;
  const val = sel.value;
  const r = await sh("sh __MODPATH__/cgi/config.sh save " + val);
  let ok = false, floor = val;
  try { const j = JSON.parse(r.stdout); ok = !!j.ok; floor = j.floor || val; } catch (e) {}
  if (ok) {
    $("#saveHint").textContent = "已保存目标档位 " + floor + " MHz（5 秒内生效）";
    toast("已保存 " + floor + " MHz");
  } else {
    $("#saveHint").textContent = "保存失败，请重试";
    toast("保存失败");
  }
  await refreshStatus({ silent: true });
}

async function refreshLog() {
  try {
    const t = await (await sh("sh __MODPATH__/cgi/log.sh")).stdout;
    const el = $("#logView");
    el.textContent = t || "(空)";
    el.scrollTop = el.scrollHeight;
  } catch (e) { $("#logView").textContent = "读取失败: " + e.message; }
}

$("#btnRefresh").addEventListener("click", () => { refreshStatus({ silent: false }); refreshLog(); });
$("#btnSave").addEventListener("click", saveFloor);
$("#btnLog").addEventListener("click", refreshLog);
setInterval(() => { if (!document.hidden) { refreshStatus({ silent: true }); refreshLog(); } }, 4000);
if (!HAS_KSU) {
  document.body.insertAdjacentHTML("afterbegin",
    '<div style="background:#12331f;color:#8fe8b0;padding:8px;font-size:12px;text-align:center">浏览器模式 · 经 127.0.0.1:8778</div>');
}
loadConfig();
refreshStatus({ silent: false });
refreshLog();