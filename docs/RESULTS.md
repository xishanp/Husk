# 实测结果

设备：RMX3357 / MT6893 / Mali-G77 MC9 / Android 13 / kernel 4.19.191 / 4 KiB 页 /
`untrusted_app`。历史型号只是参考环境，不是产品绑定。

本文只列设备上实际跑出来的结果。未验证的写在末尾，不把编译成功或旧证据当成本轮通过。

## 0. 0.0.37 门禁矩阵（2026-11-27 夜，唯一算数的当轮数据）

树：发行包 `--upgrade` 装出的 `files/linux/distributions/ubuntu-24.04/rootfs`，
运行身份 `version=0.0.37 / loader 67f543b9… / PanVK f73600da…`。

| 门禁 | 结果 |
|---|---|
| `make check` / `make test` | EXIT=0 / EXIT=0 |
| `20-tree-integrity.sh` | `PASS=14 FAIL=0` |
| `14-gate-a-acceptance.sh` | `PASS=38 FAIL=0 SKIP=0` |
| `15-gpu-global-audit.sh` | `PASS=3 FAIL=0 SKIP=0` |
| `18-gpu-loader-defaults.sh` | `PASS=9 FAIL=0 SKIP=0` |
| `19-readback-suite.sh` | `PASS=19 FAIL=0`；`READBACK_AUDIT PASS=6 FAIL=0` |
| `24-icd-canonical.sh` | `PASS=15 FAIL=0` |
| `21-gpu-soak-audit.sh`（4×300 s） | `PASS=19 FAIL=0`；四路 582 fps、errors=0、RSS 有界 |
| `run-camera-fixture.sh` | `PASS`（raw + GStreamer，640×480 与 1280×720） |
| `17-gate-a-hw.sh` | `PASS=4 FAIL=11` —— **外部阻塞**（未授权 + 宿主无 socket） |
| `make audio-audit` | `PASS=1 FAIL=3` —— 同一外部阻塞 |
| `--upgrade` 安装（最终产物 `e6d4e2c3…`） | `RC=0`，identity 六项逐项复核 |
| `make test-device` | `UNIT_TESTS: PASS`（gpu_env 6、nr_tools 7、runtime_core 0） |
| `01-functional-matrix.sh`（无会话态） | `#checks=31 fail=0` |
| `16-umount-legacy.sh` | `PASS=12 FAIL=0` |
| 干净装（stock `ubuntu-base-24.04.3` 28 MB） | `RC=0`、`bash -l` 正常；`TREE_INTEGRITY 10/4`、`Gate A 31/2/2`，4+2 条全部是精简基础包缺 `locales`/`gdk-pixbuf`/`shared-mime-info`（安装器已逐条打印原因） |
| Overview 黑色三角（10 次开关） | **未复现**：缩略图右上角近黑像素占比 0.0000，与桌面亮度均值 61.5 vs 58.4（evidence 359） |
| 应用盘缩略图黑楔子（用户指的现场） | **已修（源码级，驱动通用）**：根因是 PanVK `vkCmdBlitImage` 缩放路径的第二个三角形在 Mali v9 上被画歪；`vk_meta` 改单三角形 + 精确 scissor 后重建驱动（`.so` `5e063247…`）。现场近黑 **0.1490 → 0.0000**，`gl-probe scale-wedge` 各尺寸 `dark_cells` 全 0（evidence 365 / H57） |
| 硬件 vs llvmpipe 对照 | **外部阻塞**：宿主每次起桌面重写 `/etc/profile.d/doro-gpu.sh` 并按 `/etc/doro-gpu-mode` 钉 `frist370_execva`，树里的 gpu-env 对桌面无效（evidence 361 §8 / H50） |
| 桌面点击（`adb input tap`） | **外部阻塞**：事件不进宿主窗口；guest 内 `xdotool` 的键盘/指针路径正常（evidence 359） |
| `--fresh` 空目录安装（33 MB 精简 tarball） | `RC=0`、`bash -l` 正常；`TREE_INTEGRITY 12/2`（精简树无 gdk-pixbuf/mime 工具） |
| 完整 Ubuntu 基础包干净装 | **UNVERIFIED** —— 设备上没有 4.3 GB 基础包 |

