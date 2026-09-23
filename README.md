# G750 Boost — 游戏 GPU 地板档位模块

**作者**: 雨色  
**版本**: v2.2.11  
**适配**: SM8650 (8 Gen3 / Adreno750) · SM8750 (8 Elite / Adreno830) · SM8850 (8 Elite Gen5 / Adreno840)

---

## 一句话介绍

游戏中把 GPU 地板抬到你设置的档位（默认 680MHz）并锁住上限，系统 governor 在地板以上自由调频；退出游戏 8 秒后自动恢复。

## v2.1.6 新特性

- ✅ **修复 KernelSU 下节拍全部失效**：KernelSU 用 busybox ash 执行 service.sh，而 busybox 的 `$SECONDS` 赋值后恒为 0 不自增，导致**配置重载 / 路径探针 / 8s 迟滞 / 日志节流所有节拍全部失灵**（表现为"配置改了但地板不跟随"）。启动时检测并 `exec /system/bin/sh`（mksh）重执行自身，保留 `$SECONDS` 零 fork 优势，exec 不改 pid、置于 LOCK 之前
- ✅ **移除 proc_monitor 看护**：看护重启与 proc_monitor 自带的单实例保护互相打架——看护拉起的进程被单实例保护 `exit` 挡回，`MONITOR_PID` 永远指向已退出进程 → **无限 respawn（fail #N 风暴）**。事件源由主循环的 kill_monitor_tree + 重启管理负责，另有 5s 兜底扫描，无需看护

## v2.1.5 新特性

- ✅ **配置目标与生效值分离**：`status.sh` 新增 `cfg_floor/cfg_ceil`（读 `config/settings.conf`，非游戏态也准确）与 `state/*`（service 运行态缓存，仅游戏态刷新）两套字段，互不污染
- ✅ **WebUI 状态卡三行展示**：「配置目标 / 当前生效 / 硬件实际」——一眼看出配置没生效还是被谁改了
- ✅ **服务自愈守护**：`webdaemon.sh` 每 10s 探活 service lock pid，死亡即 `setsid` 拉起；带失败退避（前 2 次 15s、之后 60s），模块 disable/remove 时绝不拉起
- ✅ **webdaemon 独立会话**：`setsid` 脱离 service.sh 进程组，service.sh 被终端/进程组清理时 webdaemon 不陪葬，自愈守护才可靠

## v2.1.4 新特性

- ✅ **WebUI 档位选择改按下标命中**：此前前端按 **MHz 值**匹配下拉项，配置值不在设备频表时（如 8e5 上默认的 680）**一个选项都命中不了，浏览器会静默选中第一项 = 最高频**，一保存就把地板钉在 1200MHz
- ✅ **保存即吸附**：写盘前强制走 `gb_map_floor` / `gb_map_ceil`，**配置里的值必然是设备真实档位**，下次打开必然命中
- ✅ **回显生效值**：提示不再显示"请求值"，而是「生效值 + 档位号」；发生吸附 / 夹取时追加说明；保存后自动回读
- ✅ **修复浏览器降级通道**：`main.js` 的 `sh()` 在非 KSU 通道下未替换 `__MODPATH__`，路径正则失配 → **`config.sh` 的读与存被静默降级成 `status.sh`**（表现为下拉框为空、保存无效）
- ✅ **频表口径统一（跨 SoC）**：`available_frequencies` 顺序不保证降序（devfreq 表常见升序），统一 `sort -nr` 归一化，保证 **index0 = 最高频 = pwrlevel 0**，并与 `num_pwrlevels` 做条目数对齐校验
- ✅ **窗口一致性保护**：上限档位高于地板时（无解区间）自动对齐到上限档位（等效锁频），并明确提示
- ✅ **状态卡新增「地板档位 n / N」**：直接看到硬件当前的 `min_pwrlevel`

## v2.1.3 新特性

