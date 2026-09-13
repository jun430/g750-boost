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
  // 浏览器降级通道：必须先做同样的路径替换。
  // 否则 __MODPATH__ 原样残留 → 下面的正则匹配失败 → 所有调用
  // （包括 config.sh 的读/存）都会被静默降级成 status.sh，
  // 表现为"下拉框没有档位 / 保存了但没生效"。
  const flat = cmd.replace(/__MODPATH__/g, MOD_CANDIDATES[0]);
  const rel = flat.replace(/^sh\s+\/data\/adb\/modules[_update]*\/g750-boost\//, "");
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
  const floor = selF.value;
  const ceil = selC ? selC.value : 0;
  const r = await sh("sh __MODPATH__/cgi/config.sh save " + floor + " " + ceil);
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
$("#btnSave").addEventListener("click", saveCfg);
$("#btnLog").addEventListener("click", refreshLog);
setInterval(() => { if (!document.hidden) { refreshStatus({ silent: true }); refreshLog(); } }, 4000);
if (!HAS_KSU) {
  document.body.insertAdjacentHTML("afterbegin",
    '<div style="background:#12331f;color:#8fe8b0;padding:8px;font-size:12px;text-align:center">浏览器模式 · 经 127.0.0.1:8778</div>');
}
loadConfig();
refreshStatus({ silent: false });
refreshLog();