冷启动（点“打开桌面”→ `SurfaceView`）：**11.48 / 11.13 / 11.51 s**（中位 11.13），
同机 PRoot 9.79 s。`glxinfo -B`：**271–289 ms**（0.0.37 之前 4275 ms）。
全部原始输出见 evidence 358；PanVK 2 秒热身补丁本身见 evidence 357。

## 1. 最终发行树

| 项目 | 结果 | 证据 |
|---|---|---|
| 空目录安装 | `INSTALL_RC=0` | 308 |
| Tree Integrity | `PASS=23 FAIL=0`（旧树）→ 0.0.37 树 `PASS=14 FAIL=0` | 308、310、358 |
| Gate A | `PASS=34 FAIL=0 SKIP=1`（旧树）→ 0.0.37 树 `PASS=38 FAIL=0 SKIP=0` | 310、358 |
| A-hw | `PASS=14 FAIL=0`（2026-11-27 白天，已授权环境）→ 当前测试宿主 `PASS=4 FAIL=11`（未授权 + 无 socket） | 323、358 |
| GPU loader defaults | `PASS=9 FAIL=0 SKIP=0` | 310、358 |
| dpkg | 807 installed / 807 `.list` | 308 |
| 中文 locale | 6,222,864-byte locale archive，413 个 zh_CN `.mo` | 308 |

Gate A 的 SKIP 是离线树没有 apt package index。没有把它算成 PASS。

## 2. 运行时

| 项目 | 结果 | 证据 |
|---|---|---|
| loader 启动 glibc bash | 正常，路径落在 guest 根 | 27、310 |
| 动态解释器、shebang、嵌套 exec | 正常 | 34 |
| PTY、信号、进程视图 | 门禁 A 通过 | 310 |
| apt / dpkg 元数据 | 807 包记录完整；离线 apt index 缺失 | 308、310 |
| 用户与组管理 | `useradd` / `groupadd` / `chpasswd` / `id` 通过 | 310 |
| 默认中文 locale | `zh_CN.UTF-8`，显式英文不会被覆盖 | 310 |
| 最终树 App bridge | Camera2 与 AAudio 都能到达活动树 socket | 310 |

## 3. PRoot 同机对比

2026-11-27 单次现场采样：

| 工作量 | Husk | PRoot | 结果 |
|---|---:|---:|---|
| `stat` × 20,000 | 741.2 ms | 2,338.7 ms | Husk 快 3.16× |
| `open` + `close` × 20,000 | 980.9 ms | 5,676.3 ms | Husk 快 5.79× |
| shell 循环 × 1,000 | 18.2 ms | 51.5 ms | Husk 快 2.84× |
| `/bin/true` × 50 | 708.5 ms | 323.6 ms | **Husk 慢 2.19×** |

这不是 5 轮热漂移修正基准，不能替代 [`BENCHMARKS.md`](BENCHMARKS.md) 的轮转数据。短进程启动
成本是真实结果，照实记录。

## 4. GPU

