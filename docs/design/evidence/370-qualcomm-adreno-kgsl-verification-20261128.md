# 370 · 高通端（Adreno 825 / KGSL）真机验证：KGSL、Turnip/DRM、Vulkan/GLES/zink、桌面与长稳（2026-11-28）

设备：OPPO PLE110 · `3B6585005LE00000` · SM8735 · Adreno 825 · Android 16 (SDK 36) ·
kernel `6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k` · `PAGE_SIZE=4096`。
宿主：`com.linuxhub.myth.husk`（LinuxHub-2.0 debug APK，versionCode 201 / `Myth-Prometheus`）。
本轮所有数字取自该真机现场；没有真机结论一律标 UNKNOWN，编译通过不算运行通过。

## 1 · KGSL 节点访问（PASS）

```text
$ getprop ro.hardware.vulkan        → adreno
$ getprop ro.opengles.version       → （未取，见 §3 实测 GLES 3.2）
$ uname -r                          → 6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k
$ getconf PAGE_SIZE                 → 4096

$ ls -lZ /dev/kgsl-3d0
crw-rw-rw- 1 system system u:object_r:gpu_device:s0 457, 0 ... /dev/kgsl-3d0

$ cat /sys/class/kgsl/kgsl-3d0/gpu_model
Adreno825
```

以宿主 app uid 打开（`run-as com.linuxhub.myth.husk`，`uid=10511(u0_a511)`，
`context=u:r:runas_app:s0:c255,c257,c512,c768`）：

```text
$ exec 3</dev/kgsl-3d0 && echo kgsl-open-rw-OK
kgsl-open-rw-OK
```

判定：**PASS** —— 节点 666、`gpu_device` 上下文，app 域可 O_RDWR 打开；`gpu_model=Adreno825`。
`/sys/class/kgsl/kgsl-3d0/gpuclk` 对 app uid 是 `Permission denied`（sysfs 归 system），不影响渲染。

## 2 · Turnip / DRM 可行性（DRM 后端不可用，Turnip 只能走 KGSL）

```text
$ ls -ld /dev/dri
drwxr-xr-x 2 root root 80 ... /dev/dri
$ ls -lZ /dev/dri/
crw-rw-rw- 1 root graphics u:object_r:graphics_device:s0 226,   0 ... card0
crw-rw-rw- 1 root graphics u:object_r:graphics_device:s0 226, 128 ... renderD128

$ run-as com.linuxhub.myth.husk sh -c 'exec 3</dev/dri/renderD128'
sh: can't open /dev/dri/renderD128: Permission denied
```

判定（FACT + 推断分层）：
- FACT：节点本身 `0666`，父目录 `0755 root:root`，**UNIX 权限不构成拒绝**；app uid 打开仍是 `EACCES`。
- INFERENCE：拒绝来自 SELinux —— app 域是 `u:r:runas_app:s0`，节点类型 `graphics_device`，与
  `kgsl-3d0` 的 `gpu_device` 不同域。
- 结论：**Turnip 的 DRM(MSM) 后端在这台机不可用**；Turnip 必须走 KGSL（`TURNIP_KMD=kgsl` /
  `FD_FORCE_KGSL=1`），与 §3 的实测一致。

## 3 · Vulkan / GLES 实测（两条后端都通，PASS）

### 3.1 Turnip（经 zink：`MESA_LOADER_DRIVER_OVERRIDE=zink` + `GALLIUM_DRIVER=zink`）

```text
$ glxinfo -B
Extended renderer info (GLX_MESA_query_renderer):
    Device: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP)) (0x44030000)
    Accelerated: yes
OpenGL renderer string: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))
OpenGL core profile version string: 4.6 (Core Profile) Mesa 27.0.0-devel (git-b84f02a451)
OpenGL core profile shading language version string: 4.60
OpenGL version string: 4.6 (Compatibility Profile) Mesa 27.0.0-devel (git-b84f02a451)
OpenGL ES profile version string: OpenGL ES 3.2 Mesa 27.0.0-devel (git-b84f02a451)
```

