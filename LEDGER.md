# Husk 总账（Single Ledger）

> 一份账，三源合并：`TODO-0.0.37.md`（218 框）、`docs/design/defect-ledger.md`（118 条）、
> `docs/GOALS.md` v55（A/B/C）。生成于 2026-11-28，**只在工作区，不提交**。
>
> 铁律：勾必须有证据编号（evidence 或门禁汇总行）；没证据写 ⬜；没硬件写 ❓；宿主侧写 ⛔。
> 编译通过不算运行通过，静态检查不算真机验证。

## 0 · 一页结论

- 本账 **217 条**：✅ 108 条有证据 · 🟡 36 条部分 · ⬜ 60 条未做或无证据 · ⛔ 6 条外部阻塞 · ❓ 7 条 UNKNOWN。
- 缺陷历史 118 条：103 条已修或已验证（96 FIXED + 5 VERIFIED + 1 CLOSED + H59 权限侧），11 条 OPEN，1 条 DEFERRED（H63），2 条 OUT-OF-SCOPE，1 条被纠正。
- 三份旧账对不上：TODO 里 168 个空框、ledger 里 118 条，同一件事两边状态不同；你登记的原文 483 行 / 231 框，仓库里只有 346 行 / 218 框。
- 三个最大的真缺口：
  1. **性能与交互从未按目标测**：冷热各 5 次、p95、交互帧时间、20 次循环全空（§11）。
  2. **GPU 全局继承只断言 3 个面**，13 项里 8 项从未逐条测（§9.2）。
  3. **P2 运行时核心 14 项一行没动**：Path Shim 拆模块、dirfd、dup2/dup3、只读挂载补 chmod/chown、静态 ELF 边界……（§14）
- 三个不是 Husk 欠账的：宿主无 X server（H36）、宿主无硬件桥（H59）、Android 触摸不进宿主窗口（H48）。

---

## 1 · 对账：三份旧账并成一张

| 来源 | 规模 | 处理 |
|---|---|---|
| `TODO-0.0.37.md` | 346 行 / 218 框（50 勾、168 空） | 逐条并入第 7–21 节；勾选只跟证据走 |
| `docs/design/defect-ledger.md` | 118 条：96 FIXED / 5 VERIFIED / 1 CLOSED / 11 OPEN / 2 OUT-OF-SCOPE / 1 CORRECTED / 1 DEFERRED / H59 混合 | 结论并入对应条目；全量索引留在第 22 节 |
| `docs/GOALS.md` v55 | A 6 / B 4 / C 4 | 第 4–6 节 |
| 用户登记的原文 | 483 行 / 231 框 | **仓库里没有这份原文**；现存 `TODO-0.0.37.md` 是 rev2 精简版，少 137 行 / 13 框 |

两条口径，先看清楚：

- 「⬜」不等于「没干过」，含义是**没有可引用的验收证据**。干过但没留证的，一律退回 ⬜。
- 同一件事在旧账里可能既是 FIXED 又是空格（例：GPU 全局继承 13 项）。本表只留一行。

## 2 · 图例

| 标记 | 含义 | 证据要求 |
|---|---|---|
| ✅ | 有直接实测证据 | 必须带 evidence 编号或门禁汇总行 |
| 🟡 | 部分完成：机制修了但缺验收项，或只有静态结论 | 必须写清缺哪一项 |
| ⬜ | 未做 / 无证据 | 不得写成"已完成" |
| ⛔ | 外部阻塞：宿主侧或不在本仓库 | 只记阻塞，不算 Husk 欠账 |
| ❓ | UNKNOWN：无对应真机或从未实跑 | 16K/64K 页、Adreno、GitHub Actions |
| 📌 | 约束条款，永不勾 | 「明确不做」 |

## 3 · 版本与交付

| 项 | 状态 | 证据 |
|---|---|---|
| 0.0.37 发布（tag + Release + 两个 tar） | ✅ | tag `v0.0.37` → `66bbf1e`；`husk-arm64.tar.gz` `58dfccc3…`；源码包 `dbf5ab20…` |
| 0.0.38 开版：包名统一 `com.linuxhub.myth.husk` + README 重写 | ✅ | `bafaa73`；evidence 368 |
| 0.0.38 tag / Release | ⬜ | 未打、未发 |
| 0.0.38 真机门禁（包名切换后） | ❓ | 最近一次真机实测全部采于旧包名，切换后未重跑 |
| 真机在线 | ✅ | `adb devices` → `3B6585005LE00000` |

最近一次真机门禁（0.0.37 包，evidence 367 §5）：
`RUNTIME_IDENTITY 12/0`、`ICD_CANONICAL 15/0`、`READBACK_AUDIT 19/0`、`GPU_GLOBAL_AUDIT 3/0`、`A-hw 15/0`。

## 4 · 目标 A：前置六项（GOALS v55）

| # | 项 | 判定 |
|---|---|---|
| A1 | polkit「调用者可信」 | 🟡 三层修完两层（evidence 150 §4 明写"还差一层"）；电源菜单未验 |
| A2 | at-spi 无障碍总线 | ⬜ 无证据；`14-gate-a-acceptance.sh` 里没有这一项 |
| A3 | gvfs / 会话总线 | ✅ evidence 152 §1：会话总线补 `<allow user="*"/>`，`gio mount -l` 无 proxy 报错 |
| A4 | xrandr scaling 告警 | 🟡 机制已修（`SERVER_RANDR_MINOR_VERSION` 6→2，告警计数 0，evidence 152 §2）；11-28 现场仍报"缩放后右下角异常"，需复测 |
| A5 | 触控默认模式 | ✅ evidence 152 §3：默认模式 1→2，点左上角能开概览；模式 3 同样 |
| A6 | `nr-sigsys.log` 噪声 | ✅ evidence 152 §4：跨进程去重，单会话 246 行（原 5001 行 / 142 KB） |
| — | 统一判据 `14-gate-a-acceptance.sh` | 🟡 36/0 是 11-24 旧树结果；0.0.38 未重跑 |

## 5 · 目标 B：八维度对比

| # | 项 | 判定 |
|---|---|---|
| B1 | 三运行器同机、同树、轮转 | ✅ `docs/BENCHMARKS.md` 口径段 + `tools/bench/run-interleaved.sh` |
| B2 | 八维度都有数字 | 🟡 1 启动 / 2 syscall / 3 文件 I/O / 4 包管理有数；5 桌面、6 交互、7 资源、8 兼容性缺（桌面行写"不可比"） |
| B3 | ≥5 次中位数、冷热分列、脚本可重跑 | 🟡 现有 4 项 5 轮轮转；缺项同上 |
| B4 | 总表 + 为什么 + 代价 | ✅ BENCHMARKS §总表 / §为什么 / §代价 |

## 6 · 目标 C：仓库呈现

| # | 项 | 判定 |
|---|---|---|
| C1 | 必备文件 24 项 | 🟡 23 项在位；`ARCHITECTURE.md` 在 `docs/` 不在根（链接正常）；`SHA256SUMS` 只在 release 生成 |
| C2 | README 17 段固定结构 | 🟡 已重排，但**没有独立「Why Husk」章**（已并入概览）；是否恢复，你定 |
| C3 | 真徽章 | 🟡 CI / release / license / platform 在位；MSRV、PRs welcome 待核 |
| C4 | 不装 App 也能用 | 🟡 `docs/RUNNING.md` 在；"独立安装走通"仍是 ROADMAP 第 2 项未完成 |

