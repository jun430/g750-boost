# G750 Boost — Snapdragon GPU Game Floor Module

**Author**: 雨色
**Version**: v2.0.0
**Supported SoCs**: SM8650 (8 Gen3 / Adreno 750) · SM8750 (8 Elite / Adreno 830) · SM8850 (8 Elite Gen5 / Adreno 840)
**Compatible with**: KernelSU / Magisk / APatch

---

## One-line summary

**While a target game is running, raise the GPU minimum frequency (floor) to your chosen level, keep the maximum frequency unchanged, and let the system governor scale freely in between. Restore the system default 8 seconds after the game exits.**

---

## Key concept: you set the FLOOR, not the ceiling

```text
             Maximum frequency (untouched, e.g. 903 MHz)
                    ▲
                    │   ← system governor scales freely in this range
                    │       (climbs up under load)
   your setting ────┼───  ← module only raises the FLOOR here (e.g. 680 MHz)
                    │
                    │   ← system may drop lower when idle
             Minimum frequency
```

- ✅ You set the **minimum frequency (floor)**
- ✅ Maximum frequency stays **unchanged**
- ✅ The system governor scales freely **above** the floor

| Scenario | Effect |
|---|---|
| Idle / no game | Default floor restored (~231 / 160 MHz) |
| Game running (foreground/background/floating window) | Floor raised to target, ceiling unchanged, governor scales up automatically |

**No frequency is locked** — this is exactly the "auto-scale above the floor" design goal: no frame drops from downclocking, no wasted power.

---

## Why it exists

Qualcomm's GPU governor (`msm-adreno-tz`) aggressively downclocks the GPU to save power. In games this causes frame-time jitter and occasional stutters. This module raises the GPU **floor** only while a target game runs, without touching the ceiling.

---

## v2.0.0 highlights

| Feature | Description |
|---|---|
| **min_pwrlevel takeover** | Uses a lower-level KGSL pwrlevel interface; measured 13+ min with zero override (vs `min_freq` reverted within seconds) |
| **Three-SoC autodetect** | SM8650 / SM8750 / SM8850, runtime-detected, no hardcoding |
| **Per-SoC install** | Installer identifies the SoC; unsupported SoCs are rejected |
| **WebUI configurable floor** | Dropdown built from the device's real frequency table; takes effect within 5s |
| **Dual-event monitoring** | `am_proc_start` + `am_proc_died`, < 100 ms response, 5 s check as fallback |
| **Minimal overhead** | Read-only check each cycle; writes only when the value drifts |
| **Stale-state cleanup** | Recovers a floor left behind by a previous crash on startup |
| **Automatic fallback** | Falls back to `min_freq` mode when `min_pwrlevel` is unavailable |

---

## How it works

```text
  proc_monitor.sh (separate process)      service.sh (main daemon, 5s loop)
  ┌───────────────────────────┐           ┌──────────────────────────────┐
  │ logcat -b events          │  events   │ 1. verify target PID alive    │
  │  ├─ am_proc_start → PID    │ ────────► │ 2. game running → write level │
  │  └─ am_proc_died  → time   │           │ 3. read-only check each cycle │
  └───────────────────────────┘           │ 4. exit 8s → restore default  │
                                          └───────────────┬──────────────┘
                                                          │
                                          ┌───────────────▼──────────────┐
                                          │ /sys/class/kgsl/kgsl-3d0/    │
                                          │      min_pwrlevel            │
                                          └──────────────────────────────┘
```

### Takeover channel comparison (measured on OnePlus 12)

| Channel | Behavior | Verdict |
|---|---|---|
| `devfreq/min_freq` | Overridden by `msm-adreno-tz` within seconds | ❌ unreliable |
| **`min_pwrlevel`** | **13 min / 26 samples, zero override** | ✅ primary channel |

---

## Install

```text
1. Flash g750-boost_v2.0.0.zip in KernelSU / Magisk / APatch
2. Confirm with the volume key (Vol+ = install / Vol- = cancel / 15s timeout = install)
3. Reboot
4. Open WebUI: http://127.0.0.1:8778
```

The installer detects your SoC and rejects unsupported ones:

