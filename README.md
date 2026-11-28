<!-- 首屏：标题、图标、居中简介、技术栈与站内导航。项目正文从「目录」开始。 -->
<h1 align="center">Husk</h1>

<p align="center">
  <img src="docs/assets/brand/husk-mark-hexagon-h-512.png" width="128" alt="Husk">
</p>

<p align="center">
  <strong>Android 上的原生 Linux 运行时。</strong><br>
  在 Android 内核上直接运行 glibc Linux 用户态；不使用 PRoot 跟踪器，也不是第二套虚拟机。
</p>

<p align="center">
  <img alt="Runtime: Husk" src="https://img.shields.io/badge/runtime-Husk-111827?style=flat-square">
  <img alt="Userland: glibc" src="https://img.shields.io/badge/userland-glibc-0F766E?style=flat-square">
  <img alt="Ubuntu 24.04" src="https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white">
  <img alt="GNOME 46 / X11 host" src="https://img.shields.io/badge/Desktop-GNOME%2046%20%2F%20X11-4A86CF?style=flat-square&logo=gnome&logoColor=white">
  <img alt="PanVK + Turnip / Zink" src="https://img.shields.io/badge/GPU-PanVK%20%2B%20Turnip%20%2F%20Zink-7C3AED?style=flat-square">
  <img alt="Android ARM64" src="https://img.shields.io/badge/Platform-Android%20ARM64-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="Rust 1.75+" src="https://img.shields.io/badge/Rust-1.75%2B-DEA584?style=flat-square&logo=rust&logoColor=white">
  <img alt="License: Apache-2.0" src="https://img.shields.io/badge/License-Apache--2.0-2563EB?style=flat-square">
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="README_EN.md">English</a> ·
  <a href="docs/ARCHITECTURE.md">技术架构</a> ·
  <a href="CHANGELOG.md">更新记录</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a> ·
  <a href="SECURITY.md">安全策略</a>
</p>

---

## 目录

