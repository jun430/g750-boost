# G750 Boost — Snapdragon GPU Game Floor Module

**Author**: 雨色
**Version**: v2.1.4
**Supported SoCs**: SM8650 (8 Gen3 / Adreno 750) · SM8750 (8 Elite / Adreno 830) · SM8850 (8 Elite Gen5 / Adreno 840)
**Compatible with**: KernelSU / Magisk / APatch

---

## One-line summary

**While a target game is running, raise the GPU minimum frequency (floor) to your chosen level, lock the maximum frequency (ceiling) so nothing can pull it down, and let the system governor scale freely in between. Restore the system default 8 seconds after the game exits.**

---

## Key concept: you set the FLOOR, not the ceiling

```text
             Maximum frequency (guarded, e.g. 903 MHz)
                    ▲
                    │   ← system governor scales freely in this range
                    │       (climbs up under load)
   your setting ────┼───  ← module only raises the FLOOR here (e.g. 680 MHz)
                    │
                    │   ← system may drop lower when idle
             Minimum frequency
```

- ✅ You set the **minimum frequency (floor)**
- ✅ The maximum frequency is **guarded** (no game / module can lower it)
- ✅ The system governor scales freely **above** the floor

| Scenario | Effect |
|---|---|
| Idle / no game | Default floor restored (~231 / 160 MHz) |
| Game running (foreground/background/floating window) | Floor raised to target, ceiling guarded, governor scales up automatically |

**No frequency is locked** — this is exactly the "auto-scale above the floor" design goal: no frame drops from downclocking, no wasted power.

---

## Why it exists

Qualcomm's GPU governor (`msm-adreno-tz`) aggressively downclocks the GPU to save power. In games this causes frame-time jitter and occasional stutters. This module raises the GPU **floor** only while a target game runs, and guards the ceiling against vendor game stacks that rewrite it.

---

## v2.1.4 highlights

| Feature | Description |
|---|---|
| **WebUI level-snapping (fix)** | The dropdown now highlights options **by level index**. Previously it matched by MHz value — when the configured value was absent from the device table (e.g. the default `680` on 8e5), **no option matched and the browser silently selected the first one (= highest frequency)**, pinning the floor to 1200 MHz on save |
| **Snap on save** | Values pass through `gb_map_floor` / `gb_map_ceil` before being written, so **the stored value is always a real device level** and will always match next time |
| **Effective value reported** | The UI shows the **effective value + level index** instead of the raw request; snapping/clamping is called out; the form re-reads after saving |
| **Browser fallback channel fixed** | `main.js: sh()` did not substitute `__MODPATH__` on the non-KSU path, so the path regex failed and **`config.sh` reads/writes were silently downgraded to `status.sh`** (empty dropdown, saves that did nothing) |
| **Unified frequency-table ordering (cross-SoC)** | `available_frequencies` is not guaranteed to be descending (devfreq tables are often ascending). Now normalised with `sort -nr` so **index 0 = highest frequency = pwrlevel 0**, plus an entry-count check against `num_pwrlevels` |
| **Window consistency guard** | If the ceiling level is higher than the floor level (empty range), the floor is aligned to the ceiling (equivalent to frequency locking), with an explicit notice |
| **New status row: Floor level n / N** | Shows the hardware `min_pwrlevel` directly |

## v2.1.3 highlights

| Feature | Description |
|---|---|
| **Event-driven game detection** | `proc_monitor.sh` listens to `am_proc_start` / `am_proc_died` and writes `state/game_proc`; the main loop reads that state instead of running `pidof` every cycle |
| **Startup fallback scan kept** | A target game already running at boot is still detected |
| **Unified package-name source in WebUI** | Status / config / log all read `state/game_proc` |

## v2.1.2 highlights