- ✅ **事件驱动游戏识别**：`proc_monitor.sh` 监听 `am_proc_start` / `am_proc_died` 写入 `state/game_proc`，主循环直接读状态，**去掉每轮的 `pidof` 轮询**
- ✅ **保留启动兜底扫描**：开机时若已有目标游戏在运行，仍能识别
- ✅ **WebUI 包名来源统一**：状态 / 配置 / 日志三处统一读 `state/game_proc`

## v2.1.2 新特性

- ✅ **安装期节点探测按实际平台路径**：复用运行时引擎 `lib/platform.sh`（多路径 + 平台自适应），8e5 安装时不再误报"未检测到 KGSL 节点"，明确提示"devfreq 空壳由 GMU DCVS 接管属正常"
- ✅ **热路径零 fork 化**：节点读写 / 配置读取 / 进程校验全部走 shell 内建（`read`/`echo`/`$SECONDS`），游戏轮询 **统一 0.3s**（实测每轮含地板+上限共 6 路校验 ≈ 73μs，CPU 占用 <0.02%，比旧版 1s 轮询的几十次 fork 还低一个量级）
- ✅ **上限护栏同频**：`max_pwrlevel` / `max_freq` / `max_gpuclk` / `gpu_max_clock` 四路同样每 0.3s 检测，其他游戏/模块拉低上限后 0.3s 内拉回
- ✅ 配置热加载 / 状态文件只在变化时写，减少 0.3s 轮询下的 IO
- ✅ 修复 WebUI 页脚版本号不一致

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
游戏运行  → 每 0.3 秒只读校验（零 fork，偏离才重写）；governor 在地板以上自由调频
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
0. 下载最新版: g750-boost_v2.2.11.zip
   https://github.com/jun430/g750-boost/releases/download/v2.2.11/g750-boost_v2.2.11.zip