| 项目 | 结果 | 证据 |
|---|---|---|
| Mali-G77 MC9 枚举 | 通过 | 156 |
| PanVK compute + 离屏 graphics | 通过 | 156 |
| Zink/EGL/GL 默认渲染器 | `zink Vulkan 1.3(Mali-G77 MC9 (MESA_PANVK))` | 310 |
| 软件负向控制 | `NR_GPU_DEFAULT_OFF=1` 与 `HUSK_GPU=llvmpipe` 都落到 llvmpipe | 310 |
| 4 路并发 × 300 秒（Rust 门禁） | 每路约 570–572 fps，fd 不变，RSS 变化 +244 kB，GL 错误 0 | 292、329 |
| 固定管线 | 320 fps | 292 |
| 2400×1080 着色器负载 | GPU 41.9 fps vs llvmpipe 3.7 fps | 174 |
| Adreno 825 KGSL 节点 | `/dev/kgsl-3d0` 在 app uid 下可 O_RDWR 打开 | 370、371 |
| Adreno 驱动来源 | Turnip 源码构建（Mesa `27.0.0-devel` / `d211037c`），SHA-256 `35577a1a…89ad75f5` | 371 |
| Adreno Zink/EGL/GL 默认渲染器 | `zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`，GL 4.6 / GLES 3.2，`direct rendering: Yes` | 371 |
| Adreno glxgears（328×366，vblank off） | 607 / 997 / 940 FPS | 371 |
| Adreno 壁纸块状错色 | 消失（370 的洋红竖列不再复现），GNOME 不再 139 | 371 |
| Adreno 客户窗口内容上屏 | **FAIL**：窗口 `Viewable` 但 X 根图无其像素；`DRI3 error: Could not get DRI3 device`；宿主无 DRM 渲染节点 | 371 §4 |
| Adreno 长稳 soak | **NOT VERIFIED**：用户中止设备测试，无 ≥300 s 样本 | 371 §5 |

## 5. 硬件

| 项目 | 结果 | 证据 |
|---|---|---|
| 后摄 `/dev/video0` | 5 帧，6,912,000 bytes，11.89 fps | 309 |
| 前摄 `/dev/video1` | 5 帧，6,912,000 bytes，12.19 fps | 309 |
| Camera2 V4L2 `read` / `readv` | 前后摄通过 | 309 |
| GStreamer `v4l2src` | 前后摄各 3 帧 NV12 640×480，rc=0 | 309 |
| A-hw 普通用户授权路径 | `PASS=14 FAIL=0`；相机、录音、定位权限与真实数据链路 | 323 |
| V4L2 fixture + GStreamer | 640×480、1280×720 两档均 PASS | 320 |
| V4L2 crop/selection + monotonic PTS | 两档契约通过；GStreamer 无 `CROPCAP`/时间戳相关性警告 | 321 |
| AAudio 采集 | 196,608 PCM bytes，`peak=285` | 310 |
| 传感器 IIO | 5 类默认传感器 `READY`，guest 可读 | 302 |
| 传感器 D-Bus | `iio-sensor-proxy` 出现；Accelerometer/Light/Proximity 三项 Claim 成功；`monitor-sensor` 读到三类设备 | 322 |
| 定位 gpsd | last-known `network` 点转成 `TPV mode=2`；撤权后 `mode=1`、无 TPV；坐标在日志中脱敏 | 323 |
| MediaCodec 解码（标准 VA-API 路径，桌面播放器） | 720p 全片通过；1080p 与 High profile 12–25 帧后停摆，**FAIL** | 367-video-va-ab |
| AHB → SurfaceControl | 3-buffer ring / SYNC_FD，10,000 帧 | 59 |

## 6. 宿主显示边界

Husk 运行资产不包含 X server。最终树没有 `Xorg` / `Xvfb`，也没有自建 X11 socket；独立启动
GNOME/X11 桌面为 **UNVERIFIED**。不得把其他 App 或旧 PRoot 树的 X socket 作为 Husk 结果。

详情：[evidence 312](design/evidence/312-x11-host-boundary-20261127.md)。

## 7. UNKNOWN

- 16 KiB / 64 KiB 真机运行；
- Adreno/KGSL 真机；
- 其他 Android 版本、厂商 seccomp/SELinux；
- 相机 DMABUF、通用 V4L2 controls、非整帧裁剪、真实 Camera2 的 GStreamer PTS、跨进程假 fd；
- 持续定位、后台定位、GNSS 原始测量；USB、蓝牙完整链路；
- 窗口内容到 X server 的零拷贝；
- 超过 300 秒的负载型稳定性和更多 GUI 应用。
