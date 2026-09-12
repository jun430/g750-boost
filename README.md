# G750 Boost — 游戏 GPU 地板档位模块

**作者**: 雨色  
**版本**: v2.1.1  
**适配**: SM8650 (8 Gen3 / Adreno750) · SM8750 (8 Elite / Adreno830) · SM8850 (8 Elite Gen5 / Adreno840)

---

## 一句话介绍

游戏中把 GPU 地板抬到你设置的档位（默认 680MHz）并锁住上限，系统 governor 在地板以上自由调频；退出游戏 8 秒后自动恢复。

## v2.1.1 新特性

- ✅ **三通道地板接管**：`min_pwrlevel`（档位）+ `devfreq/min_freq`（Hz）+ `/sys/kernel/gpu/gpu_min_clock`（MHz）同步写入，覆盖 8g3 / 8e5 全部节点布局
- ✅ **上限常驻保护**：`max_pwrlevel` / `max_gpuclk` / `gpu_max_clock` / `max_freq` 四路护栏，防止游戏或原厂栈拉低上限
- ✅ **游戏运行 1 秒校验**（原 5 秒），压制原厂游戏栈（`opgs_daemon` 等）的抢写
- ✅ **写后回读自检**：被驱动丢弃时输出 `WARN floor write rejected`
- ✅ **节点不存在自动跳过**：8e5 无 devfreq 节点时零空转
- ✅ **monitor 进程树治理**：重启不再累积孤儿进程（原每次 +2）
- ✅ **空变量写保护**：节点路径缺失时拒绝写入，防止误写根目录
- ✅ **WebUI 面板**：状态 / 档位自定义 / 实时日志

## v2.0.0 特性（历史）

- min_pwrlevel 档位接管（实测 13 分钟+ 不被系统覆盖，对比 min_freq 几秒即被覆盖）
- 三平台自适配 + 按处理器平台区分安装
- 双事件监听（am_proc_start 启动 + am_proc_died 退出 + 校验兜底）
- 异常残留自清理（上次崩溃残留的档位，启动时自动恢复）

## 工作原理

```text
游戏启动  → 三通道同步写入地板：
              min_pwrlevel（档位号）
              devfreq/min_freq（Hz，节点存在时）
              /sys/kernel/gpu/gpu_min_clock（MHz，节点存在时）
游戏运行  → 每 1 秒只读校验，偏离才重写；governor 在地板以上自由调频
            同时守卫上限：max_pwrlevel / max_gpuclk / gpu_max_clock / max_freq
游戏退出  → 8 秒迟滞 → 恢复系统默认档位（num_pwrlevels-1）
```

## 使用场景

| 场景 | GPU 地板 |
|---|---|
| 王者荣耀 / 永劫无间运行中（前台/后台/小窗） | 目标档位（默认 680MHz） |
| 所有目标游戏退出后 | 系统默认（约 231MHz） |

## 安装

```text
1. KernelSU / Magisk / APatch 中安装 zip
2. 重启生效
3. WebUI: http://127.0.0.1:8778（管理器内嵌通道或浏览器）
```

## WebUI

- **状态**：平台 / 实际地板 / 目标档位 / 当前频率 / 实际上限 / 游戏状态 / 温度
- **档位**：下拉选择目标频率 → 保存（5 秒内生效）
- **日志**：实时查看运行日志

## 修改游戏白名单

编辑 `/data/adb/modules/g750-boost/games.txt`，一行一个包名（建议末尾留空行）。

## 日志

```text
/data/adb/modules/g750-boost/boost.log
```

## 技术细节

### 接管通道（地板）

| 通道 | 节点 | 单位 | 8g3 | 8e5 | 说明 |
|---|---|---|---|---|---|
| 主 | `/sys/class/kgsl/kgsl-3d0/min_pwrlevel` | 档位号 | ✅ | ✅ | 最可靠，实测长时间不被覆盖 |
| 软下限 | `<kgsl>/devfreq/min_freq` | Hz | ✅ | ❌ 无节点 | 第三方调频 App 走这里，必须同步 |
| 内核 | `/sys/kernel/gpu/gpu_min_clock` | MHz | ✅ | ✅ | msm_perf / 性能工具常用接口 |

> 8e5 (SM8850) 上 `devfreq` 设备虽注册但**无频率节点**（gen8 把调频决策移到 GMU DCVS，
> 且 DCVS 节点全部只读）。代码按"节点文件存在"探测，不存在自动跳过，无空写。
> `min_pwrlevel` / `min_clock_mhz` / `gpu_min_clock` 在 8e5 上指向**同一后端**，写一个另两个跟随。

### 上限护栏

| 节点 | 单位 | 8g3 | 8e5 |
|---|---|---|---|
| `max_pwrlevel` | 档位号 | ✅ | ✅ |
| `max_gpuclk` | Hz | ✅ | ✅ |
| `/sys/kernel/gpu/gpu_max_clock` | MHz | ✅ | ✅ |
| `<kgsl>/devfreq/max_freq` | Hz | ✅ | ❌ 无节点 |

### 档位映射

`available_frequencies`（倒序）的 index = pwrlevel。目标频率 → 选择 ≥ 目标的最小档位（如 700 → 720）。

### 恢复保证

- 启动保存系统默认档位（num_pwrlevels-1）
- 退出 / 禁用 / 卸载 / 异常（trap）全部恢复
- 崩溃残留：下次启动自动清理

## 平台档位表参考

| 平台 | 档位表（MHz） |
|---|---|
| SM8650 | 903 / 834 / 770 / 720 / 680 / 629 / 578 / 500 / 422 / 366 / 310 / 231 |
| SM8850 (8e5) | 1200 / 1050 / 967 / 902 / 826 / 726 / 646 / 578 / 539 / 500 / 461 / 422 / 382 / 342 / 282 / 222 / 191 / 160 |
| SM8750 | 运行时自动读取 |

## 更新日志

### v2.1.1 (2026-09-13)
- 三通道地板接管（min_pwrlevel / devfreq min_freq / kernel gpu_min_clock）
- 上限四路护栏（max_pwrlevel / max_gpuclk / gpu_max_clock / max_freq）
- 游戏运行 1 秒校验 + 写后回读自检
- 修复：节点缺失时可能误写根目录（空变量写保护）
- 修复：proc_monitor 进程树泄漏（重启累积孤儿进程）
- 修复：启动 banner 版本号与 module.prop 不一致
- 8e5 (SM8850) 全节点实测定稿：devfreq 空壳、GMU DCVS 只读，均自动跳过

### v2.1.0 (2026-09-13)
- 新增上限档位接管（max_pwrlevel）+ WebUI 上限下拉
- 频率表多路径读取（freq / level 双模式）+ 单位归一化

### v2.0.0 (2026-09-12)
- 重构：min_pwrlevel 档位接管（替代 min_freq 主通道）
- 三平台自适配与安全模式
- WebUI 档位自定义
- 双事件监听（start + died）
- 异常残留自清理

### v1.3.1
- am_proc_start 事件监听 + 精确匹配
- games.txt 末行无换行修复

### v1.2.0
- 纯进程检测（前台/后台/小窗一致）

---

**License**: MIT  
**作者**: 雨色