1. KernelSU / Magisk / APatch 中安装 zip
2. 重启生效
3. WebUI: http://127.0.0.1:8778（管理器内嵌通道或浏览器）
```

## WebUI

- **状态**：平台 / 实际地板 / 地板档位 / 目标地板 / 目标上限 / 当前频率 / 实际上限 / 游戏状态 / 温度
- **档位**：下拉框列出**设备真实档位**（每项标注档位号）→ 保存即吸附生效（游戏运行中 0.3s 内应用；非游戏态不写地板，进游戏后生效）
- **日志**：实时查看运行日志

> 保存时会自动吸附：你选的 MHz 若不在设备频表上，会落到最近的可用档位，界面明确回显「生效值 + 档位号」。
> 配置值与设备档位不一致时，档位区会给出 ⚠ 提示。

## 当前特性 (v2.2.4)

- ✅ **壁纸可直接选相册图（root 直读，绕开 WebView 空壳）**：实测发现宿主 `SuKiSU Ultra` 的 `onShowFileChooser` → `FileChooserParams.parseResult()` 交给 WebView 的 `File` 是**空壳**（`name` 是 MediaStore 数字 `_id`、`size=0`、无字节流）→ `FileReader`/`createImageBitmap`/`createObjectURL` 三条通道全挂。v2.2.4 改用 **root 直读**：`_id` → `content query` 解析真实路径 → `cp` 进模块 → 后端 magic 校验 → 原子替换；失败再回落 `content read` 流式读取 → FileReader 直传 → canvas 压缩。**实测 11MB 相机原图直传成功，字节级一致**
- ✅ **液态玻璃透明度可调**：新增「玻璃透明度」滑杆 0–100%（越高越透），统一驱动卡片 / 日志区 / 输入框 / 底部浮动按钮的玻璃层 alpha；映射 `alpha = 1 - v/100*0.94`（100% → 0.06 近全透，0% → 1.0 全实），持久化到 `config/wall.conf` 的 `wall_glass`（默认 50）
- ✅ **壁纸透明度可调**：滑杆 0–100%，持久化 `wall_opacity`（默认 35）
- ✅ **液态玻璃浮动按钮**：3 枚彼此**独立**的圆角玻璃按钮（主题 / 壁纸 / 刷新），不连成一整条底栏
- ✅ **默认浅色主题（白底黑字）**：`light` 为默认值，并提供 `dark` / `auto`（跟随系统）三态切换，首屏同步防闪
- ✅ **缓存击穿**：`index.html` 的 `style.css`/`main.js` 带 `?v=` 版本参数，避免宿主 WebView 命中旧脚本；8778 路由同步兼容带 query 请求
- ✅ **写入链路自愈**：`ksu.exec` 全局串行化；分块写盘主用 64KB，失败自动降到 8192 整段重试
- ✅ **失败可见**：写入失败时页面直接回显**诊断尾部**（确切失败环节），无需 root 读日志；完整链路写入 `webui_debug.log`
- ✅ **路径注入防护**：外部路径参数 base64url token 化；`_id` 严格数字白名单（拒绝 `; rm -rf` / `$(id)` / 中文名等注入串）；后端 `path_ok` 三重校验 + JPEG/PNG/WEBP magic 头校验
- ✅ **`.whandler.sh` 与 `webdaemon.sh` 同步**：静态资源 / wall / 二进制 wallpaper 路由两者一致（`cmp` 逐字节 IDENTICAL），重启不被 heredoc 回滚

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

`available_frequencies` 的 index = pwrlevel。模块会先把频表**强制降序归一化**（不同 SoC / devfreq 表顺序不保证），再用 `num_pwrlevels` 做条目数对齐校验。

- **地板**：目标频率 → 选择 **≥ 目标的最小档位**（如 700 → 720）
- **上限**：目标频率 → 选择 **≤ 目标的最大档位**（如 400 → 366）
- 保存时写入的是**吸附后**的值，所以 WebUI 里显示的永远是设备真实档位

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

### v2.2.11 (2026-09-24)
- **修复「系统返回/侧滑不退出 WebUI，只回退到上一个分页」**
  - **根因**：v2.2.8 起用 `location.hash` 做分页路由。写 hash 属于**同文档导航**，每次切页都会往 WebView 历史栈压一条记录 → 宿主 `canGoBack()` 变 `true` → 返回键只回退历史、不退出。
  - **实测证据（真实浏览器，`history.length`）**：
    - 修复前：`2 → 3 → 4 → … → 16`（每次点击 +1，来回点 10 次涨到 14）
    - 修复后：`2 → 2 → 2 → … → 2`（**全程增量 0**，URL/hash 均未变）
  - **改法**：分页状态改为纯内存变量 `curPage`，**完全不碰 `history` / `location`**；同时移除 `hashchange` / `popstate` 监听（注册它们本身就意味着依赖历史栈）。
  - 效果：WebView 历史栈始终保持 1 条 → `canGoBack()=false` → **系统返回键 / 侧滑直接退出 WebUI**。
  - 副作用（有意为之）：不再支持 `#wall` 深链，启动恒为首页。
- **修复 `http://127.0.0.1:8778/?v=xxx` 打开 404**：`case` 里 `/` 是精确匹配，带 query 的根路径落到 `*)` 分支返回 404。补 `/'?'*` 通配。
- 保留 v2.2.10 的 `nc -lk` 并发修复（3 路并发 3/3、8 路 8/8）。

### v2.2.10 (2026-09-24)
- **修复 8778 并发缺陷**：原来用 `busybox nc -l -p 8778 -e handler`，nc 只处理 1 个连接就退出，`while` 循环重新监听之间存在空档 → 浏览器并发请求 `index.html + style.css + main.js` 时后两个被拒（`curl code=000`），页面**裸奔无样式**。
  - 改法：`nc -l` → **`nc -lk`**（`-k` = persistent，监听不退出，每连接派生处理进程）
  - 实测：3 路并发 **3/3 → 200**；8 路并发（含 11MB 图片与 CGI）**8/8 → 200**；无僵尸进程累积