## 7 · P0 纠正测试对象

| 项 | 状态 | 证据 |
|---|---|---|
| 冻结旧环境结论（三角 / 旧 ICD / 1 s、4–5 s） | ✅ | evidence 358 / 366 |
| 确认工作区与分支 | ✅ | `husk` / `main` |
| 建 `codex/` 分支或 worktree 再改 | ⬜ | 仍在 `main` 工作区 |
| 保住未提交的 PanVK 改动 | ✅ | 已随 0.0.37 落库 |
| 生成新 runtime 资产，不用旧 App 里的 | ✅ | 新 `dist` + runtime boundary PASS |
| 每次部署产出运行身份（6 项 SHA） | ✅ | evidence 350；`RUNTIME_IDENTITY 12/0` |
| 设备能自证跑的是这份 Husk | ✅ | 同上 |
| 清掉 `COGL_DEBUG=disable-software-clipn` | ✅ | 设备 `gpu-env` / `profile.d` 已无该变量 |
| 宿主只当黑盒，覆盖配置记外部阻塞 | ✅ | evidence 366 §9；H50 |

## 8 · P1 构建、打包、安装

| 项 | 状态 | 证据 |
|---|---|---|
| `make loader` 可复现 | ✅ | `make check` 内含复现断言；`f2fe07f8…` / 1,263,104 B |
| `make check`（NDK 28.2.13676358） | ✅ | EXIT=0；398 个 md / 0 断链；PanVK 审计 PASS |
| `cargo test -p gpu-env` | ✅ | 含在 `make check` |
| `audit-panvk-bundle.sh` | ✅ | PASS（`47d11cd2…` / `5e063247…`） |
| `make test` | ✅ | EXIT=0；四组 aarch64 交叉编译，**不是真机运行** |
| 安装器不吞 tar 失败 | ✅ | pass1 / pass2 分开判 rc |
| 绝对符号链接自动处理 | ✅ | 安装器 2c 相对化 |
| 装齐 usermgr / su / ldconfig / wallpaper-\* / 硬件工具 | ✅ | `20-tree-integrity 23/0` |
| `make dist` 只出 runtime | ✅ | runtime boundary PASS |
| 无 `._*`、无私路径、无旧脚本 | ✅ | `audit-runtime-package` PASS |
| 逐项断言发布包内容 | ✅ | `make dist` 内断言 |
| 设备文件 SHA 与包一致 | ✅ | `23-runtime-identity 11/0` |
| 干净目录装 | ✅ | evidence 358 §8（`RC=0`） |
| 卸载 / 重装无残留 | 🟡 | 删过树，未做逐项对照 |
| 升级装不覆盖新版 | ✅ | `26-upgrade-in-app.sh` PASS |
| 清旧 ICD / 驱动副本 + 负向测试 | ⬜ | H43 |

## 9 · P1 GPU

### 9.1 ICD 与驱动（8）

| 项 | 状态 | 证据 |
|---|---|---|
| canonical ICD `husk_panvk_guest.json` | ✅ | `ICD_CANONICAL 15/0` |
| 驱动 `libvulkan_panfrost_husk.so` | ✅ | 同上 |
| 旧 ICD 全部禁选 + 负向测试 | ✅ | 15/0 含负向 |
| `/proc/<gnome-shell>/maps` 实证 | ✅ | evidence 352 |
| `/proc/<gnome-shell>/fd` 有 `/dev/mali0` | ✅ | evidence 352 |
| `zink` + `VK_ICD_FILENAMES` + `PANVK_DXVK_COMPAT=0` | ✅ | evidence 351 / 352 |
| 无静默 llvmpipe；`HUSK_GPU=llvmpipe` 显式回退 | ✅ | evidence 351（坏 ICD 仍拿到 Mali） |
| `NR_GPU_DEFAULT_OFF=0` 不误判 | ✅ | 同上 |

### 9.2 GPU 全局继承 13 项

- ✅ 3 项：GNOME Shell、loader 默认 GL 客户端、nested GTK → `GPU_GLOBAL_AUDIT PASS=3 FAIL=0`（evidence 352 §94、367 §5）
- ✅ 1 项：4 路 × 300 s → `GPU_SOAK_AUDIT PASS=19 FAIL=0`（evidence 342）
- ✅ 1 项：3 进程同时读回 → 三路各 19/0（evidence 319）
- ⬜ 8 项：登录 shell、非登录进程、`env -i`、嵌套 `execve` 显式读回、fd 稳定、RSS 不涨、GL 错误计数、多进程互不覆盖
  —— **门禁脚本只有 3 个面（`15-gpu-global-audit.sh:61 / 85 / 98`），这 13 项从未被逐条断言。**

### 9.3 Overview / 缩略图三角（6）

| 项 | 状态 | 证据 |
|---|---|---|
| 不用旧壁纸预缩放冒充修复 | ✅ | 约束已守 |
| 6 步复现 + 4 张截图 | ⬜ | 未留 |
| 10 组单变量对照 | ⬜ | 未留 |
| 判定表 | 🟡 | H49 已收敛到"一次 draw 内缺角"，未成表 |
| 驱动缺陷最小复现 + 修复位置 | ✅ | H57 / evidence 365：`vk_meta_draw_volume` 改单三角形 + 精确 scissor，近黑 0.1490→0.0000 |
| 不隐藏缩略图冒充修复 | ✅ | 同上 |

### 9.4 零拷贝与读回（5）

| 项 | 状态 | 证据 |
|---|---|---|
| 2400×1080 每帧回读耗时 | ✅ | GPU 1.8 ms / `XPutImage` 15.1 ms / 整帧 31 ms = 32 fps |
| DRI3 不可用原因写清 | ✅ | 结构性四因已写（bionic X server、无 render node、`card0` 无权限、kbase 无 DRM） |
| 两段零拷贝分开写 | ✅ | 已分"窗口→X server"与"合成→屏幕" |
| 不许笼统写"零拷贝" | ✅ | 已按段表述 |
| 0.0.37 只量化不修 | ✅ | 记录完成，修复归 0.0.38 |

### 9.5 Adreno / KGSL（3）