→ **Vulkan 1.4 / Turnip 在 KGSL 上真实可用**（渲染器字符串带 `MESA_TURNIP`），GL 4.6、GLES 3.2。

### 3.2 原生 freedreno（`MESA_LOADER_DRIVER_OVERRIDE=kgsl` + `GALLIUM_DRIVER=freedreno`）

```text
$ glxinfo -B
OpenGL renderer string: Adreno (TM) 825
OpenGL version string: 4.6 (Compatibility Profile) Mesa 27.0.0-devel (git-b84f02a451)
OpenGL ES profile version string: OpenGL ES 3.2 Mesa 27.0.0-devel (git-b84f02a451)

$ es2_info
GL_VERSION:  OpenGL ES 3.2 Mesa 27.0.0-devel (git-b84f02a451)
GL_RENDERER: Adreno (TM) 825

$ eglinfo
EGL vendor string: Mesa Project
OpenGL core profile vendor: freedreno
OpenGL core profile renderer: Adreno (TM) 825
OpenGL compatibility profile vendor: freedreno
```

→ 原生 gallium freedreno 在 KGSL 上跑起来，`vendor=freedreno`，GL 4.6 / GLES 3.2。

### 3.3 吞吐与警告

```text
$ glxgears -geometry 400x300+200+200        # 原生 freedreno，vblank_mode=0
ATTENTION: default value of option vblank_mode overridden by environment.
MESA-LOADER: failed to retrieve device information
3066 frames in 5.0 seconds = 613.081 FPS
3188 frames in 5.0 seconds = 637.367 FPS
```

- 判定：**PASS（GL 通路有吞吐）**。
- 附带 FAIL 记录：`MESA-LOADER: failed to retrieve device information` 每次都打印（不致命，但说明
  loader 探测某个设备信息失败，来源未定，记 UNKNOWN）。

## 4 · 桌面与合成（FAIL，本轮最硬的问题）

同一宿主、同一 X 服务器、同一份 mutter/DING，只改 Mesa 后端（其余不变）：

| 后端 | 壁纸块状错色 | dock/面板 | 桌面图标(DING) | 普通窗口内容（glxgears） | 首帧/交互 |
|---|---|---|---|---|---|
| llvmpipe（对照） | 无 | 正常 | 正常 | 正常 | 正常，但慢 |
| 原生 freedreno | **有** | 正常 | **不显示** | **不显示**（613 FPS 在跑，屏幕上没有窗口） | 可交互 |
| zink(Turnip) | 无 | **不显示** | 不显示 | — | 可交互 |

### 4.1 壁纸块状错色是「写入布局 / 读取假设」不一致，不是宿主拷贝层

两条互相独立的取图路径看到同一份错色：

```text
guest 内 XGetImage（gjs + Gdk.pixbuf_get_from_window，2360×1080）：
  粉色列 run = [848,879] [896,911] [1712,1727]
Android SurfaceFlinger screencap（2362×1080，X 屏幕在宿主画布上有 2px 偏移）：
  粉色列 run = [849,880] [897,912] [1713,1728]
```

逐行结构（guest 图，隔行交替）：A 行 `848–879`（32px）实心 + 斜向阶梯；B 行 `864–879`(16px)
与 `896–911`(16px)。16/32px 方块 + 隔行交替 = 块内布局被按线性解释。
→ 宿主拷贝层不自证有罪（它只是把 guest 的那一帧原样搬上来）。

### 4.2 已排除的假设（全部单变量，每次重启桌面 + 截图）