### v2.2.9 (2026-09-24)
- **修复「壁纸透明度调了还是有遮挡」**：定位到**三层**叠加遮挡，逐一修掉
  1. **`body` 自身背景盖住壁纸层**（真凶）：壁纸层是 `body::before { z-index:-1 }`，而 `body` 自己有 `background: radial-gradient(...)` + `background-color`，会把壁纸压在下面 → 把背景**移到 `html`**（canvas 层），`body` 改为 `background: transparent`
  2. **卡片磨砂硬编码**：`.card` 写死 `backdrop-filter: blur(8px)`，**完全不听「玻璃模糊」滑杆** → 改为跟随滑杆 `--glassBlurCard = --glassBlur × 0.1`（默认 24px → **2.4px**，约 10%；调 0 → 卡片彻底清晰）
  3. **残留白底**：`select` 用 `calc(glassA + .25)`、`.logview` 用 `calc(glassA + .18)` → 玻璃 100%（alpha=0）时**仍残留 25%/18% 白底**。改为按比例派生 `--glassA-strong=glassA×1.5` / `--glassA-soft=glassA×1.36`，alpha=0 时**真正全透**
  - 兼容性：默认值（玻璃 50%）下观感与旧版**完全一致**（0.5×1.5=0.75、0.5×1.36=0.68，与原 `+0.25`/`+0.18` 结果相同）
- **修复「滑杆配置首屏闪跳」**：配置本身早已持久化在 `config/wall.conf`（重启不丢），但前端首屏只能等 `wall.sh get`（约 0.3s）才知道真实值，期间用默认 35/50/24 渲染 → 会闪一下。
  - localStorage 缓存（`gb_wall_cache_v1`）扩展为**同时保存三个滑杆值**（`op`/`gl`/`bl`）
  - `saveWallCache()` 改为**合并写入**（patch 形式），滑杆值与 `present`/`mtime` 互不覆盖
  - 新增 `saveSliderCache()`，在 **`wallInit` 同步 + 三个滑杆保存成功**后各写一次
  - 首屏顺序：先用缓存值渲染滑杆 → 再用缓存 mtime 显示壁纸 → `get` 回来校正
- 版本一致性：`GB_BUILD` / `index.html` 资源 `?v=` / `module.prop` 三处同步

### v2.2.8 (2026-09-24)
- **壁纸设置改为独立分页**（修正 v2.2.7 的弹层实现）：底栏「壁纸」按钮现在**整页切换**到壁纸设置分页，不再是覆盖式弹层
  - 分页结构：`#page-home`（状态 + 档位配置 + 日志）/ `#page-wall`（壁纸设置）
  - 底部导航 4 枚：**首页 / 壁纸**（分页切换，当前页高亮）/ **刷新 / 主题**（动作）
  - 路由用 `location.hash`（`#home` / `#wall`）：**系统返回键回上一分页**，不会退出 WebUI
  - 壁纸分页内有「‹ 返回」按钮；桌面按 Esc 也可返回
  - 支持深链：直接打开 `...#wall` 会落在壁纸分页
  - 进入壁纸分页时只**只读同步**三个滑杆值，不重复加载壁纸图片（避免闪烁）
- 保留全部原控件 id（`wallPick` / `wallOpacity` / `glassOpacity` / `glassBlur` 等），事件绑定逻辑零改动

### v2.2.7 (2026-09-24)
- **壁纸设置独立成页**：底部「壁纸」浮动按钮不再直接弹相册，改为进入**全屏壁纸设置页**
  - 页内含：选择/清除壁纸 + 壁纸透明度 + 玻璃透明度 + 玻璃模糊（四个区块集中管理）
  - 关闭方式：右上角 ✕ / 点页外遮罩 / **系统返回键**（不退出 WebUI）/ Esc
  - 实现用 `history.pushState` 压栈，返回键先关页而非退出
  - 设置页自身也是玻璃卡片（跟随 `--glassA` / `--glassBlur`），打开时锁滚动并隐藏底栏