| 项 | 状态 | 判定 |
|---|---|---|
| 没真机写 UNKNOWN | ✅ | `STATUS.md:113`、`README.md:220` 已写 UNKNOWN；真机到位后按 evidence 370 回填 |
| 有真机后验 KGSL 节点 / Turnip / zink / Vulkan / GLES / 桌面 / 长稳 | 🟡 **已真机实测**（PASS 6 / FAIL 5 / UNKNOWN 1） | evidence **370**：KGSL app uid O_RDWR 可开 + `gpu_model=Adreno825`（PASS）；`renderD128` 打开 EACCES（节点 0666、父目录 0755，拒绝来自 SELinux app 域，FAIL/Turnip DRM 后端不可用）；Turnip 经 KGSL 出 `zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`、GL 4.6 / GLES 3.2（PASS）；原生 freedreno `vendor=freedreno`、GL 4.6 / GLES 3.2、glxgears 613–637 FPS（PASS）；桌面可起可交互（PASS）；**窗口内容不上屏**（glxgears 在跑但窗口不可见，FAIL）；**壁纸块状错色**（guest XGetImage 与 SurfaceFlinger 两路同错色，FAIL）；`tmp/husk-desktop.status` 不存在 → 就绪判定无证据（FAIL）；长稳进程级 PASS（8 样本 pid 稳定、fds 43 不变、RSS 无增长）/ 画面级 FAIL（错色随时间扩散）；`FD_KGSL_ENABLE_DMABUF` 在 Turnip 与上游源码均不存在 → 宿主 Adreno 链路依赖的下游 dma-buf 导出能力本机缺失（FAIL）。已排除 UBWC/DING/clipped-redraw/PBO/Cogl 纹理全套/notile 六项单变量；原生 a7xx-kgsl 块状错色与上游 freedreno 两条 open issue 同族 |
| 高通端改走**源码构建 Turnip**（KGSL + x11 WSI）+ H57 共享 vk_meta 补丁 | ✅ **PASS（11/11 自证）** | evidence **371**：`d211037c` / Mesa `27.0.0-devel` / SHA-256 `35577a1a…89ad75f5`；`glxinfo -B` → `zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`、Version `27.0.0`、`direct rendering: Yes`、GL `4.6`、GLES `3.2`；glxgears 328×366（vblank off）**607 / 997 / 940 FPS**；`/proc/<gnome-shell>/maps` 7 段 `libvulkan_freedreno_husk.so`；**370 的壁纸块状错色不再复现**、GNOME 不再 139。踩到并修掉两个构建缺陷：漏 `-Dfreedreno-kmds=kgsl`（→0 设备→139，H64）、漏 `-Dplatforms=x11`（→`pc=0`，H65）。顺带更正 370 的一条推断：KGSL dma-buf 导出本快照**上游已有**（`kgsl_bo_export_dmabuf` / `KHR_external_memory_fd` / `EXT_external_memory_dma_buf`），无需移植；`FD_KGSL_ENABLE_DMABUF` / `TURNIP_KMD` / `FD_FORCE_KGSL` / `TP_UBWC_FLAG_HINT` 在源码中**零命中**，是无效变量。**仍未解决**：客户窗口内容不上屏（窗口 `Viewable` 但 X 根图无其像素；`DRI3Open` 取不到 DRM 设备——app 进程只持有 `/dev/kgsl-3d0`，guest 的 `/dev/dri/renderD128` 是 shim 假节点且 `adreno_ioctl()` 只实现 `DRM_IOCTL_VERSION`）。长稳 soak 因用户中止设备测试**未跑**（NOT VERIFIED）。已固化：`vendor/turnip/` + `install-husk.sh` + `tools/ci/audit-turnip-bundle.sh` + `tools/device-tests/29-turnip-kgsl.sh` |

## 10 · P1 桌面与会话 lifecycle（14）

| 项 | 状态 | 证据 / 缺口 |
|---|---|---|
| 启动前清旧 D-Bus / X socket / gvfs / at-spi / 安全模式标记 | ⬜ | H42：`gvfsd/` 积压 146 个 socket，启动不清理 |
| 说清「后台保留会话」与「强制退出」两种状态 | 🟡 | `docs/design/lifecycle.md` 有口径；真机未按两态对照测 |
| 强退后 `gnome-shell` / `dbus-daemon` / X server 无残留 | ⬜ | 未测 |
| 不允许"强退后旧会话还活着" | ⬜ | 未测 |
| 就绪判定（WM 认领 + X root + 首帧非黑 + 可输入） | ✅ | G8 / evidence 333：`husk-desktop.status` 原子写 starting/ready/failed |
| 首启不黑屏 | ✅ | evidence 147 |
| 重复启动 20 次不进安全模式 | ⬜ | `19-overview-10cycles` 只跑到 10 次；20 次 NOT RUN |
| 主题 / Dock / 壁纸 / 中文界面不丢 | ⬜ | 未测 |
| X11 resize 后不裁剪 | ⬜ | 未测 |
| 旋转后几何不错位 | ⬜ | 未测 |
| 切分辨率后窗口不留旧几何 | ⬜ | 未测 |
| 默认语言中文 | ⬜ | 无证据 |
| GTK4 保持 `GSK_RENDERER=cairo` | 🟡 | evidence 186 记录 GTK4 曾走 GL 出楔；当前值未在 0.0.38 复核 |
| GNOME Shell 仍 zink / PanVK | ✅ | evidence 352 / 367 §5 |

## 11 · P1 启动与交互性能（10）

| 项 | 状态 | 缺口 |
|---|---|---|
| 三个指标分开（点程序→进程创建 / →窗口 / →首帧可交互） | ⬜ | 只有整段冷启动，未拆三段 |
| 同程序冷 5 次 / 热 5 次 | ⬜ | 未跑 |
| 同文件夹冷 5 次 / 热 5 次 | ⬜ | 未跑 |
| 强退立即重进 5 次 / 等 30 s 重进 5 次 | ⬜ | 未跑 |
| 中位数 / p95 / 最大值 / 4–5 s 异常次数 | 🟡 | 只有中位 11.35 s（10.57 / 11.35 / 11.48，evidence 353）；p95 与异常计数缺 |
| 冷启动中位 11.35 s vs PRoot 9.79 s（慢 1.16×） | ✅ | evidence 355；瓶颈已定位到"点按钮→stage=outer-root" 5.9 s |
| 波动来源逐项排除 | ⬜ | 七项排除表未做 |
| 交互单独测（空闲 / 连点 / 滑动 / 拖动 / 缩放 / Overview / 并发） | ⬜ | 只有"拖动卡"的现场描述，无帧时间 |
| 记输入事件→响应时间、帧时间、掉帧数 | ⬜ | 未测 |
| 不用 GPU soak 冒充交互流畅 | ✅ | 口径已守（H60/H61 照写 FAIL） |

## 12 · P1 输入（10）

| 项 | 状态 | 证据 / 阻塞 |
|---|---|---|
| 触摸板默认模式、点哪落哪 | ✅ | A5 / evidence 152 §3 |
| Android 触摸 → 宿主窗口 → X | ⛔ | H48：`adb shell input tap` 不进宿主窗口，宿主侧，不在本仓库 |
| guest → X 输入语义（xdotool） | ✅ | evidence 359：`xdotool key super` 能开关 Overview |
| 坐标对齐（缩放 / 旋转后） | ⬜ | 未测 |
| Overview / 旋转 / 分屏下的输入 | ⬜ | 未测 |
| 双客户端不串扰 | ⬜ | 未测 |
| fcitx5 中文输入 + 候选框位置 | ⬜ | 未测 |
| 多指触摸 / 滚轮 / 相对鼠标 | 🟡 | G7 已把事件接到 Xlorie，真机未逐项验 |
| 输入期间帧率与 CPU | ⬜ | 未测 |
| 不把"宿主不管"写成"Husk 已修" | ✅ | 已按外部阻塞记 |

## 13 · P1 硬件接口（36）

### 13.1 相机（11）

| 项 | 状态 | 证据 |
|---|---|---|
| V4L2 节点映射（`/dev/video0/1`） | ✅ | A-hw 15/0；H59 |
| Camera2 → V4L2 中转 | ✅ | 同上，Camera2 真出 3 帧 |
| 前后摄像头切换 | ⬜ | 未测 |
| `read` / `readv` / `mmap` 三种读取 | 🟡 | 只验过一路读取；三路未分别验 |
| 裁剪语义 | ⬜ | 未测 |
| 时间戳单调 | ⬜ | 未测 |
| GStreamer `v4l2src` | ✅ | evidence 343 相机 fixture |
| 相机 fixture | ✅ | 同上，`PASS=4/0` |
| 权限拒绝时错误明确 | ✅ | H33 / P20 |
| 权限恢复后能重开 | ✅ | H33 |
| 不能只在 ADB 手动授权下通过 | ✅ | H59 权限侧（debug manifest + `-g` 授权流程） |
| 桌面预览帧率可用 | ⬜ | H60：逐帧刷新，未量化 |

