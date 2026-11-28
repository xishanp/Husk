# 当前状态

最后核验：2026-11-28（CST）
参考设备（两条 GPU 链各自的参考机）：

- MediaTek：RMX3357 / MT6893 / Mali-G77 MC9 / Android 13 / kernel 4.19.191 / arm64 / 4 KiB 页
- Qualcomm：OPPO PLE110 / SM8735 / Adreno 825 / Android 16（SDK 36）/ kernel 6.6.118 / arm64 / 4 KiB 页
运行域：`untrusted_app`，无 Root、无 Shizuku、未解锁 Bootloader、无硬件虚拟化
宿主 App：LinuxHub 2.0 的 Husk 运行时 `com.linuxhub.myth.husk`

本文只记录**当前代码和当前设备上已经复验过的状态**。历史版本变化见
[`CHANGELOG.md`](../CHANGELOG.md)，原始设备输出见 [`design/evidence/`](design/evidence/)。

## 1. 交付边界

Husk 是 Linux ARM64 用户态运行时，不是桌面发行版，也不是恶意代码安全沙箱。

- 交付资产是 loader、path-shim、glibc 补丁、rootfs 安装器、设备接口与 GPU 默认值。
- 资产必须放进 Android 应用私有目录，和 PRoot 一样由宿主 App 解压、安装并启动。
- App 或桌面环境负责窗口系统、输入注入和显示合成；Husk 的运行资产不包含 X server。
- 静态 ELF、raw syscall、不经过 loader 的进程不受 GOT 改写控制，不能用来隔离不可信代码。

## 2. 最终安装树

当前最终树由 `release-tree-v2.tar.gz` 在空目录安装产生，并接入 App 的正式入口：

```text
files/rootfs-full -> release-tree-final/root
```

关键结果：

| 项目 | 结果 | 证据 |
|---|---|---|
| 安装器退出码 | `INSTALL_RC=0`（`--upgrade`，0.0.37 发行包） | 358 |
| Tree Integrity | `PASS=14 FAIL=0` | 358 |
| Gate A | `PASS=38 FAIL=0 SKIP=0` | 358 |
| A-hw | `PASS=4 FAIL=11` —— **外部阻塞**：相机/麦克风/定位未授权，宿主未建 `/run/husk/*.sock` | 358 |
| GPU loader defaults | `PASS=9 FAIL=0 SKIP=0` | 358 |
| readback 19 项 | `PASS=19 FAIL=0`；`READBACK_AUDIT PASS=6 FAIL=0` | 358 |
| ICD canonical | `PASS=15 FAIL=0`（`24-icd-canonical.sh`） | 358 |
| `--upgrade` 安装 | `RC=0`（两次），identity 六项一致 | 358 |
| `--fresh` 空目录安装 | `RC=0`（stock `ubuntu-base-24.04.3`，28 MB）；`TREE_INTEGRITY 10/4`、`Gate A 31/2/2`，失败项全是精简基础包缺 `locales`/`gdk-pixbuf`/`shared-mime-info` | 358、359 |
| `make test-device` | `UNIT_TESTS: PASS`；`01-functional-matrix` 31/0；`16-umount-legacy` 12/0 | 359 |
| dpkg 记录 | 807 个 installed 包 / 807 个 `.list` | 308 |
| locale | `LANG=zh_CN.UTF-8`，413 个 zh_CN `.mo` | 308 |

0.0.37 这一轮的树是发行包 `--upgrade` 装出来的
`files/linux/distributions/ubuntu-24.04/rootfs`，运行身份写在 `etc/husk/runtime-identity`
（version 0.0.37 / loader `67f543b9…` / PanVK `f73600da…`），门禁 A 38/0/0 全过。
A-hw 的 11 条失败全部落在“没有人授权 + 宿主没有 socket”两件事上，不是硬件坏了：
`RECORD_AUDIO`/`CAMERA`/`ACCESS_COARSE_LOCATION` 都是 `<absent>`，`/run/husk/` 下一次只有
`ipc/` 和 `mounts`。相机 V4L2/GStreamer fixture（不需要权限）是 `camera-fixture: PASS`。