- **修复「打开 WebUI 数秒不出壁纸」**：定位到两个叠加原因
  1. `wall.sh get` 实测 0.6~1.0s（6 次 `conf_get`，每次 grep/tail/cut 多进程管道）→ 改为**一次 grep + 内建 read 解析**，进程数从 ~20 降到 ~3，实测降至 **0.20~0.35s**
  2. 前端必须先等 `get` 返回拿到 `mtime` 才能拼壁纸 URL → 新增 **localStorage 首屏预热**，用上次缓存的 `mtime` 立即显示壁纸，`get` 回来再校正（内容未变则跳过重复解码）
- 新增 `shrinkIfHuge()`：>2MB 的壁纸自动尝试降采样（有 convert/ffmpeg 时生效；当前设备无此工具，保留原图不阻断功能）
- 保留 `file input` 的 `class="filehide"` 视觉隐藏（**不得改 `hidden` 属性**，否则部分 WebView 唤不起选择器）

### v2.2.5 (2026-09-24)
- **玻璃透明度上限完全放开**：映射改为 `alpha = 1 - v/100`，100% → alpha **0**（玻璃底衬彻底消失，只剩边框与文字，壁纸完全透出）；0% → 1.0 全实。此前 100% 只到 0.06 仍有底衬
- **新增「玻璃模糊」滑杆**：0–40px，作用于底部浮动按钮的 `backdrop-filter`（0 = 无模糊纯透明）；持久化到 `wall_blur`（默认 24）
- **`cgi/wall.sh` 新增 `blur` 子命令**：`wall.sh blur <0-40>`，`get` 增输出 `wall_blur`；`conf_write` 扩为 5 参数（含 fail-safe 写盘顺序不变）
- 版本：module.prop → v2.2.5 / versionCode 21

### v2.2.4 (2026-09-24)
- **修复「相册选图必失败」根因**：宿主 `SuKiSU Ultra` 的 `onShowFileChooser` 经 `FileChooserParams.parseResult()` 交给 WebView 的 `File` 是空壳（`name`=MediaStore 数字 `_id`、`size=0`、无字节流），导致 `FileReader` / `createImageBitmap` / `createObjectURL` 三条通道全部失败。改为 **root 直读通道**：`_id` → `content query` 取真实路径 → `cp` 进 `webroot/bg/wall.new.jpg` → 后端 magic 校验 + 原子替换；`_data` 不可用时回落 `content read` 流式读取，再回落 FileReader 直传 / canvas 压缩。实测 11MB 相机原图 cp 后 md5 字节级一致
- **新增「玻璃透明度」滑杆**：0–100%（越高越透），统一驱动卡片 / 日志区 / 输入框 / 浮动按钮的玻璃 alpha；映射 `alpha = 1 - v/100*0.94`（0%→1.0 全实，100%→0.06 近全透），持久化到 `wall_glass`（默认 50）。修复此前 `.logview` 纯 `#ffffff`、`select` 用不透明 `var(--bg)` 造成「壁纸 100% 仍被遮挡」
- **`cgi/wall.sh` 新增 `glass` 子命令**：`wall.sh glass <0-100>`，`get` 增输出 `wall_glass`；配置写盘保持 tmp+mv 原子、fail-safe 顺序
- **缓存击穿**：`index.html` 引用的 `style.css` / `main.js` 统一加 `?v=` 版本参数；8778 静态路由同步兼容带 query（`/index.html|/index.html?*` 等）
- **诊断体系**：`webui_debug.log` 记录环境（UA / ksu / canvas / FileReader / bitmap / objURL）与全链路步骤；失败时页面直接回显诊断尾部
- **健壮性**：`ksu.exec` 全局串行化（消除并发竞态）；分块写盘 64KB + 失败降 8192 重试；`_id` 严格数字白名单防空注入
- 版本：module.prop → v2.2.4 / versionCode 20

