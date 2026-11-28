# 硬件接口地图

Husk 的目标不是给某个 Linux 应用单独开洞，而是把 Android 宿主能力映射成稳定的 Linux 接口。
每个接口只归入四类之一：

| 分类 | 定义 |
|---|---|
| **直连** | guest 进程直接打开真实设备节点，应用侧不参与数据路径 |
| **中转** | guest 看到标准 Linux 接口，后端经明确协议转到 Android 服务或 NDK |
| **不需要** | 对 Linux 用户态没有可复用的标准语义，或实现只会与 Android 抢夺同一交互 |
| **权限或厂商限制** | 接口方向成立，但当前应用权限或回调模型不够 |

参考验证环境是 arm64 Android 13、kernel 4.19.191、4 KiB 页、Mali-G77 MC9、
`untrusted_app`。机型只是证据条件，不是运行时产品绑定。

## 1. 当前矩阵

| 能力 | 分类 | guest 接口 | Android 后端 | 当前状态 |
|---|---|---|---|---|
| GPU（MediaTek） | 直连 | `/dev/mali0` + Vulkan/EGL | PanVK + Zink（kbase） | Mali-G77 已真机验证 |
| GPU（Qualcomm） | 直连 | `/dev/kgsl-3d0` + Vulkan/EGL | Turnip + Zink（KGSL） | Adreno 825 驱动链已真机验证（GL 4.6 / GLES 3.2、607–997 FPS）；客户窗口上屏被宿主 DRI3 阻塞 |
| 相机 | 中转 | V4L2 `/dev/videoN` facade | Camera2 NDK / `AImageReader` | 2026-11-27 复验：A-hw 14/0，前后摄各 3 帧 1280×720 NV12；fixture 的 V4L2/GStreamer 两档通过；crop/selection 与 monotonic PTS 已验；DMABUF、通用 controls、非整帧裁剪未支持 |
| 音频输出 | 中转 | PulseAudio | Rust relay → AAudio | 真实 PCM 输出已验证 |
| 音频采集 | 中转 | PulseAudio source | Rust relay → AAudio | 196,608 PCM bytes、peak=285 已验证 |
| 视频解码 | 中转 | VA-API | Rust VA driver → MediaCodec | H.264 1080p30 600 秒，dropped=0 |
| 传感器 | 中转 | IIO sysfs 影子树 | NDK `ASensorManager_*` | 加速度、磁力、陀螺仪、环境光、距离五类可读；`iio-sensor-proxy` 的 `net.hadess.SensorProxy`、三项 Claim 与 `monitor-sensor` 已在参考机通过（evidence 322） |
| 显示 | 应用侧中转 | AHB / dma-buf | `SurfaceControl` | 3-buffer ring 与 `SYNC_FD` 10,000 帧；仅代表应用侧接管段 |
| 输入 | 窗口层 | 宿主 window/X11 事件 | Android 输入事件 | bridge 已实现；端到端依赖宿主窗口系统 |
| 定位 | 中转（仅 last-known） | gpsd JSON over Unix socket | `LocationManager.getLastKnownLocation()` | `/run/husk/gps.sock` 已提供 `VERSION`/`DEVICES`/`WATCH`/`POLL`/`TPV`；`/run/gpsd.sock` 在未被占用时指向它；撤权后清空 FIX 并返回 mode=1；持续定位、后台定位、GNSS 原始测量 UNVERIFIED |
| USB | 权限或厂商限制 | libusb（候选） | `UsbManager` + Intent | 首次授权需要广播接收器；需要最小 Java 垫片 |
| 蓝牙 | 权限或厂商限制 | BlueZ（候选） | `BluetoothAdapter` | Android 12+ 权限与回调模型需要 Java 垫片 |
| NFC | 不需要 | — | 前台 Activity tag dispatch | 没有可复用的标准 POSIX NFC 设备接口 |
| 指纹 | 不需要 | — | `BiometricPrompt` | 认证绑定可见 Activity，guest 没有可复用的凭据流 |

**直连只有 GPU。** 相机、音频、视频、传感器、定位和显示都是中转。不能宣传成“全部直连”。

## 2. GPU 直连

参考机的真实节点：

```text
/dev/mali0  crw-rw-rw- root root 10,33
```

guest 进程直接打开该节点，PanVK 走 kbase 后端，Zink 提供 OpenGL/GLES。默认环境由 loader 从
`/etc/husk/gpu-env` 注入：

```text
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/husk_panvk_guest.json
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/husk_panvk_guest.json
MESA_LOADER_DRIVER_OVERRIDE=zink
GALLIUM_DRIVER=zink
```

实测：

```text
plain renderer: zink Vulkan 1.3(Mali-G77 MC9 (MESA_PANVK))
NR_GPU_DEFAULT_OFF=1 -> llvmpipe
HUSK_GPU=llvmpipe -> llvmpipe
GPU_LOADER_DEFAULTS PASS=9 FAIL=0 SKIP=0
```

边界：

- `PANVK_DXVK_COMPAT=1` 的 geometry shader 崩溃是已知支持边界，默认规避不是修复。
- GLES 3.2 依赖 `MESA_GLES_VERSION_OVERRIDE`，真实应用覆盖不足。
- 窗口内容进入宿主 X server 仍不是零拷贝。