- [跑起来的前提](#跑起来的前提)
- [概览](#概览)
- [安装与启动](#安装与启动)
- [运行方式](#运行方式)
- [工作原理](#工作原理)
- [从源码构建](#从源码构建)
- [运行能力](#运行能力)
- [硬件接口](#硬件接口)
- [交付内容](#交付内容)
- [仓库结构](#仓库结构)
- [性能基准](#性能基准)
- [当前状态](#当前状态)
- [已知限制](#已知限制)
- [常见问题](#常见问题)
- [文档](#文档)
- [参与贡献](#参与贡献)
- [许可](#许可)
- [致谢](#致谢)

## 跑起来的前提

> [!IMPORTANT]
> 下面三条是硬前提，缺一条就跑不起来。其它条件只影响功能完整度。

| # | 硬前提 | 不满足时的样子 | 怎么自查 |
|---|---|---|---|
| 1 | **arm64（aarch64）**：loader 的 GOT 改写和 syscall 直通只对这一 ABI 成立 | `Exec format error` | `uname -m` 输出 `aarch64` |
| 2 | **目录同时可写、可执行、被沙箱允许**：loader 和 guest 二进制都要能被 `exec` | 看起来像 loader 损坏，实际是 `noexec`/权限问题 | 直接执行 loader，应返回 `missing program name` |
| 3 | **厂商没有额外收紧 `untrusted_app` 的 seccomp / SELinux**：`execve`、`clone`、`open*` 必须能直达内核 | `Bad system call`，进程被杀 | 运行 `tools/device-tests/01-functional-matrix.sh`，或先跑 `/usr/bin/true` |

参考配置：arm64、Android 13、kernel 4.19.191、4 KiB 页、无 root、无 Shizuku、未解锁
Bootloader。16 KiB / 64 KiB 页只在 QEMU 上验证过，真机状态是 UNVERIFIED。

## 概览

Husk 让一棵真实的 Linux ARM64 用户态作为普通 Android 应用进程运行。glibc、包管理器、编译器、
shell 和服务直接向 Android 内核发系统调用，不需要 root、虚拟机、namespace，也不逐条
`ptrace` 拦截 syscall。

路径改写只发生在装载阶段：loader 把动态对象里的路径函数入口改到 Husk path-shim，shim 把
guest 绝对路径转换成应用私有目录里的真实路径，然后调用真正的 libc/内核入口。程序开始执行后，
自己的 syscall 原样进入内核。

PRoot 每次经过路径相关的 syscall 都要停下来改写；Husk 只在装载时改写一次 GOT。路径和 syscall
越密集，这个差别越明显；大块顺序 I/O 主要由存储和内核决定，差距会消失。

参考环境是 Ubuntu 24.04、glibc 2.39、arm64 Android 13 和 Mali-G77。具体机型、内核、页大小
与证据入口写在 [`docs/STATUS.md`](docs/STATUS.md) 和 [`docs/RESULTS.md`](docs/RESULTS.md)；
这些是实测条件，不是产品绑定。

## 安装与启动

### App 资产部署

生产路径是把 `dist/husk-arm64.tar.gz` 打进 APK assets，首次启动时解压到应用私有目录，再执行
安装器准备 rootfs。安装器负责：

- 安装 `libld.so`、打过补丁的 `libc.so.6` 和运行时工具；
- 把绝对符号链接改成相对链接并逐项校验；
- 替换 `ldconfig`、用户与组管理、`su` 等不可直接工作的发行版入口；
- 创建 `run`、`tmp`、`dev/shm` 等 guest 目录；
- 写入 `etc/husk/runtime-identity`，记录 version、commit 与关键资产 SHA-256；
- 升级时重跑 guest 侧步骤，不重新解压整棵 rootfs。

### 手工安装

```sh
tar xzf husk-arm64.tar.gz
cd husk
sh install-husk.sh \
  --rootfs /path/to/ubuntu-rootfs.tar \
  --dest /path/to/app-private/rootfs \
  --loader ./libld.so
```

安装后的会话启动契约：

```sh
NR_ROOTFS=<rootfs> \
NR_LD=<loader> \
NR_LIBRARY_PATH=<aarch64-linux-gnu:usr/lib/aarch64-linux-gnu:lib:usr/lib> \
  <loader> --library-path "$NR_LIBRARY_PATH" usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root /bin/sh
```

完整目录、升级、libc 恢复和故障排查见 [`docs/RUNNING.md`](docs/RUNNING.md)。

## 运行方式

Husk 以运行时资产交付，由 LinuxHub 2.0 放进应用私有目录并启动。LinuxHub 2.0 同时提供窗口
系统、输入注入和 Surface 呈现；`dist/husk-arm64.tar.gz` 不包含 X server，也不包含桌面合成器。

```text
LinuxHub 2.0
  ├─ 应用容器、权限与窗口呈现
  └─ Husk runtime
       ├─ loader + path-shim
       ├─ guest rootfs 安装与修补工具
       ├─ GPU 默认值与随包驱动（Mali→PanVK，Adreno→Turnip）
       └─ 相机、音频、视频、传感器、定位接口
```

终端、编译器、包管理和 GPU 计算可以脱离桌面单独验证；GNOME 桌面是否完整，还取决于宿主侧
窗口系统、输入和呈现链是否接通。

## 工作原理

```text
Android App
  │
  ▼
Husk loader
  ├─ 校验并装载 guest ELF
  ├─ 解析 PT_INTERP、shebang 和嵌套 exec
  ├─ 改写动态对象的路径函数 GOT
  └─ 注入 GPU / locale 等运行时默认值
        │
        ▼
Husk path-shim
  ├─ guest 绝对路径 → 应用私有 rootfs 路径
  ├─ 符号链接、`..` 边界与 rootfd 语义
  └─ 调用真正的 libc / syscall
        │
        ▼
Android Linux 内核
```

关键点：

- loader 内嵌 path-shim，不依赖外部预加载环境。
- `execve` 由 loader 自己解析，嵌套执行仍回到同一套装载流程。
- libc 只补 Android/glibc 边界必需的两类改动；发行版二进制不为 Husk 重写。
- 运行时不做 syscall 代理，不启动常驻翻译进程。
- 静态 ELF、直接 raw syscall、以及没有经过 loader 的进程不受路径改写控制。

更完整的装载、GOT、路径解析与已知缺口见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 从源码构建

```sh
# loader，需要 Android NDK
NDK=$ANDROID_HOME/ndk/<ver>/toolchains/llvm/prebuilt/<host>/bin \
  sh tools/loader/build-embedded-loader.sh

# Rust 运行时与工具
cargo build --release --manifest-path runtime/Cargo.toml

# 本地检查
make check
cargo test -p gpu-env

# 设备门禁（连接设备后）
make test-device

# 只生成运行时发行包
NDK=<ndk>/bin make dist
```

CI 把格式检查、Rust 交叉检查、Clippy、shell 语法、文档链接、版本一致性和运行时包边界拆成
独立作业。编译通过不等于设备可用；最终结果以 [`docs/RESULTS.md`](docs/RESULTS.md) 和原始
evidence 为准。

## 运行能力

| 能力 | 现状 | 说明 |
|---|---|---|
| aarch64 glibc 用户态 | 可用 | bash、coreutils、Python、GCC、make 已在参考树中执行 |
| 动态解释器、shebang、嵌套 exec | 可用 | 子进程重新进入同一 loader |
| 路径与符号链接 | 可用 | guest 绝对路径落在 rootfs；绝对链接由安装器规范化 |
| PTY、信号、进程视图 | 可用 | 门禁 A 覆盖管道、子 shell、进程可见性和 SIGSYS |
| apt / dpkg | 可用 | 安装、配置、包记录和 libc 升级后的恢复链已实测 |
| 用户与组管理 | 可用 | `husk-usermgr` / `husk-su` 替代不可用的发行版工具 |
| 中文 locale | 可用 | 默认 `zh_CN.UTF-8`，显式英文设置不会被覆盖 |
| GPU 默认值 | 可用 | loader 从 `/etc/husk/gpu-env` 注入 ICD、Zink 和 GLES 配置 |
| GPU 直连 | 可用 | 两条独立链：Mali（kbase）经 `/dev/mali0` 走 PanVK + Zink；Adreno（KGSL）经 `/dev/kgsl-3d0` 走源码构建的 Turnip + Zink |

## 硬件接口

分类只有四种：直连、中转、不需要、权限或厂商限制。

| 设备类 | 分类 | guest 接口 | 当前验收 |
|---|---|---|---|
| GPU | **直连** | Mali：`/dev/mali0` + PanVK；Adreno：`/dev/kgsl-3d0` + Turnip | Mali-G77：枚举、compute、离屏 graphics、EGL/GL、2400×1080 读回、4×300 s 并发长稳全过。Adreno 825：Turnip 源码构建，`zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`、GL 4.6 / GLES 3.2、glxgears 607–997 FPS、壁纸块状错色消失；**客户窗口内容上屏未通**，卡在宿主 X server 取不到 DRM 渲染节点（DRI3）——外部阻塞，见 LEDGER §21 |
| 相机 | **中转** | V4L2 `/dev/videoN` facade | Camera2 前后摄、V4L2/GStreamer fixture、read/readv/mmap/拍照/录像数据链通过；桌面预览帧率过低，未达可用 |
| 音频 | **中转** | PulseAudio → Rust relay → AAudio | 输出和采集得到真实 PCM；`/dev/snd` 在应用域不能直开 |
| 视频解码 | **中转** | VA-API → bridge → MediaCodec | 720p Constrained Baseline 通过；1080p 和 High profile 在 12–25 帧后停摆，桌面播放器当前不可用 |
| 传感器 | **中转** | IIO sysfs 影子树 ← Android NDK sensor | 加速度、磁力、陀螺仪、环境光、距离五类可读，三套 IIO 视图一致 |
| 定位 | **中转（仅 last-known）** | gpsd JSON over Unix socket | `VERSION` / `DEVICES` / `WATCH` / `POLL` / `TPV` 已通，实测 `mode=3`；持续定位和 GNSS 原始测量未实现 |
| 显示 | **应用侧中转** | `AHardwareBuffer` → dma-buf → `SurfaceControl` | 应用侧接管段为零拷贝；窗口内容进入 X server 仍存在回读与 SHM 拷贝 |
| USB / 蓝牙 | **权限或厂商限制** | 候选标准接口 | 当前未完成全链路验收 |
| NFC / 指纹 | **不需要** | — | 没有可复用的标准 Linux 设备语义 |

**只有 GPU 是直连。** 相机、音频、视频、传感器、定位和显示都是中转，不能宣传成“全部硬件
直连”，也不能把整条呈现链写成零拷贝。逐项理由和原始错误见
[`docs/design/hardware-interface-map.md`](docs/design/hardware-interface-map.md)。

GPU 内部是**两条互不覆盖的驱动链**，不是「一份驱动适配两家」：

| | Mali（MediaTek，kbase） | Adreno（Qualcomm，KGSL） |
|---|---|---|
| 设备节点 | `/dev/mali0` | `/dev/kgsl-3d0` |
| Vulkan 驱动 | PanVK，`vendor/panvk/`，源码构建 | Turnip，`vendor/turnip/`，Mesa `d211037c` 源码构建 |
| canonical ICD | `husk_panvk_guest.json` | `husk_turnip_guest.json` |
| `gpu-env` 家族标记 | `@GPU_FAMILY=mali-kbase` | `@GPU_FAMILY=adreno-kgsl` |
| GL 前端 | Zink | Zink（原生 freedreno 实测壁纸成块状错色，只作回退） |

安装器按宿主实际存在的节点判家族，只解压对应那一份驱动、只落那一份 ICD，另一条链不落地。
两条链共用同一份 `vk_meta` 源码补丁（H57：blit 单三角形 + 精确 scissor），但驱动二进制各自独立。

## 交付内容

唯一运行时资产是 `dist/husk-arm64.tar.gz`。包内包含 loader、path-shim、glibc 补丁、安装器、
guest 工具、GPU 默认值和随包驱动（Mali→PanVK，Adreno→Turnip，按宿主节点二选一）；不包含 X server、
桌面合成器或整棵发行版 rootfs。

```text
usr/bin/
  libld.so                 loader + path-shim
  libc.so.6                按 glibc 基线校验并修补
  husk-ldconfig            guest ldconfig
  husk-usermgr             用户与组管理替身
  husk-su                  su 替身
  husk-symlinks            绝对符号链接规范化
etc/husk/
  gpu-env                  GPU 默认环境
  runtime-identity         version / commit / 关键 SHA-256
usr/lib/aarch64-linux-gnu/
  libvulkan_panfrost_husk.so        Mali（kbase），随 vendor/panvk/
  libvulkan_freedreno_husk.so       Adreno（KGSL），随 vendor/turnip/
usr/share/vulkan/icd.d/
  husk_panvk_guest.json             Mali canonical ICD
  husk_turnip_guest.json            Adreno canonical ICD
```

设备上重算 `runtime-identity` 中的 SHA-256 并逐项比对，才能证明当前运行的是这份包，而不是
设备上残留的旧资产。

## 仓库结构

```text
runtime/crates/          loader 侧 path-shim、exec、PTY、信号（Rust，no_std）
runtime/crates/nr-tools/ ELF 扫描、修补、嵌入和 libc interpose
tools/loader/            loader 入口与 hook 汇编
tools/guest/             rootfs 安装器、会话脚本、发行打包
tools/guest-config/      libc 补丁、ldconfig、符号链接处理
tools/device-tests/      设备门禁 A、A-hw、GPU、readback、soak
tools/bench/             三运行器轮转基准
docs/design/evidence/    每个结论对应的设备原始输出
```

## 性能基准

2026-11-24 使用同一台手机、同一份 rootfs、同一个 App 沙箱，三个运行器轮转执行 5 轮。下表是
中位数；Husk 与 PRoot 的差别只来自路径层实现。

| 工作量 | Husk | PRoot | Husk 相对 PRoot |
|---|---:|---:|---:|
| `stat` × 20,000 | 650 ms | 3,734 ms | **5.7×** |
| `open` + `close` × 20,000 | 1,252 ms | 8,481 ms | **6.8×** |
| `make -j4`，200 目标链接 | 5,194 ms | 24,182 ms | **4.7×** |
| 顺序写 256 MB | 1,294 ms | 1,321 ms | **1.0×** |

优势集中在路径和 syscall 密度高的任务；顺序大块 I/O 基本持平。完整八维表、其他运行器、
热漂移条件、冷启动和不利数字见 [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)。

## 当前状态

仓库已进入 `0.0.38` 开发周期。最近一轮完整设备门禁来自 `0.0.37` 收尾批次，运行身份、GPU、
桌面崩溃修复、安装器和发行包都已留证；相机预览和标准 VA-API 1080p 仍是 FAIL，已登记到后续
版本。

| 项目 | 结果 | 证据 |
|---|---|---|
| 安装器 `--upgrade` + 运行身份自证 | PASS=12，FAIL=0 | `367-runtime-upgrade-20261128` |
| canonical ICD / 旧 ICD 禁选 | PASS=15，FAIL=0 | `367-runtime-upgrade-20261128` |
| GPU 全局继承 | PASS=3，FAIL=0 | `367-gpu-audit-final-20261128` |
| 2400×1080 读回 | PASS=19，FAIL=0 | `367-gpu-audit-final-20261128` |
| GPU 4×300 s soak | PASS=19，FAIL=0；fd 7→7，RSS +244 kB，errors=0 | `367-gpu-soak-final-20261128` |
| 桌面 Snapshot / 139 | 20 s 无 139 | `367-snapshot-20s-20261128` |
| A-hw 相机 / 麦克风 / 传感器 / 定位 | PASS=15，FAIL=0 | `367-a-hw-final-20261128` |
| 相机桌面预览 | **FAIL**：能出画面，但逐帧刷新、帧率极低 | 现场反馈，待量化 |
| 标准 VA-API 视频 | **FAIL**：720p 通过；1080p / High profile 12–25 帧后停摆 | `367-video-va-ab-20261128` |
| 运行时发行包审计 | PASS | `367-dist-0.0.37-20261128` |

未在设备上复跑的项目继续写 UNVERIFIED；编译成功、驱动加载、element 注册都不会被当成功能
通过。完整结果见 [`docs/RESULTS.md`](docs/RESULTS.md)。

## 已知限制

- **不是安全沙箱。** 静态 ELF、raw syscall 和不经过 loader 的进程不受路径替换控制；不要把
  Husk 用来隔离恶意代码。
- **窗口呈现不是全链路零拷贝。** 应用侧 `AHardwareBuffer → SurfaceControl` 是零拷贝；窗口
  内容进入 X server 仍会回读和拷贝，DRI3 在应用域没有可用 render node。
- **相机预览不可用。** 数据链能出帧，但桌面刷新率过低，已列为 0.0.38 后续项。
- **标准 VA-API 1080p 不可用。** 720p 通过，1080p / High profile 会停摆；相关插件和工具也还
  没有全部进入发行包。
- **Adreno 桌面还不能用。** 驱动链（KGSL → Turnip → Zink）已在 Adreno 825 真机跑通，
  GL 4.6 / GLES 3.2、glxgears 607–997 FPS；但客户窗口内容上屏不通——宿主 X server 拿不到
  DRM 渲染节点，DRI3 报 `Could not get DRI3 device`，mutter 无法把窗口合成进场景。
- **平台覆盖有限。** 16/64 KiB 页真机、其他 Android 版本和厂商 SELinux/seccomp 策略仍未验证。
- **桌面依赖应用侧集成。** Husk 发行资产不包含 X server 或桌面合成器。

更完整的不工作项和原因见 [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md)。

## 常见问题

**需要 root 或解锁 Bootloader 吗？** 不需要。Husk 运行在普通 `untrusted_app` 权限内。

**这是容器还是虚拟机？** 都不是。没有 namespace、cgroup、虚拟机或 syscall 跟踪器；guest 和
普通 Android 应用使用同一个内核。

**为什么路径密集任务快很多？** PRoot 每次路径 syscall 都要 `ptrace` 往返；Husk 只在装载时
改写 GOT，运行时不再为每条 syscall 加一层。

**为什么 `apt-get update` 只快约 1.1×？** 它主要受镜像、网络和 dpkg 自身工作限制，不是纯路径
查找负载。基准照实写。

**为什么顺序 I/O 没有明显提升？** 大块顺序读写主要由存储和内核决定，路径拦截不是瓶颈。

**能跑 Debian / Fedora / Alpine 吗？** 当前只完整验证 Ubuntu 24.04 / glibc 2.39。Alpine 使用
musl，是另一套装载和符号问题；换 rootfs 必须重新验证。

**为什么 rootfs 还要打补丁？** Android 环境有两个额外边界：libc 内部存在不经过 GOT 的路径
调用；rootfs 里的绝对符号链接会按 Android 根解析。安装器负责补齐这些边界。

**能在 Termux 里跑吗？** 不能，也不支持。Termux 的目录、依赖和应用私有路径模型不满足 Husk
的运行契约。

**为什么 README 里还有 FAIL？** 因为相机预览和 VA-API 1080p 当前确实没达到可用标准。把失败
藏起来只会让发布结果失真。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | loader、GOT、shim、exec 与已知缺口 |
| [`docs/RUNNING.md`](docs/RUNNING.md) | 安装、升级、会话契约与排障 |
| [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) | PRoot 对比、完整表格、机制与代价 |
| [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) | shell、工具链、系统服务和浏览器边界 |
| [`docs/design/hardware-interface-map.md`](docs/design/hardware-interface-map.md) | GPU、相机、音频、视频、传感器、定位等接口分类 |
| [`docs/STATUS.md`](docs/STATUS.md) | 当前设备与安装树状态 |
| [`docs/RESULTS.md`](docs/RESULTS.md) | 门禁矩阵和实测结果 |
| [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) | 已知限制与不能宣称的内容 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更与延期账 |
| [`ROADMAP.md`](ROADMAP.md) | 已交付范围与下一步 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 构建、测试、发布与提交规范 |
| [`SECURITY.md`](SECURITY.md) | 漏洞范围与私密上报方式 |

## 参与贡献

欢迎 issue 和 pull request。提交前先读 [`CONTRIBUTING.md`](CONTRIBUTING.md)，并运行与改动对应
的本地检查和设备门禁。任何性能结论都必须带 `docs/design/evidence/` 下的原始输出；不利数字
不能删除或改成推测值。

安全问题不要公开贴利用细节，按 [`SECURITY.md`](SECURITY.md) 私密上报。

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)。第三方组件、glibc 构件与商标声明见
[NOTICE](NOTICE)。

## 致谢

Husk 的 path-shim 思路与早期验证受 [PRoot](https://proot-me.github.io/) 启发。两者实现不同：
PRoot 在运行时逐条拦截路径 syscall，Husk 在装载时改写 GOT。基准与限制以
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)、[`docs/RESULTS.md`](docs/RESULTS.md) 和
`docs/design/evidence/` 为准。