### v2.2.0 (2026-09-24)
- 新增壁纸系统：系统相册 / 文件管理器选图（主通道）+ 目录列图 + 手动路径三级；`cgi/wall.sh` v3.2.0（get/list/set/commit/opacity/clear），配置独立在 `config/wall.conf`，完全不触碰 `settings.conf` 的 `game_floor_mhz`/`game_ceil_mhz`
- 壁纸透明度可调（0–100，默认 35），松手持久化
- UI 重构：默认浅色（白底黑字）+ `dark`/`auto` 三态主题；液态玻璃底栏（仅主题/壁纸/刷新）；档位配置区字段卡式重排；手机单列 / 平板双栏自适应
- 安全：路径参数 base64url token 化 + 后端绝对路径白名单 + 图片 magic 头校验；分块写入失败即清理，旧壁纸保留
- 修复：`Content-Length` 按字节计算（原按字符，含中文响应被截断）
- 修复：`.whandler.sh` 增加 wall 路由与二进制 wallpaper 路由（原缺失 → 浏览器模式壁纸必然 404），`webdaemon.sh` heredoc 同步
- 版本：module.prop → v2.2.0 / versionCode 16

### v2.1.6 (2026-09-13)
- 修复：KernelSU(busybox ash) 下 $SECONDS 不自增，导致配置重载 / 路径探针 / 8s 迟滞 / 日志节流全部失效（表现为“配置改了但地板不跟随”）
- 新增 shell 兼容层：检测到 $SECONDS 不自增即 exec /system/bin/sh(mksh) 重执行自身（G750_MKSH 防递归，exec 不改 pid，置于 LOCK 之前）
- 移除 proc_monitor 看护：与 proc_monitor 单实例保护冲突，导致无限 respawn（fail #N 风暴）

### v2.1.5 (2026-09-13)
- status.sh 新增 cfg_floor / cfg_ceil（配置目标，读 config/settings.conf，非游戏态也准确），与 state/*（当前生效）分离
- WebUI 状态卡三行：配置目标 / 当前生效 / 硬件实际
- 新增服务自愈守护：webdaemon 每 10s 探活 service lock pid，死亡即 setsid 拉起（前 2 次 15s、之后 60s 退避；模块 disable/remove 时绝不拉起）
- webdaemon 用 setsid 独立会话，service.sh 被进程组清理时不陪葬

### v2.1.4 (2026-09-13)
- WebUI 档位选择改按档位下标命中，修复"配置值不在频表时静默选中最高频"
- 保存时强制吸附到设备真实档位，写盘值必为可用档位
- 回显生效值 + 档位号；保存后回读；吸附 / 夹取附加提示
- 修复浏览器通道未替换 `__MODPATH__`（导致 `config.sh` 被降级为 `status.sh`）
- 频表强制降序归一化 + 与 `num_pwrlevels` 对齐校验（跨 SoC 一致性）
- 上限档位高于地板时窗口对齐（等效锁频）
- WebUI 状态卡新增「地板档位」

### v2.1.3 (2026-09-13)
- 事件驱动游戏识别（`am_proc_start` / `am_proc_died` → `state/game_proc`），去掉 pidof 轮询
- 保留启动兜底扫描
- WebUI 包名来源统一到 `state/game_proc`

### v2.1.2 (2026-09-13)
- 安装期节点探测重构：按实际平台路径探测（复用运行时引擎），8e5 不再误报
- 热路径零 fork 化：内建 read/echo 替代 cat/命令替换，游戏轮询统一 0.3s（实测每轮 73μs）
- 上限护栏同频 0.3s：四路上限节点每轮检测，拉低后 0.3s 内恢复
- 修复：WebUI 页脚版本号 v2.1.0 → v2.1.2
- 修复：启动 banner 版本号与 module.prop 一致（v2.1.2 / versionCode 11）

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