| Feature | Description |
|---|---|
| **Platform-aware installer probe** | Installer reuses the runtime engine (`lib/platform.sh`); on 8e5 it no longer falsely reports "no KGSL node" — devfreq shell is explained as normal (GMU DCVS) |
| **Zero-fork hot path** | Node reads/writes, config parsing and PID checks use shell builtins only (`read`/`echo`/`$SECONDS`); in-game poll unified at **0.3 s** (measured ~73 µs per cycle incl. all 6 guards → CPU < 0.02%, still cheaper than the old 1 s loop with ~30 forks) |
| **Ceiling guard at the same rate** | `max_pwrlevel` / `max_freq` / `max_gpuclk` / `gpu_max_clock` all checked every 0.3 s — a lowered ceiling is restored within 0.3 s |
| **Write-on-change state files** | `state/` files are only written when targets change (less IO at 0.3 s cadence) |
| **WebUI footer version fixed** | |

## v2.1.1 highlights

| Feature | Description |
|---|---|
| **Three-channel floor takeover** | `min_pwrlevel` (level) + `devfreq/min_freq` (Hz) + `/sys/kernel/gpu/gpu_min_clock` (MHz) written together, covering every node layout on 8g3 / 8e5 |
| **Ceiling guard (4 nodes)** | `max_pwrlevel` / `max_gpuclk` / `/sys/kernel/gpu/gpu_max_clock` / `devfreq/max_freq` |
| **1-second check in game** | Suppresses the vendor game stack (`opgs_daemon` etc.) that rewrites the floor |
| **Write-back self-check** | Logs `WARN floor write rejected` if the driver drops the write |
| **Missing nodes auto-skip** | Zero no-op writes (8e5 has no usable devfreq frequency nodes) |
| **Monitor process-tree cleanup** | No more orphan accumulation across restarts |
| **Empty-variable write guard** | Refuses to write when a node path is empty (prevents stray root-directory files) |
| **Three-SoC autodetect** | SM8650 / SM8750 / SM8850, runtime-detected, no hardcoding |
| **WebUI** | Status panel / floor dropdown / ceiling dropdown / live log |

---

## How it works

```text
  proc_monitor.sh (separate process)      service.sh (main daemon, poll loop)
  ┌───────────────────────────┐           ┌──────────────────────────────┐
  │ logcat -b events          │  events   │ 1. verify target PID alive    │
  │  ├─ am_proc_start → PID    │ ────────► │ 2. game running → write floor │
  │  └─ am_proc_died  → time   │           │ 3. 1s read-only check          │
  └───────────────────────────┘           │ 4. guard ceiling each cycle    │
                                          │ 5. exit 8s → restore default  │
                                          └───────────────┬──────────────┘
                                                          │
                  ┌───────────────────────────────────────▼──────────────────────────┐
                  │ /sys/class/kgsl/kgsl-3d0/min_pwrlevel      (level)                │
                  │ /sys/class/kgsl/kgsl-3d0/devfreq/min_freq  (Hz,  8g3 only)        │
                  │ /sys/kernel/gpu/gpu_min_clock              (MHz)                  │
                  └──────────────────────────────────────────────────────────────────┘
```

### Takeover channels (floor)

| Channel | Node | Unit | 8g3 | 8e5 | Notes |
|---|---|---|---|---|---|
| Primary | `/sys/class/kgsl/kgsl-3d0/min_pwrlevel` | level | ✅ | ✅ | Most reliable; never observed being overridden |
| Soft floor | `<kgsl>/devfreq/min_freq` | Hz | ✅ | ❌ node absent | Third-party tuners (Scene etc.) write here |
| Kernel | `/sys/kernel/gpu/gpu_min_clock` | MHz | ✅ | ✅ | Common `msm_perf` / tuning-tool interface |

> On 8e5 (SM8850) the `devfreq` device is registered but exposes **no frequency nodes** (gen8 moved
> clock decisions into GMU DCVS, and all DCVS nodes are read-only). The module probes for the **node file**,
> not the directory, so it skips automatically with zero no-op writes.
> `min_pwrlevel` / `min_clock_mhz` / `gpu_min_clock` are three views of the **same backend** on 8e5.

### Ceiling guard