## 3. Linux 用户态

| 能力 | 状态 | 说明 |
|---|---|---|
| aarch64 glibc 用户态 | 已验证 | glibc 2.39 参考树可启动 bash、coreutils、Python、GCC、make |
| ELF 装载与嵌套 `exec` | 已验证 | 动态解释器、shebang 和嵌套 exec 回到同一 loader |
| 路径语义 | 已验证 | 绝对路径落到 guest root；绝对符号链接由安装器改为相对链接 |
| PTY、信号、进程视图 | 已验证 | 门禁 A 覆盖身份、管道、子 shell、进程可见性和 SIGSYS |
| apt / dpkg | 已验证 | dpkg 记录完整；离线树没有 apt index，在线安装需先 `apt-get update` |
| 用户与组管理 | 已验证 | `husk-usermgr` / `husk-su` 替代不可用的发行版工具 |
| 中文默认值 | 已验证 | 未显式设置 locale 时默认 `zh_CN.UTF-8`；显式英文值保留 |
| GPU 默认值 | 已验证 | loader 从 `/etc/husk/gpu-env` 注入 ICD、Zink 和 GLES 设置 |

## 4. 硬件接口

分类口径只有四种：直连、中转、不需要、权限或厂商限制。逐项原始错误与理由见
[`design/hardware-interface-map.md`](design/hardware-interface-map.md)。

| 设备类 | 分类 | guest 接口 | 当前实测 |
|---|---|---|---|
| GPU | 直连 | Mali：`/dev/mali0` + PanVK；Adreno：`/dev/kgsl-3d0` + Turnip（源码构建） | Mali-G77 MC9 枚举、compute、离屏 graphics、EGL/GL 全过。Adreno 825：`zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`、GL 4.6 / GLES 3.2、glxgears 607–997 FPS、壁纸块状错色消失（evidence 371）；**客户窗口内容上屏 FAIL**，宿主 X server 取不到 DRM 渲染节点（DRI3），见 §5.2 |
| 相机 | 中转 | V4L2 `/dev/videoN` facade | 2026-11-27 复验：A-hw 14/0；前后摄各 3 帧 1280×720 NV12；V4L2/GStreamer fixture 两档通过；crop/selection 与 monotonic PTS 已验；DMABUF、通用 controls、非整帧裁剪未支持 |
| 音频 | 中转 | PulseAudio → Rust relay → AAudio | 输出与采集真实 PCM；采集探针 196,608 bytes、`peak=285` |
| 视频解码 | 中转 | VA-API → bridge → MediaCodec | 标准 VA-API 路径（gst-vaapi/`vaapih264dec`）720p 全片 PASS，1080p 与 High profile 在 12–25 帧后停摆 **FAIL**（evidence `367-video-va-ab-20261128`） |
| 传感器 | 中转 | IIO sysfs 影子树 ← `ASensorManager_*` | 加速度、磁力、陀螺仪、环境光、距离五类可读；`iio-sensor-proxy` 已发布 `net.hadess.SensorProxy`，三项 Claim 与 `monitor-sensor` 真机通过（evidence 322） |
| 定位 | 中转（仅 last-known） | gpsd JSON → `/run/husk/gps.sock` ← `LocationManager.getLastKnownLocation()` | `VERSION` / `DEVICES` / `WATCH` / `POLL` / `TPV` 真机通过；撤权后缓存 FIX 清空且只回 `mode=1`；持续定位、后台定位、GNSS 原始测量 UNVERIFIED（evidence 323） |
| 显示 | 应用侧中转 | AHB → dma-buf → SurfaceControl | 3-buffer ring 与真实 `SYNC_FD` 跑到 10,000 帧；只覆盖应用侧接管段 |
| 输入 | 窗口层 | Android 输入 → 宿主 window/X11 | bridge 已实现；端到端依赖宿主窗口系统 |
| USB / 蓝牙 | 权限或厂商限制 | 宿主侧权限与回调 | 当前只支持明确的功能子集，完整链路未验收 |
| NFC / 指纹 | 不需要 | 无标准 POSIX 等价接口 | 不应为 Linux 用户态伪造 |