```text
- SoC: 8 Gen3 (Adreno750)
- Default floor: 680MHz (changeable in WebUI)
- Primary channel min_pwrlevel: available
```

---

## WebUI

Open `http://127.0.0.1:8778`.

### Status panel (read-only)

```text
SoC         8 Gen3 (Adreno750)
Live floor  680 MHz     ← actual kernel floor
Target      680 MHz     ← your configured floor
Current     720 MHz     ← real-time GPU frequency
Max         903 MHz     ← ceiling (unchanged)
Game        playing · com.netease.l22
Temp        45 °C
```

### Floor setting

```text
[Dropdown] Target frequency: 903 / 834 / 770 / 720 / 680 / 629 / ... / 231 MHz
           (built from your device's real frequency table)
[Save]     → write config → daemon hot-reloads within 5s
```

**Note**: this selects the **minimum frequency (floor)**; the maximum is not changed.

---

## Game whitelist

Defaults:

```text
com.tencent.tmgp.sgame     # Honor of Kings
com.netease.l22            # Naraka: Bladepoint Mobile
```

Add your own by editing `/data/adb/modules/g750-boost/games.txt` (one package per line).

---

## Platform frequency tables

| SoC | GPU | Max | Frequency table (MHz) |
|---|---|---|---|
| SM8650 (8 Gen3) | Adreno 750 | 903 | 903 / 834 / 770 / 720 / 680 / 629 / 578 / 500 / 422 / 366 / 310 / 231 |
| SM8750 (8 Elite) | Adreno 830 | 1100 | read at runtime |
| SM8850 (8 Elite Gen5) | Adreno 840 | 1200 | 1200 / 1050 / 967 / 902 / 826 / 726 / 646 / 578 / 539 / 500 / 461 / 422 / 382 / 342 / 282 / 222 / 191 / 160 |

> The module **always uses the device's runtime `available_frequencies`**; the table above is for reference only.

### Floor mapping rule

If the target frequency has no exact entry, the module picks the **smallest entry ≥ target** (performance-leaning).

```text
Example: target 700 MHz → no exact entry → 720 MHz (smallest ≥ 700)
```

---

## Technical details

- **Primary channel**: `/sys/class/kgsl/kgsl-3d0/min_pwrlevel`
- **Fallback channel**: `/sys/class/kgsl/kgsl-3d0/devfreq/min_freq`
- **Floor index**: `level = index in available_frequencies` (descending; smaller = higher floor)
- **Recovery**: default saved at start (`num_pwrlevels - 1`); restored on exit / disable / uninstall / crash (trap); stale state cleaned on next start

---

## Cross-vendor compatibility

The module relies on Qualcomm's standard KGSL sysfs interface, which is **identical across brands** (OnePlus / OPPO / realme / Xiaomi / iQOO, etc.).

Source verification (realme's official open-source org):

```text
realme GT7 Pro (SM8750):  drivers/devfreq/governor_msm_adreno_tz.c   ← same governor
realme GT8 Pro (SM8850):  qcom_base_ko.txt → msm_kgsl.ko             ← same driver
                          canoe.dtsi / sun.dtsi → qcom,kgsl-3d0@3d00000
```

Since the node is SoC-level (provided by the Qualcomm driver), the installer only checks the **SoC model** — not the brand or ROM.

---

## FAQ

**Q: Minimum or maximum frequency?**
A: Minimum (floor). The maximum is unchanged; the governor scales above the floor.

**Q: Does it raise power consumption a lot?**
A: Only while a target game runs; restored on exit. The floor is adjustable in the WebUI.

**Q: Why does "Current" frequency change?**
A: That is the governor's real-time scaling, which is normal. As long as "Live floor" equals your target, it is working.

**Q: Does switching to a WeChat floating window drop the floor?**
A: No. As long as the target game process exists, the floor is held; the 8-second hysteresis only detects a real exit.

**Q: Non-Snapdragon devices?**
A: Not supported. This module targets Qualcomm Adreno KGSL.

---

## License

**MIT** — **Author**: 雨色

> For personal device tuning and research use only. Use at your own risk.