| 假设 | 做法 | 结果 |
|---|---|---|
| UBWC 压缩布局 | `FD_MESA_DEBUG=noubwc`（已确认进入 gnome-shell environ） | 错色**不变** |
| DING 绘制窗口导致 | 停用 DING 扩展 + kill 进程 | 错色**不变** |
| Clutter 局部重绘 | `CLUTTER_PAINT=disable-clipped-redraws` | 错色**不变** |
| PBO 贴图上传 | `COGL_DEBUG=disable-pbos` | 错色**不变** |
| Cogl 纹理/读回优化 | `COGL_DEBUG=disable-pbos,disable-atlas,disable-shared-atlas,disable-fast-read-pixel,disable-npot-textures` | 错色**不变** |
| 只关 tiling | `FD_MESA_DEBUG=notile` | **更糟**（错色列变多）→ 缓冲本身是 tiled/压缩布局，强推线性方向错了 |
| GTK4 渲染器 | `GSK_RENDERER=cairo`（已确认进入 DING 的 environ） | 图标**仍不显示** → 不是 GTK 渲染器，是窗口内容合成层 |

### 4.3 与上游已知问题的对应关系

Mesa 上游有两条同族未修问题（freedreno 项目）：一类是 **a7xx + kgsl 后端 + X11 桌面**上出现
「按块对齐的错色块」，报告者把全部 `FD_MESA_DEBUG` 变通一起打开也无效，同一设备同一份 Mesa
换 zink 即干净；另一条是用 `sysmem` 复现同类块状错色。→ 与 §4.2/§4.1 的现场一致：**走原生
freedreno 这条路，问题不在我们的环境变量**。

### 4.4 就绪判定文件缺失（FAIL）

`tools/guest/husk-desktop.sh` 约定把就绪状态写到 `<rootfs>/tmp/husk-desktop.status`；本轮在
Adreno 现场 **该文件不存在**（`ls` → `No such file or directory`），说明当前宿主拉起桌面的路径
没有走我们这套 launcher，或 launcher 未写状态。→ 桌面就绪判定在这条路径上 **无证据可依**。


### 4.5 zink 上两种症状同时出现（2026-11-28 12:40 现场）

补 `FD_KGSL_ENABLE_DMABUF=1` / `TP_UBWC_FLAG_HINT=1` / `GSK_RENDERER=cairo` 后（zink 后端），现场同时出现：

- 壁纸/合成层出现**多列**块状错色（比原生 freedreno 更多，随时间扩散）；
- dock/面板/桌面图标/普通窗口内容**依旧不合成**。

→ 同一会话里「freedreno 的错色」与「zink 的窗口不合成」**叠加出现**，说明这两类症状都不在 GL/Vulkan 后端的
光栅/着色层，而在**两者共用的那一跳：guest GPU 出帧 → X server**。llvmpipe 干净，正因为它不走这一跳。

### 4.6 KGSL dma-buf 导出：宿主链路依赖、本机驱动缺

宿主自带 `doro-gpu-run` 的 Adreno 分支（zink / kgsl）都导出下列变量：

```text
FD_KGSL_ENABLE_DMABUF=1
MESA_VK_WSI_PRESENT_MODE=mailbox
MESA_SHADER_CACHE_DISABLE=false MESA_SHADER_CACHE_MAX_SIZE=512M
GSK_RENDERER=cairo      # 脚本注释：GTK4 NGL 在 Adreno 走 Zink/Turnip 时会坏 tab strip 与 damaged region
```

三处核对 `FD_KGSL_ENABLE_DMABUF`：

```text
现场 libgallium-27.0.0-devel.so        → 有（出现 1 次）
现场 libvulkan_freedreno.so（Turnip）  → 没有（0 次）
上游 mesa main 源码 `grep -rn FD_KGSL src` → 空
```

判定（FACT）：宿主链路假定的是**带 KGSL dma-buf 导出的下游驱动**；本机 Turnip 没有这条能力，
上游源码也没有。`FD_KGSL_ENABLE_DMABUF=1` 在 zink 链路上是空操作 → §4.5 的叠加症状。
这也解释了宿主的 `/etc/doro-gpu-mode` 只认 `panvk`，其余一律落到 `llvmpipe`（`/etc/profile.d/doro-gpu.sh`）：
**宿主自身没有可用的 Adreno 硬件分支**。

## 5 · 长稳（进程级 PASS，画面级 FAIL）

原生 freedreno 桌面，10 分钟采样（每 60s，gnome-shell 主进程）：