### 13.2 音频（7）

| 项 | 状态 | 证据 |
|---|---|---|
| PulseAudio module / 中转 | ✅ | `AUDIO_AUDIT PASS=4 FAIL=0` |
| 输出 | ✅ | 同上 |
| 麦克风输入 | ✅ | 200704 B PCM，peak=1891 |
| 并发客户端 | ⬜ | 未测 |
| 断开重连 | ⬜ | 未测 |
| `/dev/snd` 不可用的限制写清 | 🟡 | 已写口径，未在 real 设备复核 |
| 宿主 `audio-out.sock` 缺失 | ⛔ | H59 桥 OPEN（宿主无 `AudioRecord` / `AAudio`） |

### 13.3 视频（7）

| 项 | 状态 | 证据 |
|---|---|---|
| VA-API 驱动（自有 `husk_drv_video.so`） | 🟡 | 设备上可用；**未进 dist / assets**（H62） |
| MediaCodec 桥 | 🟡 | 自有 SurfaceControl 路径 1080p30 / 600 s 通过；标准 VA 路径停摆（H61） |
| 1080p30 | 🟡 | 自有路径 ✅；VA-API 1080p 12–25 帧后卡（H61） |
| 十分钟长稳 | 🟡 | 自有路径 600 s 通过；VA 路径未达 |
| 音视频同步 | ⬜ | 未测 |
| 解码帧交给桌面 | 🟡 | totem 出画；彩色条问题待查（用户 11-28 现场） |
| 播放器兼容性 | 🟡 | 只验 totem 一条 |

### 13.4 传感器与定位（9）

| 项 | 状态 | 证据 |
|---|---|---|
| IIO sysfs | ✅ | evidence 344 §5 |
| `iio-sensor-proxy` D-Bus | ✅ | 同上（H33 口径已改） |
| 加速度 / 陀螺仪 / 磁力计 / 环境光 / 距离 | ✅ | 五类三视图可读 |
| GPS last-known | ✅ | `TPV mode=2/3` |
| gpsd | ✅ | `/run/husk/gps.sock` |
| 权限不足时明确不可用 | ✅ | 权限框 + 撤权后明确报错 |
| 持续定位 / 后台定位 / GNSS 原始测量 | ⬜ | `LIMITATIONS.md` §11 明列未测 |

### 13.5 其他（5）

| 项 | 状态 |
|---|---|
| USB 分类（直连 / 中转 / 权限限制） | ⬜ |
| 蓝牙分类 | ⬜ |
| NFC 分类 | ⬜ |
| 指纹分类 | ⬜ |
| 不把"不需要"写成"未实现" | 🟡 口径在，分类表未写 |

## 14 · P2 运行时核心（15）

| 项 | 状态 | 说明 |
|---|---|---|
| Path Shim 按模块拆分（14k 行单文件） | ⬜ | NOT RUN |
| 符号链接 40 层语义 + 竞态 | ⬜ | 现有 0 escapes 是浅层 |
| `dirfd` 越界 + fd 生命周期 | ⬜ | 未测 |
| `dup2/dup3` 后设备身份 | ⬜ | 未测 |
| errno 保持 | ✅ | S12 / evidence 325 |
| 只读挂载补 `chmod/chown/utimensat` | ⬜ | 未做 |
| 用户/组库四文件事务化 | 🟡 | `husk-usermgr` 在位，事务性未验证 |
| `sync_all` 与权限设置失败不吞 | ⬜ | 未做 |
| DRM 假 fd 识别不只匹配 `mali` | ⬜ | 仍是字符串匹配 |
| 静态 ELF 边界写清 | ⬜ | 未写 |
| raw syscall 边界写清 | ⬜ | 未写 |
| 安全文档不说成恶意代码沙箱 | 🟡 | `SECURITY.md` 口径在，未逐句核 |
| libc 升级自动重打补丁 + 版本校验 | ✅ | 安装器 pass2 + 哈希校验（evidence 358） |
| 补丁失败阻止会话启动 | ✅ | 同上 |
| **16 KiB / 64 KiB 页真机 + 4K 回归** | ❓ | 静态：2987 个 ELF 4K/16K/64K 全绿（`page-size.md:61`）；**真机没有 16K/64K 内核设备**，UNKNOWN（`page-size.md:108`） |

## 15 · P2 CI 与测试门禁（9）

| 项 | 状态 | 证据 |
|---|---|---|
| CI 检查整个 workspace | ✅ | `ci.yml` `check` job，`--workspace` |
| CI 跑全部可运行单测 | ✅ | `test` job |
| CI 编译 Android Rust | ✅ | `android` job |
| CI 构建 APK | 🟡 | `apk` job 已定义（`ci.yml:151`）；**Actions 从未实跑**（token 缺 `workflow` 权限） |
| CI 查资产边界 / shell 语法 / 断链 / 版本 / 包 SHA / PanVK | 🟡 | `scripts` job + `docs` job 已定义（`ci.yml:205 / 235`）；同上未实跑 |
| 每个修复配负向测试 | ✅ | 18 反向控制 / 25 负向 / H57 `blit-green` |
| `make check`、`make test`、CI 覆盖一致 | ✅ | EXIT=0 |
| coverage-sweep 缺工具标 SKIP 不算 PASS | ✅ | 脚本已标 SKIP |
| 单机不代替跨设备 | ✅ | 文档口径已写 |

## 16 · P2 文档（12）

| 项 | 状态 |
|---|---|
| 全中文优先 | ✅ |
| README 只介绍 Husk 这个 Linux 运行环境 | ✅ 0.0.38 已重写 |
| 不绑 Ubuntu / 不绑某台手机 / 不绑 GNOME | 🟡 README 仍以 Ubuntu 24.04 + GNOME 46 举例 |
| 硬件接口写成直连 / 中转 / 不需要 / 权限限制 | ✅ README 硬件表 |
| 环境要求写在主页前面 | ✅「跑起来的前提」在目录后 |
| 写清装完发行版必须改什么 | ⬜ 未写 |
| 版本徽章、Rust 比例、平台支持同步 | 🟡 徽章在；Rust 行数与平台说明未同步 |
| 修正 evidence 349 错误口径 | ✅ 已重写 |
| 修正"Husk 没有 X server"过期表述 | ✅ `STATUS.md` §1 改为"显示载体由宿主提供" |
| 区分已实现 / 已验证 / 仅静态 / 环境跳过 / 未验证 | ✅ RESULTS / STATUS 四档 |
| 不利数字照写 | ✅ evidence 366 §8 |
| 不能靠改 README 宣布修复 | ✅ 口径已守 |

## 17 · P2 Rust 化与清理（5）

| 项 | 状态 |
|---|---|
| 审计剩余 Python / C / Java，能 Rust 化的全 Rust 化 | ⬜ NOT RUN |
| 保留必要汇编 + 最小 bootstrap shell | ⬜ |
| 删除旧实验脚本 / 重复探针 / 旧备份 loader / 过期 ICD 驱动副本 | ⬜ NOT RUN（与 H43 同批） |
| 删除前确认不被安装器与门禁引用 | ⬜ |
| 清理后重跑全部门禁 | ⬜ |

## 18 · 发布门禁（0.0.37 已发，按条对账）（22）