“直连”只用于 GPU。相机、音频、视频、传感器和定位都是明确的中转；不能写成“全部直连”。

## 5. GPU

### 5.1 Mali / kbase（MediaTek）

参考机上的 Mali/kbase 路径已经可用：

```text
plain renderer: zink Vulkan 1.3(Mali-G77 MC9 (MESA_PANVK))
NR_GPU_DEFAULT_OFF=1 -> llvmpipe
HUSK_GPU=llvmpipe -> llvmpipe
GPU_LOADER_DEFAULTS PASS=9 FAIL=0 SKIP=0
```

`glxinfo -B` 走 zink→PanVK 现在 **271–289 ms**（0.0.37 之前恒定 4275 ms）。差别来自随包 PanVK 的
kbase「2 秒热身」补丁：上游快照每建一次 context 就 `nanosleep(2s)`，一个进程建两次就白等 4 秒
（evidence 357）。补丁只清零 `.rodata` `0x53a570` 的 16 字节 timespec，渲染语义不变，
`HUSK_PANVK_KEEP_WARMUP=1` 可回退。

同一份 `gl-probe` 的重负载结果：

| 负载 | GPU | llvmpipe | 结果 |
|---|---:|---:|---|
| 2400×1080，每像素 48 次 `sin`，2 遍 | 23.8 ms/帧（41.9 fps） | 266.7 ms/帧（3.7 fps） | GPU 快 11.2× |
| 1280×720，同一负载 | 14.9 ms/帧（67.1 fps） | 101.9 ms/帧（9.8 fps） | GPU 快 6.8× |

### 5.2 Adreno / KGSL（Qualcomm，Turnip 源码构建）

驱动不再是发行版预编译 freedreno，而是我们自己的源码构建：

```text
源码      Mesa 27.0.0-devel（快照 d211037c），src/freedreno/vulkan
驱动      usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so
SHA-256   35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5（11487376 B）
ICD       /usr/share/vulkan/icd.d/husk_turnip_guest.json
配方      tools/build/build-turnip.sh；PROVENANCE 见 vendor/turnip/d211037c-adreno-825/
```

真机（OPPO PLE110 / Adreno 825 / Android 16）结果：

```text
glxinfo -B   direct rendering: Yes
             Device: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP)) (0x44030000)
             Version: 27.0.0 | GL 4.6 | GLES 3.2
glxgears     328×366，vblank off：607 / 997 / 940 FPS
maps         gnome-shell 有 7 段 libvulkan_freedreno_husk.so
device test  tools/device-tests/29-turnip-kgsl.sh：PASS=11 FAIL=0
```

- 壁纸块状错色（evidence 370 的洋红竖列）**已消失**，GNOME 不再退出 139。
- 两个构建缺陷已修并写成门禁：漏 `-Dfreedreno-kmds=kgsl` 会 0 设备 → 139（H64），
  漏 `-Dplatforms=x11` 会表面创建 `pc=0` 段错误（H65）；`audit-turnip-bundle.sh` 直接断言这两个特征串。
- **客户窗口内容上屏仍是 FAIL**：窗口都 `Viewable`，但 `XGetImage(root)` 里没有它们的像素；
  `MESA-EGL: warning: DRI3 error: Could not get DRI3 device`。app 进程只有 `/dev/kgsl-3d0`，
  没有 `/dev/dri/*`；guest 的 `/dev/dri/renderD128` 是 shim 假节点且只实现 `DRM_IOCTL_VERSION`。
  这是**宿主侧阻塞**，已记 LEDGER §21。