```text
t=60s  pid=18569 rss_kb=162976 fds=43 threads=22
t=120s pid=18569 rss_kb=160552 fds=43 threads=22
t=180s pid=18569 rss_kb=157852 fds=43 threads=22
t=240s pid=18569 rss_kb=147768 fds=43 threads=23
t=300s pid=18569 rss_kb=148440 fds=43 threads=22
t=360s pid=18569 rss_kb=149824 fds=43 threads=22
t=420s pid=18569 rss_kb=128620 fds=43 threads=22
t=480s pid=18569 rss_kb=126520 fds=43 threads=22
```

有效样本 8 个（t=60s…480s，同一 pid）。t=540s/600s 两行是**操作者中途 force-stop 重启桌面**造成的串号
（pid 变成别的进程、rss 4 MB），不作为长稳证据，照实写出来。

判定：
- **进程级 PASS**：pid 全程不变（无崩溃/无重启）；fd 数稳定；RSS 无单调增长。
- **画面级 FAIL**：同一会话内块状错色随时间**扩散**（12:14 → 12:20 截图对比，错色列从 3 处增至
  6 处以上），不属于「首帧一次性画错」。

## 6 · 单项判定汇总（对齐 LEDGER §9.5）

| 项 | 判定 | 依据 |
|---|---|---|
| KGSL 节点可访问（app uid） | **PASS** | §1 |
| KGSL 内核侧 GPU 型号可见 | **PASS** | `gpu_model=Adreno825` |
| Turnip 的 DRM 后端可用 | **FAIL** | §2，`renderD128` EACCES（SELinux） |
| Turnip 经 KGSL 可用（Vulkan） | **PASS** | §3.1 `MESA_TURNIP` + Vulkan 1.4 |
| 原生 freedreno GL/GLES 可用 | **PASS** | §3.2 |
| GL 吞吐（glxgears，400×300，vblank off） | **PASS** 613–637 FPS | §3.3 |
| 桌面起得来、可交互 | **PASS** | 截图 + 进程 |
| 桌面就绪判定（status 文件） | **FAIL** | §4.4 |
| 桌面窗口内容正确呈现 | **FAIL** | §4，glxgears 613 FPS 但窗口不可见 |
| 壁纸/合成无错色 | **FAIL** | §4.1/§4.2 |
| 长稳（进程不崩、无 fd/内存泄漏） | **PASS** | §5 |
| 长稳（画面稳定） | **FAIL** | §5 错色扩散 |
| Adreno 桌面「加速 + 正确」同时成立 | **UNKNOWN / 未达成** | 三种后端各坏一半；补 DMABUF/hint/cairo 后 zink 上两症状叠加（§4.5） |
| KGSL dma-buf 导出（宿主链路依赖） | **FAIL** | §4.6：Turnip 无该能力，上游源码无该开关 |

## 7 · 未验证 / 不能从本机得出结论的项

- 16K / 64K 页内核真机：无设备（UNKNOWN）。
- `MESA-LOADER: failed to retrieve device information` 的确切来源：未定位（UNKNOWN）。
- 桌面 20 次循环进安全模式：本轮未跑满 20 次（NOT RUN）。
- 输入、相机、音频、视频：不属本轮 §9.5 范围，另见对应 evidence。

## 8 · 结论（判断，不冒充事实）

1. 高通的**通路**是通的：KGSL 可开、Turnip(KGSL) 出 Vulkan 1.4、原生 freedreno 出 GL 4.6、
   glxgears 613–637 FPS。**「不能加速」这个说法不成立。**
2. 高通**画面对不对**没通：原生 freedreno 有块状错色且随时间扩散、普通窗口内容不上屏；
   zink 壁纸干净但窗口/面板内容不合成。三条后端里只有 llvmpipe 全对——也就是「慢但正确」。
3. 与上游同族 issue 对照后可以确定：**这不是我们环境变量写错**（§4.2 全部单变量已排除），
   要根治必须落到驱动源码层，和 Mali 侧 H57/H41 同一性质的工作。