| 项 | 状态 | 证据 |
|---|---|---|
| 最新 runtime 已部署 | ✅ | evidence 367 §5 |
| 设备能证明跑的是该版本 | ✅ | `RUNTIME_IDENTITY 12/0` |
| 新 ICD 实际生效 | ✅ | `ICD_CANONICAL 15/0` |
| 三角已修或明确阻塞 | ✅ | H57 驱动源码修复 |
| 启动波动已定量并修复或说明原因 | 🟡 | 中位 11.35 s；4–5 s 异常来源未全归因 |
| 交互卡顿已定量 | 🟡 | 整帧 31 ms = 32 fps；**交互帧时间未测** |
| 门禁 A 全过 | 🟡 | 36/0 是旧树；0.0.38 未重跑 |
| A-hw 全过 | ✅ | 15/0（权限侧 debug 变体） |
| GPU 全局继承全过 | 🟡 | 3/0；13 项未逐条断言 |
| GPU soak 全过 | ✅ | 19/0（4 路 × 300 s） |
| readback 全过 | ✅ | 19/0 |
| 音频全过 | 🟡 | 4/0；宿主 `audio-out.sock` 缺 |
| 相机全过或明确外部阻塞 | 🟡 | 数据链 15/0；桌面预览帧率仍 FAIL（H60） |
| 桌面 / 输入全过 | ⬜ | 输入卡在 H48；20 次循环未跑 |
| 干净树安装全过 | ✅ | evidence 358 |
| VERSION / CHANGELOG / README / STATUS / LIMITATIONS / COMPATIBILITY / RESULTS 一致 | ✅ | evidence 367 §5 |
| annotated tag | ✅ | `v0.0.37` → `66bbf1e` |
| Release 标题 | ✅ | 已发 |
| 资产名 | ✅ | `husk-arm64.tar.gz` |
| `SHA256SUMS` | ✅ | `58dfccc3…` |
| release audit | 🟡 | 曾固定一条红（naming audit 与"不 tag"约束冲突）；0.0.38 需重跑 |
| 只发 runtime，不夹带测试宿主 | ✅ | boundary PASS |

## 19 · 明确不做（8，📌 永不勾）

📌 不改另一个仓库的源码 / 不把它的改动算进 Husk 验收 / 不用 PRoot 解法（`virgl_test_server`） /
0.0.37 不改 X11、不换 Wayland、不换渲染后端 / 不用单机冒充跨设备 / 不用编译冒充运行 /
不用隐藏缩略图冒充修复 / 不把 GOT 路径拦截说成安全沙箱。

## 20 · 0.0.38 延期账（4）

| 项 | 状态 | 归属 |
|---|---|---|
| 相机桌面预览帧率（逐帧刷新） | ⬜ | H60 |
| 标准 VA-API 1080p / High profile 停摆 | ⬜ | H61 |
| VA 资产进 dist 与 App assets（`husk_drv_video.so` / `libgstvaapi.so` / `vainfo`） | ⬜ | H62，随 H61 |
| X11 → WD 迁移 | ⬜ | H63（你指定延后） |
| 0.0.37 发布前提：PanVK/Zink + 19 项 readback 全绿 | ✅ | 19/0 |

## 21 · 外部阻塞与 UNKNOWN（不能算 Husk 欠账）

| 项 | 类型 | 依据 |
|---|---|---|
| 宿主无自己的 X server → 桌面 GPU 全局继承、打开设置对比无 Husk 侧结果 | ⛔ H36 | evidence 349 §4：`XOpenDisplay failed (DISPLAY=':0')`；PRoot 中位 2810 ms 不可比 |
| 宿主无 CameraManager / AudioRecord / GNSS / socket 实现 | ⛔ H59 桥 | evidence 366 §9 |
| Android 触摸不进宿主窗口 | ⛔ H48 | evidence 359 §2/§5 |
| 宿主重写 `/etc/profile.d/doro-gpu.sh`、钉死 ICD | ⛔ H50 | evidence 361 §8 |
| 16K / 64K 页内核真机 | ❓ | 无设备 |
| Adreno / KGSL 真机 | 🟡 驱动侧已通（窗口合成仍阻塞在宿主 DRI3） | evidence **370**：通路全部实测；仅「加速 + 画面正确」未达成——三种后端各坏一半，且 zink 上两症状叠加，说明坏在 guest GPU→X server 共用那一跳，不在后端光栅层 |
| GitHub Actions 实跑 | ❓ | 缺 `workflow` 权限 |
| 宿主 X server 拿不到 DRM 渲染节点 → DRI3 不可用 → 客户窗口无法合成 | ⛔ 宿主侧（非驱动欠账） | evidence **371** §4：app 进程 fd 只有 `/dev/kgsl-3d0`（无 `/dev/dri/*`）；guest `/dev/dri/renderD128` 是 shim 假节点且 `adreno_ioctl()` 只答 `DRM_IOCTL_VERSION`；`MESA-EGL: DRI3 error: Could not get DRI3 device`（`platform_x11_dri3.c:517`，语义为「扩展在、`x11_dri3_open` 失败」）。解决方向两条：A 走 WD/Wayland（合成器在 guest 内）；B 补 KGSL 版 DRM 翻译 **且** 宿主能提供 DRM 节点 |


## 22 · 缺陷账本全量索引（118 条，原 `docs/design/defect-ledger.md`）

> 只留编号、一句话、状态与证据指针；完整描述在原文，结论已并入上文各节。