### 2.1 Adreno（Qualcomm / KGSL）

节点与后端：

```text
/dev/kgsl-3d0  crw-rw-rw-（app uid 可 O_RDWR 打开）
Vulkan 驱动    Turnip，源码构建：Mesa 27.0.0-devel / d211037c
               usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so
               SHA-256 35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5
ICD            /usr/share/vulkan/icd.d/husk_turnip_guest.json
```

默认环境：

```text
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/husk_turnip_guest.json
GALLIUM_DRIVER=zink
MESA_LOADER_DRIVER_OVERRIDE=zink
```

实测（OPPO PLE110 / SM8735 / Adreno 825 / Android 16）：

```text
Device: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP)) (0x44030000)
GL 4.6 / GLES 3.2 / direct rendering: Yes
glxgears 607 / 997 / 940 FPS
29-turnip-kgsl.sh: PASS=11 FAIL=0
```

边界：

- 原生 freedreno（不经 Zink）在 a7xx/KGSL 上仍有块状错色，默认固定 `zink`。
- **客户窗口内容上屏不通**：窗口 `Viewable` 但 X 根图里没有像素，`DRI3 error: Could not get DRI3 device`；
  宿主 app 进程只有 `/dev/kgsl-3d0`，guest 的 `/dev/dri/renderD128` 是 shim 假节点且只实现
  `DRM_IOCTL_VERSION`。这是宿主侧缺口，记 LEDGER §21。
- 两条驱动链（`vendor/panvk/` 与 `vendor/turnip/`）互不覆盖，安装器按节点二选一。

## 3. 相机、音频、视频和传感器

这些能力需要 Android 应用身份，因此不能把宿主 fd 直接冒充成内核设备：

- **相机**：guest `open("/dev/videoN")` 返回 shim 的 memfd；V4L2 ioctl 和 buffer 协议由 Rust
  shim 承接，帧由 Camera2 NDK 产生。`read`、`readv`、mmap 已验证。
- **音频**：`/dev/snd` 在应用域不可打开；guest 使用 PulseAudio，Rust relay 转成 AAudio。
- **视频**：guest 使用 VA-API；Rust driver 和 bridge 把帧转到 MediaCodec / AHardwareBuffer。
- **传感器**：NDK `ASensorManager_*` 产生事件，写入应用私有 IIO 影子树；guest 通过标准
  `/sys/bus/iio/devices/iio:deviceN/*`、`/sys/class/iio/iio:deviceN/*` 和
  `/sys/subsystem/iio/devices/iio:deviceN/*` 读取；`iio-sensor-proxy` 再把这些节点发布为
  `net.hadess.SensorProxy` D-Bus 接口。

这些接口的好处是应用侧无需改代码；代价是协议、同步和格式能力受 Android 后端限制。测试数字
分别见 evidence 309、310、302、80。

## 4. 显示与输入

显示链需要分成两段：

```text
guest 渲染 / X client -> 宿主 X server    # 可能发生回读与 SHM 拷贝
X 合成结果 -> AHB/dma-buf -> SurfaceControl # 已实现的应用侧零拷贝段
```

当前发行资产不包含 X server。GNOME/X11 桌面启动属于宿主 App 集成，不能把其他 App 或旧
PRoot 树的 socket 算进 Husk。证据见 evidence 312。

输入走窗口层：Android MotionEvent/KeyEvent 进入 App，再注入宿主窗口系统。它不是一个可直接
直开的 `/dev/input` 设备路径。

## 5. 定位、USB、蓝牙、NFC、指纹

- **定位**使用不需要自定义 Java 类的 last-known 子集：App 轮询 `network` / `fused` / `gps`
  三个 provider 的 `getLastKnownLocation()`，把最新点发布成 gpsd JSON。guest 默认使用
  `/run/husk/gps.sock`；`/run/gpsd.sock` 未被真实 daemon 占用时会指向它。socket 位于应用私有
  目录，避免无认证 TCP 让同机其他应用读取位置。撤销权限会同时清空内存 FIX，客户端只能看到
  `mode=1`。持续回调、后台定位、GNSS 原始测量没有实现。
- **USB、蓝牙**方向上是中转，但 Android API 需要 Intent、广播接收器或回调。当前 App 保持
  `hasCode=false`，因此要么增加一个极小的 Java 类，要么明确只支持功能子集。
- **NFC、指纹**归类为不需要。它们依赖前台 Activity 的可见交互或安全认证语义，Linux 用户态
  没有可复用的标准设备接口。

## 6. 可以说什么

可以说：

- 能直开的设备节点使用真实 fd；
- 必须经过 Android 服务的能力，向 guest 暴露标准 Linux 接口；
- 驱动和 GPU 默认配置只部署一份，所有 guest 进程共享；
- 应用侧一行代码不改。

不能说：

- “所有硬件都是直连”；
- “整条显示链零拷贝”；
- “Adreno 桌面已经能用”（驱动链通了，客户窗口上屏还卡在宿主 DRI3）；
- “GNOME 桌面由 Husk 独立启动”；
- “Husk 是恶意代码安全沙箱”。