- 长稳 soak 因用户中止设备测试未跑，状态 **NOT VERIFIED**。

### 5.3 边界

- `PANVK_DXVK_COMPAT=1` 的 geometry shader 崩溃是已知支持边界，默认值规避不等于修复。
- GLES 3.2 依赖 `MESA_GLES_VERSION_OVERRIDE`，真实应用未完整验证。
- 窗口内容进入宿主 X server 仍是回读 + SHM 拷贝；DRI3 在当前应用权限布局下不可达。
- Adreno 的原生 freedreno（不经 Zink）仍会出块状错色，所以高通链固定 `GALLIUM_DRIVER=zink`；
  原生路径只作回退，不作为默认。

## 6. 与 PRoot 的现场对比

2026-11-27 在同一台设备、同一份测试负载上做了一次单次采样：

| 工作量 | Husk | PRoot | 结果 |
|---|---:|---:|---|
| `stat` × 20 000 | 741.2 ms | 2,338.7 ms | Husk 快 3.16× |
| `open` + `close` × 20 000 | 980.9 ms | 5,676.3 ms | Husk 快 5.79× |
| shell 循环 × 1,000 | 18.2 ms | 51.5 ms | Husk 快 2.84× |
| `/bin/true` × 50 | 708.5 ms | 323.6 ms | **Husk 慢 2.19×** |
| 桌面冷启动（点按钮 → `SurfaceView`） | 11.13 s（3 次中位） | 9.79 s（3 次中位） | **Husk 慢 1.14×** |

短进程启动是 Husk 当前真实代价：每次都要重新装载并完成 GOT 改写。历史 5 轮轮转数据与完整
方法见 [`BENCHMARKS.md`](BENCHMARKS.md)，原始输出见 evidence 311。

## 7. 显示宿主边界

当前 Husk 运行资产没有 `Xorg`、`Xvfb` 或应用内 X server：

```text
ls: files/rootfs-full/usr/bin/Xvfb: No such file or directory
ls: files/rootfs-full/usr/bin/Xorg: No such file or directory
ls: files/rootfs-full/usr/lib/xorg/Xorg: No such file or directory
```

因此：

- Linux 用户态、设备桥和 GPU 默认值可以独立验收。
- 独立启动 GNOME/X11 桌面属于宿主 App 集成，当前为 UNVERIFIED。
- 不使用其他 App 或旧 PRoot 树的 X socket 冒充 Husk 的结果。

## 8. UNKNOWN / UNVERIFIED

- 16 KiB / 64 KiB 页真机；当前只有 QEMU 证据。
- Adreno 客户窗口内容上屏（宿主 DRI3 不可用）、Adreno 长稳 soak、其他 Android 版本、其他厂商
  seccomp/SELinux 策略。
- 持续定位、后台定位、GNSS 原始测量；USB、蓝牙的完整链路。
- 相机 DMABUF、通用 V4L2 controls、非整帧裁剪、真实 Camera2 的 GStreamer PTS、跨进程假 fd。
- 窗口内容到 X server 的零拷贝。
- 超过 300 秒的负载型 soak；现有 30 分钟为空载，GPU 有 300 秒四路并发探针。

## 9. 发布门禁

发布前必须同时满足：

```sh
make check
DEV=<serial> sh tools/device-tests/20-tree-integrity.sh
DEV=<serial> sh tools/device-tests/14-gate-a-acceptance.sh
DEV=<serial> sh tools/device-tests/17-gate-a-hw.sh
DEV=<serial> sh tools/device-tests/18-gpu-loader-defaults.sh
```

并保证 `VERSION`、`CHANGELOG.md`、APK `versionName/versionCode`、annotated tag、Release 标题、
资产名、`SHA256SUMS` 与 release audit 全部一致。编译成功或单元测试通过不能替代上述真机门禁。