| ID | 一句话 | 状态 | 证据 |
|---|---|---|---|
| H1 | 干净 clone 只跑 ./gradlew 会成功打出 0 块 .so 的空壳 APK | FIXED | BUILD SUCCESSFUL，随后 unzip -l … |
| H2 | make check 只查 39 个 crate 里的 12 个 | FIXED | audio-relay 注入 E0308 后旧列表 rc=… |
| H3 | 单测只有 3 个 crate 进 CI；video-protocol 零测试 | FIXED | grep -rl "#\[cfg(test)\]" 只有 … |
| H4 | 发布命名契约只有联网半，离线规则从未进 CI | FIXED | audit-release-names.sh 需要 gh，… |
| H5 | 第 1 轮的四张审计清单没有落库，无法"保持可复现" | FIXED | 修前 docs/ 下无对应文件；修后见 evidence … |
| H6 | video-protocol / husk-va-driver 的单测在本机（macO… | FIXED | cargo test -p husk-va-driver … |
| H7 | video-protocol 的 commit() 不校验 write_seq：空环上… | FIXED | 新单测修前在 unwrap_err() 上 panic（拿… |
| H8 | libc 门禁与运行树版本不一致：包库记录 2.39-0ubuntu8.12，实际补丁… | FIXED | 修前两棵最终树均记录 8.12，但两份 libc.so.6… |
| H9 | CI 的 apk / android 两个作业一直红：用了 ANDROID_NDK_L… | FIXED | run 45824212545：no clang at /… |
| H10 | 第 2 轮开工前 main 上连续 6 个提交的 CI 全红（apk/android … | FIXED | 5bc335c…13231bd 六个 run 全 fail… |
| H11 | guest 工具交叉链接只给 --sysroot，没有给目标 GCC 支持目录；NDK… | FIXED | ld.lld: error: cannot open cr… |
| H12 | 16-umount-legacy.sh 用 awk 解析挂载表，但有效发行树可以只有 … | FIXED | 最终树实跑 awk: command not found，… |
| H13 | docs/ENGINEERING.md 的 loader 指纹表落后于当前 path-… | FIXED | 文档写 ld-embedded.so 3f4189e2..… |
| G9 | 内嵌桌面验收只检查文件/日志，不检查实际帧和输入落地：全黑或大块缺失仍可能被人眼漏掉 | FIXED | evidence 334：修前无 raw screensh… |
| H14 | husk-session.sh 启动系统 bus 时，后台 dbus-daemon 让… | FIXED | 修前 run-fd-identity-probe.sh 超… |
| H15 | 9263c0e 修改嵌入 loader 的 drm-shim 后，docs/ENGIN… | FIXED | 旧文档 96b96bbe... / 5319d128...… |
| S1 | 假 fd 身份有三份实现，规则各不相同：drm-preload 用子串 contain… | FIXED | 三处源码 runtime/crates/{drm-prel… |
| S2 | path-shim 对"无状态假 DRM fd"回 EBADF(9)：fd 本身是我们… | FIXED | 真机修前 registered_fd=6 rc=-1 er… |
| S3 | 设备上存在三份 libld.so（APK lib 目录 / files/linux/l… | FIXED | sha256：APK lib = 658f97e1…、fi… |
| S4 | fd-identity-probe 的 v4l2 名字语法用例用"errno≠ENOT… | FIXED | 对照表见 evidence 294 §3：plain / … |
| S5 | pathshim-drm-fake-fd-identity-lost 用 open("… | FIXED | 改前输出 registered_fd=6 … errno=… |
| S6 | 同一条件两层答案不一致：无 DRM preload 时 path-shim 回 EOP… | FIXED | 修前真机 pathshim-drm-fake-fd-ide… |
| S7 | husk-usermgr 的 save() 里四次 rename 不是事务：第三个失败… | FIXED | 单测 install_staged_rolls_back_… |
| S8 | 只读挂载的**元数据**写检查（chmod / fchmodat / chown / … | VERIFIED | 05-mount-audit.sh B-01 13 条全 … |
| S9 | 05-mount-audit.sh 声明 #!/bin/sh、注释也写"run ins… | FIXED | /tmp/05.sh: 75: Bad substitut… |
| S10 | 门禁 A 在测试树上跑出 24/12，其中 7 条用户管理项全红 —— 看似本轮 us… | FIXED | 门禁 A 修前 PASS=24 FAIL=12；按 ins… |
| S11 | pathconf(3) 是 glibc 内部路径查询包装，调用点没有可改写的 GOT/… | FIXED | 旧 loader PATHCONF v=-1 errno=… |
| S12 | statvfs、openat、access 在成功返回时把路径探测留下的 ENOENT… | FIXED | 同一探针：FREOPEN ok=1 errno=2、CRE… |
| S13 | 04-path-reliability.sh 把 Ubuntu 点版本写死为 24.0… | FIXED | 修前真机：PASS symlink-follow 的解析内… |
| S14 | run-path-race-probe.sh 没有像同组探针那样把 Makefile … | FIXED | 修前真机：/data/local/tmp/husk-ses… |
| P1 | 用解包 deb 拼出来的树没有 dpkg 文件清单：status 里 862 个包 i… | FIXED | grep -c "Status: install ok i… |
| P2 | nr-tools rootfs 的索引下载路径从不调用 finish()：包解包完就退… | FIXED | 修前 /tmp/nr-check2/var/lib/dpk… |
| P3 | 状态库是桩（只有 name/version + "staged by nr-tools… | FIXED | 真机 dpkg --admindir 修前：parsing… |
| P4 | usr-merge 链接用 Path::exists() 判断，而它跟随符号链接：sb… | FIXED | 修前暂存输出 staged: 1 entries in u… |
| P5 | 门禁 A 的断言依赖树里的包：shadow hash 用 awk、group entr… | FIXED | 干净树 PASS=27 FAIL=9，三行都是 got '… |
| P6 | 宿主的 EXPECT_PKGS_MIN 从来没传进 guest（guest 只读 ${… | FIXED | installed packages (want >= 9… |
| P7 | 按包拼出来的树没有 /usr/lib/locale/locale-archive（de… | FIXED | 修前：locale charmap 空、%A=Monday… |
| P8 | hard-link 校验把两条 test -s 用 && 串起来：没装 perl 的树… | FIXED | 66 包树安装日志：假警告 + -rwxr-xr-x. 1… |
| P9 | BASE 缺 libssl3t64：noble 的 coreutils 里 sort/… | FIXED | sort 的脚本静默返回空（门禁 A 的泄漏检查因此"PA… |
| P10 | BASE 缺 libc-bin/locales/acl/mawk：基础树里没有 get… | FIXED | 同 P5（三条空串）、getfacl 失败、no zh_C… |
| P11 | 出厂桌面树 files/linux/distributions/ubuntu-24.0… | FIXED | 真机：dpkg -C \ |
| P19 | 稳定 rootfs 是软链接时，husk-session.sh 按字面父目录取旧 bu… | FIXED | 主机负向测试修前：new rootfs libc was … |
| P12 | 同一棵树的 /etc/default/locale 是 LANG=C.UTF-8，且 … | FIXED | 修前 locale charmap 空、%A=Monday… |
| P13 | nr-tools 的 http_get 用 TcpStream::connect((H… | FIXED | 真机/主机侧观测：22:42 起 ls cache/deb… |
| C1 | 整块 glReadPixels 在本树 guest Mesa 里坏：目的行距被当成 1… | CORRECTED by C4 | 独立探针（ctypes，不共用 Rust 代码）：W×H … |
| C2 | 第 5 轮缺"截图类 / 宽度边界 / 金丝雀"三类测试：289 只测了一个 16×1… | FIXED | 新探针首版 13 条全红 —— 全是建帧阶段粘住的 0x5… |
| C3 | DRI3 / dma-buf 在"X server 跑在应用内、本机无 render … | VERIFIED | evidence 290：/dev/dri/renderD… |
| C4 | 2026-11-25/26 的“16 字节行距”不是 Mesa 缺陷，而是探针把 GL… | FIXED | 修前 readback.py 实测 PACK_ALIGNM… |
| G1 | GPU 默认值（ICD / GL 驱动 / GLES 上限 / PANVK 兼容位）只… | VERIFIED | 由加载器 path-shim/src/gpuenv.rs … |
| G2 | 多进程并发吃 GPU 会不会串（假装/共享失败）没有测过 | VERIFIED | 同树同时起三个读回进程，三次都是 zink/PanVK，各… |
| G3 | PanVK 的 PANVK_DXVK_COMPAT：默认值到底有没有真的注入、以及它是… | VERIFIED | 树里 etc/husk/gpu-env 有 PANVK_D… |
| G4 | Mali PanVK 只存在于手工补过的测试树，发行 bundle 没有驱动；干净安装… | FIXED | 手工树 GPU 9/0，但 release-tree-v2… |
| P14 | nr-tools 的 HTTP 下载只靠 read_to_end() 等 EOF；镜像… | FIXED | 旧构建在 718 deb 停 1 小时以上；采样栈为 ht… |
| P15 | nr-tools rootfs --packages 直接替换 BASE，自定义桌面列… | FIXED | 设备原文 usr/bin/env: error while… |
| P16 | install-husk.sh 对非空目标目录没有防护；残留的实体 bin/sbin/… | FIXED | 修前原文 tar: can't remove: ./bin… |
| P17 | 安装器只要存在 python3 就无条件要求 libblas.so.3 / libla… | FIXED | OSError: libblas.so.3: cannot… |
| P18 | make dist 没有打包或断言 guest-config/linuxhub-sys… | FIXED | 修前 TREE_INTEGRITY PASS=12 FAI… |
| D1 | 传感器原先只有 NDK 枚举，没有 guest 可消费的 Linux 接口 | FIXED | 旧矩阵 sensors=absent、no sensor … |
| D2 | V4L2 facade 没有 CROPCAP / CROP / SELECTION，G… | FIXED | 旧 loader 上 v4l2-test 的 CROPCA… |
| D3 | DQBUF 把 Camera2 纳秒时间戳按微秒拆进 timeval，tv_sec 放… | FIXED | 修后契约测试在单位修正前得到 timestamp=2781… |
| D4 | V4L2 buffer 宣称 TIMESTAMP_MONOTONIC，但 Camera… | FIXED | 旧 loader 上 GStreamer gstv4l2s… |
| D5 | IIO 的 class/bus 视图整棵指向 subsystem，导致 /sys/cl… | FIXED | 真机修前 cat /sys/class/iio/iio:d… |
| D6 | 定位被整体归到“需要 Java 回调”后没有 guest 接口，实际可先落地不依赖自定… | FIXED | 修前 guest 没有 gpsd socket；GPSD_… |
| P20 | 用户从系统设置页重新授权后，权限状态只在 pending=true 分支里清零；设置页… | FIXED | 旧 APK：设置页重新授权后日志只有 STATE |
| C5 | 活跃的 19 项读回套只留在手工命令和旧 evidence 里；正式门禁只有 gl-p… | FIXED | 基线 git show HEAD:Makefile 无 r… |
| G5 | ~~当前 Husk APK/发行树没有自己的 X server，无法完成“桌面 + G… | OUT-OF-SCOPE | evidence 329 的失败对象是独立调试壳，不是 H… |
| G6 | 新的四路 GPU 长稳门禁把 RSS 下降误判成增长，导致一次错误的 FAIL=1 | FIXED | 第一次 300 秒四路运行四个工作负载均 errors=0… |
| H16 | 应用内 Xlorie 的构建不可重复：build.sh 二次执行会在已应用的树上失败，… | FIXED | evidence 330：修前 A=fd35d09…、B=… |
| H17 | 应用内桌面入口硬编码 Ubuntu 固定 rootfs，而主运行时使用 rootfs-… | FIXED | 旧 desktop.rs 只尝试 files/linux/… |
| G7 | 内嵌 X11 已有 husk_xlorie_send_touch/mouse/key … | FIXED | evidence 332：修前 drain_input()… |
| G8 | desktop::ACTIVE 在 fork launcher 后立即置真，guest… | FIXED | evidence 333：修前无 husk-desktop… |
| G10 | 第 6 轮只有无桌面四路 soak 和单个 nested GTK 检查，没有三个 GU… | FIXED | evidence 335：修前 15-gpu-global… |
| H18 | 受跟踪的 .py 数为 0，但活跃门禁仍用 Python heredoc 做 stra… | FIXED | evidence 336：修前 coverage-swee… |
| H19 | 设备探针的 device_path() 只匹配裸 files/rootfs-full，… | FIXED | evidence 336 §4：run-path-race… |
| H20 | 13-egress.sh 仍用 Python socket，并把 awk/curl/p… | FIXED | evidence 337：修前真机 awk: 未找到命令、… |
| H21 | 05-mount-audit.sh 仍用 Python 验证只读 dirfd 写入、元… | FIXED | evidence 338：修前脚本包含 12 处 pyth… |
| H22 | rt-server-parity.sh 的 26 处 python3 和 2 处 aw… | FIXED | evidence 339：修前静态计数 python3=2… |
| H23 | 把“宿主 App 没提供 X server”错误归因成 Husk 运行时缺陷，导致方针… | FIXED | b48bd56 首次把独立调试壳缺少 X server 记… |
| H24 | 35ab14a 把 Xlorie 源码、libXlorie.so、同进程 deskto… | FIXED | 修前 git ls-tree 可见 third_party… |
| H25 | syslog_libc 用固定字符串 parity: … 检查，但 openlog(3… | FIXED | evidence 341：完整日志确有 parity[18… |
| H26 | 真机 files/linux/husk/libld.so 仍是旧构建 69d591…，… | FIXED | evidence 341：第一次 make gate-a … |
| H27 | A-hw 没有先唤醒设备；ColorOS LcdOff 会冻结 App，导致相机 so… | FIXED | evidence 342：修前息屏状态 PASS=11 F… |
| H28 | GPU soak 使用 POSIX shell 的保留变量 SECONDS 传时长；M… | FIXED | evidence 342 §6：make gpu-soak… |
| H29 | 相机门禁把仓库相对 ROOTFS / LD 原样传进 adb shell，guest … | FIXED | evidence 343 §1：LD=files/husk… |
| H30 | 相机 raw 用例在 guest 启动失败后仍无条件 wait fixture hos… | FIXED | evidence 343 §2：H29 失败后继续等待 6… |
| H31 | 相机 raw fixture 会 unlink App 正在监听的 camera.so… | FIXED | evidence 344 §2：先跑相机 fixture … |
| H32 | audio-setup、audio-relay、audio-capture、audio… | FIXED | evidence 344 §3：修前新树找不到四个工具，a… |
| H33 | 能力矩阵仍把 iio-sensor-proxy D-Bus 写成 UNVERIFIED… | FIXED | evidence 344 §5：源码固定文案为 iio-s… |
| H34 | 干净安装树使用 files/clean-audio-344/* 时，多个设备探针的 d… | FIXED | evidence 345 §1：门禁 A 已 PASS=3… |
| H35 | 活动 rootfs 选择器之外，音频、输入、编码器、AHB、视频桥、呈现和能力镜像仍硬… | FIXED | evidence 348 §1：10 个 app 侧路径仍… |
| H36 | Husk App 当前没有自己的 X server；Husk 用户态执行 gnome-… | OPEN | evidence 349 §4：PRoot 同探针 3 次… |
| H37 | 两次 loader 构建产出不同字节（869888 vs 738816），其中一份 p… | OPEN | evidence 350 §3：67f543b9 返回 /… |
| H38 | 宿主 X server 宣告 MIT-SHM 却拒绝 ShmAttach，gnome-… | OPEN | evidence 350 §4：Mtk-ERROR ...… |
| H39 | 升级替换工具后 usr/bin/passwd 等名字消失（只保留 usr/sbin 链… | FIXED | evidence 350 §2.5：initializat… |
| H40 | 宿主自带 doro-gpu-run 把 VK_ICD_FILENAMES 钉死在旧文件… | FIXED | evidence 351 §1：脚本第 92 行原文；两份… |
| H41 | 桌面冷启动 14.7 s：gnome-shell 创建到首帧 9.7 s，其中 **4… | FIXED | evidence 353：5 次冷启 tap_to_sur… |
| H42 | 会话退出不清理 $XDG_RUNTIME_DIR：gvfsd/ 里积压 146 个历史… | OPEN | evidence 353 §4b：设备上 ls tmp/r… |
| H43 | 设备与树里留着实验期的过期 ICD/驱动副本：husk_panvk_nosleep_t… | OPEN | evidence 357 §7：ls usr/share/… |
| H44 | --upgrade 安装器把**自己**当残留会话 kill 掉：它按 cmdline… | FIXED | evidence 358 §5：2026-11-27 实测… |
| H45 | 空目录 --fresh 安装必失败在 pass 2：库搜索路径在解包前按“目录是否存在… | FIXED | evidence 358 §8：usr/bin/env: … |
| H46 | make test-device 永远报 adb: device 'EV' not f… | FIXED | evidence 359/358：make test-de… |
| H47 | 01-functional-matrix.sh 用 rm -rf /tmp 清场，而桌… | FIXED | evidence 359 §2：跑完该脚本后 xdpyin… |
| H48 | Android 侧 adb shell input tap 完全不进宿主窗口：同一坐标… | OPEN | evidence 359 §2/§5：(60,1030)、… |
| H49 | 应用盘（左下角 Ubuntu 按钮）里每个工作区缩略图的右端缺一块**纯黑楔子**，连… | OPEN | evidence 361：连开两次截图字节相同、近黑 0.… |
| H50 | 宿主每次起桌面都重写 /etc/profile.d/doro-gpu.sh，并按 /e… | OUT-OF-SCOPE | evidence 361 §8：bash -lic 里读到… |
| H51 | /proc/self/exe 的 **execve** 没修（readlink 修过）… | FIXED | evidence 362：bash -c 'exec /p… |
| H52 | glGenerateMipmap 生成的 mip 各级内容本身就是坏的：每级右端都有一… | OPEN | evidence 363 §3：scale-wedge d… |
| H53 | 两处口径错误：COGL_DEBUG=no-auto-mipmap / COGL_DRI… | CLOSED | evidence 363 §6：会话 maps 是 mut… |
| H54 | 一次「GNOME 已退出，退出码 139」被复现，但**是我自己的实验补丁造成的**，… | FIXED | evidence 364 §1–2：22:36 连开 12… |
| H55 | 怀疑存在“只设了 32 个”的上限导致桌面崩 | FIXED | evidence 364 §3：runtime/crate… |
| H56 | 139 没有任何现场记录：崩溃处理器用栈上缓冲，栈一溢出就在处理器里二次崩溃，日志里一… | FIXED | evidence 364 §4：本次崩溃前后 nr-sig… |
| H57 | 应用盘缩略图黑楔子（桌面开 GPU 加速才出现）：PanVK 的 vkCmdBlitI… | FIXED | evidence 365 §1–2：clearonly 清… |
| H58 | 三条门禁脚本自己制造假失败：20-tree-integrity 的 DING 判据只认… | FIXED | evidence 366 §7：装着已修 DING 的树被… |
| H59 | 硬件门禁 A-hw 在测试宿主上是“权限 + 桥”两件缺失，而此前只记成“没授权”：宿… | 权限侧 FIXED | evidence 366 §9：仅加 debug 变体的 … |
| H60 | 相机预览能出画面，但**逐帧刷新、帧率极低**，桌面里不可用 | OPEN | 用户现场反馈（2026-11-28）：预览可见但一帧一帧跳… |
| H61 | 标准 VA-API 视频路径（gst-vaapi → vaapih264dec → b… | OPEN | evidence 367-video-va-ab-2026… |
| H62 | VA 相关资产只在设备 rootfs 里，**没进 dist tar、也没进 App … | OPEN | 2026-11-28 核对：dist/husk-arm64… |
| H63 | X11 → WD 迁移（换掉 X11 合成/呈现链路） | DEFERRED | 用户 2026-11-28 明确：该项**延后**，不在 … |

## 附 · Adreno 桌面「块状错色 / 窗口不合成」与 Mali 修补差异（2026-11-28 实测）

> [!WARNING]
> **本节写于 2026-11-28 上午（预编译 freedreno 阶段），当天下午已被推翻，只作历史现场保留，不要当现状引用。**
> Turnip 已改成**源码构建**并上机：`vendor/turnip/d211037c-adreno-825/`，SHA-256 `35577a1a…89ad75f5`，
> evidence **371**，总账见 §9.5 第 3 行。因此下面表格里的「预编译 / 无源码 / 无对应修补」与结尾那句
> 「必须把 Turnip 也变成我们源码构建」**都已完成**：壁纸块状错色消失、GNOME 不再 139、
> `zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`、glxgears 607–997 FPS。
> 仍然成立的只有一条：**客户窗口内容上屏没有通路**，原因已定位到宿主 X server 取不到 DRM 渲染节点
> （DRI3 报 `Could not get DRI3 device`），见 §21 最后一行。

**为什么天机修好了、高通像什么都没修：不是环境变量差，是驱动源码补丁的有无。**

| 项 | 天机（Mali G77 / PanVK） | 高通（Adreno 825 / Turnip+gallium） |
|---|---|---|
| 驱动来源 | `vendor/panvk/fristonerr-1.2.0-mali-g77/`，**我们自己源码构建**，有 `PROVENANCE.md` + `SHA256SUMS` | `libvulkan_freedreno.so`（Turnip）、`libgallium-27.0.0-devel.so` 均为**预编译**，无源码、无补丁 |
| 块状缺色/楔子 | H57 **FIXED（源码）**：`vk_meta_draw_volume()` 6 顶点/2 三角形在 Mali v9 jm 上第二三角形画歪 → 目标区域永不着色；改为单三角形 + 精确 scissor，近黑 0.1490→0.0000 | **无对应修补**（同一份 `vk_meta` 共用代码，但没做 Turnip 构建） |
| 冷启动 2s 空转 | H41 **FIXED（源码）**：kbase 建 context 后 `nanosleep(2s)` 改 `PANVK_KBASE_WARMUP_MS` | 不适用（KGSL） |
| 环境注入 | G1/G3：loader 注入 `gpu-env`，`PANVK_DXVK_COMPAT=0` | 同一注入机制可用；本轮实测 `@GPU_FAMILY` 写错一个字符 → **整份 gpu-env 被静默丢弃**（`gpuenv.rs`: `SLOT_N=0; return`） |

单变量实测（本机、只改 gpu-env、每次重启桌面 + 截图）：

| 后端 | 壁纸块状错色 | 面板/dock | 桌面图标(DING) | 说明 |
|---|---|---|---|---|
| llvmpipe | 无 | 正常 | 正常 | 对照组 |
| freedreno 原生 | **有**（x=848/896/1712，16/32px 块，隔行交替） | 正常 | **不画** | 上游 Mesa #16184 / #16189 同类：a7xx/kgsl 块状错色，**所有 FD_MESA_DEBUG 均无效**，同机 zink 干净 |
| freedreno + `notile` | **更糟**（错色列变多） | — | — | 证明缓冲本身是 tiled/压缩布局，强推线性更不对 |
| zink(Turnip) | **无** | **窗口内容不合成**（dock/面板黑） | 不画 | `TP_UBWC_FLAG_HINT=1` 后壁纸仍干净、窗口仍不合成 |
| zink + `GSK_RENDERER=cairo` | 无 | 同上 | 仍不画 | 已确认该变量进了 DING 的 environ；plank(2 进程)、ding 均存活 → **不是 GTK 渲染器，是窗口内容合成层** |

已排除（全部单变量）：UBWC(`noubwc`)、`COGL_DEBUG=disable-pbos`、Cogl 全套纹理/读回优化(`disable-atlas/shared-atlas/fast-read-pixel/npot-textures`)、`CLUTTER_PAINT=disable-clipped-redraws`、DING 关闭、宿主拷贝层（guest 内 XGetImage 与 SurfaceFlinger 两路一致，说明写入布局与读取假设不符）。

**结论（判断）**：高通要真正对齐天机的水平，必须把 Turnip 也变成「我们源码构建 + 同族补丁」，否则只是换后端在两种坏法之间跳。