| Node | Unit | 8g3 | 8e5 |
|---|---|---|---|
| `max_pwrlevel` | level | ✅ | ✅ |
| `max_gpuclk` | Hz | ✅ | ✅ |
| `/sys/kernel/gpu/gpu_max_clock` | MHz | ✅ | ✅ |
| `<kgsl>/devfreq/max_freq` | Hz | ✅ | ❌ node absent |

---

## Install

```text
1. Flash g750-boost_v2.1.4.zip in KernelSU / Magisk / APatch
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
Floor level  4 / 11      ← hardware min_pwrlevel
Target      680 MHz     ← your configured floor
Current     720 MHz     ← real-time GPU frequency
Max         903 MHz     ← ceiling (guarded)
Game        playing · com.netease.l22
Temp        45 °C
```

### Setting

```text
[Dropdown] Target floor:   903 / 834 / 770 / 720 / 680 / 629 / ... / 231 MHz
[Dropdown] Ceiling:        0 = unlimited / or an explicit frequency
[Save]     → snapped to a real device level → written → applied within 0.3 s while a game runs
```

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
| SM8750 (8 Elite) | Adreno 830 | ~1100 | read at runtime |
| SM8850 (8 Elite Gen5) | Adreno 840 | 1200 | 1200 / 1050 / 967 / 902 / 826 / 726 / 646 / 578 / 539 / 500 / 461 / 422 / 382 / 342 / 282 / 222 / 191 / 160 |

> The module **always uses the device's runtime frequency table** (`available_frequencies` /
> `gpu_available_frequencies`); the table above is for reference only.

### Floor mapping rule

### Frequency-table normalisation

`available_frequencies` ordering is **not guaranteed** across SoCs (devfreq tables are often ascending).
The module normalises the table to **descending** order so that `index 0` always means the highest
frequency = `pwrlevel 0`, and cross-checks the entry count against `num_pwrlevels`.

### Floor mapping rule

If the target frequency has no exact entry:

- **Floor**: pick the **smallest entry ≥ target** (performance-leaning)
- **Ceiling**: pick the **largest entry ≤ target** (never above what you asked for)

The **snapped** value is what gets written to the config, so the WebUI always displays a real device level.

```text
Example: floor 700 MHz → no exact entry → 720 MHz (smallest ≥ 700)
         ceiling 400 MHz → no exact entry → 366 MHz (largest ≤ 400)
```

---

## Technical details

- **Floor channels**: `min_pwrlevel` (primary) · `devfreq/min_freq` (soft, 8g3) · `/sys/kernel/gpu/gpu_min_clock`
- **Ceiling guard**: `max_pwrlevel` · `max_gpuclk` · `/sys/kernel/gpu/gpu_max_clock` · `devfreq/max_freq`
- **Floor index**: `level = index in the frequency table` (descending; smaller index = higher floor)
- **In-game check interval**: 0.3 s (zero-fork builtins; writes only when the value drifts)
- **Process management**: monitor process tree is cleaned on start and on exit — no orphan accumulation
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
A: Minimum (floor). The ceiling is guarded but never lowered below your setting; the governor scales above the floor.

**Q: Does it raise power consumption a lot?**
A: Only while a target game runs; restored on exit. The floor is adjustable in the WebUI.

**Q: Why does "Current" frequency change?**
A: That is the governor's real-time scaling, which is normal. As long as "Live floor" equals your target, it is working.

**Q: The status panel shows a different floor than a third-party tuning app. Why?**
A: Those apps usually read `devfreq/min_freq` only, while the module reads `min_pwrlevel`. KGSL does not
synchronise the two views automatically, so the module writes both (plus `/sys/kernel/gpu`). Values now match.

**Q: Does switching to a WeChat floating window drop the floor?**
A: No. As long as the target game process exists, the floor is held; the 8-second hysteresis only detects a real exit.

**Q: Non-Snapdragon devices?**
A: Not supported. This module targets Qualcomm Adreno KGSL.

---

## License

**MIT** — **Author**: 雨色

> For personal device tuning and research use only. Use at your own risk.
