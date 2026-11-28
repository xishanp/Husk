# 371 · 高通端 Turnip 源码构建 + KGSL 后端真机验证（2026-11-28）

目标：在 **OPPO PLE110 / SM8735 / Adreno 825 / Android 16 SDK36 / kernel 6.6.118 / 4K 页**
上用 **源码构建的 Turnip**（而不是发行版/预编译 freedreno）把桌面 GPU 链路跑起来，
并逐项留证。承接 evidence 370 的六项 FAIL。

判定口径：PASS / FAIL / UNKNOWN 全部以本次真机原始输出为准；
**编译通过不算运行通过**；不利结果照写。

---

## 1 构建身份

| 项 | 值 |
|---|---|
| Mesa | `27.0.0-devel`，`git-b84f02a451`，源码快照 `d211037c` |
| 驱动 | `usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so` |
| SHA-256 | `35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5` |
| 大小 | 11487376 B（未 strip） |
| ICD | `husk_turnip_guest.json`，`api_version 1.4.368`，`library_path` 用 guest 相对路径 |
| 构建配方 | `tools/build/build-turnip.sh`、`vendor/turnip/d211037c-adreno-825/PROVENANCE.md` |
| 源码改动 | `docs/design/patches/fristonerr-blit-single-triangle.patch`（H57，与 Mali 共用同一份 vk_meta 补丁） |

`NEEDED`（`llvm-readelf -d`）：

```
libm.so.6  libxcb-dri3.so.0  libxcb.so.1  libX11-xcb.so.1  libxcb-present.so.0
libxcb-xfixes.so.0  libxcb-sync.so.1  libxcb-randr.so.0  libxcb-shm.so.0
libxshmfence.so.1  libgcc_s.so.1  libc.so.6  ld-linux-aarch64.so.1
```

> 顺带更正 evidence 370 的一条推断：本快照上游**已带** KGSL dma-buf 导出
> （`kgsl_bo_export_dmabuf()`、`tu_device.cc: .KHR_external_memory_fd = true`、
> `.EXT_external_memory_dma_buf = true`），所以"要移植 KGSL dma-buf 导出补丁"不需要做。
> `FD_KGSL_ENABLE_DMABUF` / `TURNIP_KMD` / `FD_FORCE_KGSL` / `TP_UBWC_FLAG_HINT`
> 在 `src/freedreno/vulkan/**` 里 **grep 无任何命中**，是无效变量；工作配置里保留它们
> 无副作用，但固化版本已不再写。

---

## 2 两个构建缺陷（都是 139 的直接原因，各踩一次）

### 2.1 漏 `-Dfreedreno-kmds=kgsl` → KGSL 枚举整段没编进来

`src/freedreno/vulkan/meson.build:130` 只有 `if freedreno_kmds.contains('kgsl')` 才
`tu_flags += '-DTU_HAS_KGSL'` 并编译 `tu_knl_kgsl.cc`；该选项默认只带 `msm`。
`tu_knl.cc:363` 的 `tu_enumerate_devices()` 整段在 `#ifdef TU_HAS_KGSL` 里，缺了就直接
`return VK_ERROR_INCOMPATIBLE_DRIVER` → 0 个物理设备。

真机症状（`rootfs/tmp/doro-gnome-shell.log`，原始）：

```
libmutter-Message: Running GNOME Shell (using mutter 46.2) as a X11 window and compositing manager
ATTENTION: default value of option vblank_mode overridden by environment.
MESA: error: ZINK: vkEnumeratePhysicalDevices failed (VK_ERROR_INITIALIZATION_FAILED)
MESA: error: ZINK: failed to choose pdev
glx: failed to create drisw screen
failed to load driver: zink
```

`gnome-shell` 退出码 **139**。

`VK_LOADER_DEBUG=all` 同时证明**不是 dlopen 失败**（驱动已加载并返回函数指针）：

```
DEBUG | DRIVER:    Searching for ICD drivers named /usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so
DEBUG:             loader_phys_dev_ext_gpa: Driver /usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so returned ptr 0x7d576a0da4 for vkGetPhysicalDeviceCooperativeMatrixProperties2EXT
```

### 2.2 漏 `-Dplatforms=x11` → 没有 X11 WSI

`src/vulkan/wsi/meson.build` 只有 `with_platform_x11` 才编译 `wsi_common_x11.c`。
补上 KGSL 后桌面能起、但 GL 客户端立刻崩，崩溃由 path-shim 捕获并打印寄存器：

```
segv|sig=11|fa=0|pc=0|lr=525259073716|sp=549598188448|fp=549598188704|...
```

`pc=0` = 跳到空指针，即表面创建走了没编译进来的函数。

修正后 `NEEDED` 里出现 `libxcb-dri3.so.0 / libxcb.so.1 / libX11-xcb.so.1 ...`，
与发行版那份 `libvulkan_freedreno.so` 的 WSI 依赖集合对齐。

---

## 3 结果实测

### 3.1 GL / Vulkan / GLES（`glxinfo -B`，原始）

```
name of display: :0
display: :0  screen: 0
direct rendering: Yes
Extended renderer info (GLX_MESA_query_renderer):
    Vendor: Mesa (0x5143)
    Device: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP)) (0x44030000)
    Version: 27.0.0
    Accelerated: yes
    Video memory: 8378MB
    Unified memory: yes
    Preferred profile: core (0x1)
    Max core profile version: 4.6
    Max compat profile version: 4.6
    Max GLES1 profile version: 1.1
    Max GLES[23] profile version: 3.2
```

### 3.2 吞吐（`glxgears -info`，328×366，`vblank_mode=0`）

```
GL_RENDERER   = zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))
GL_VERSION    = 4.6 (Compatibility Profile) Mesa 27.0.0-devel (git-b84f02a451)
3033 frames in 5.0 seconds = 606.597 FPS
4984 frames in 5.0 seconds = 996.706 FPS
4698 frames in 5.0 seconds = 939.599 FPS
```

evidence 370 里原生 freedreno 是 613 / 637 FPS；本次 zink→Turnip 为 607 / 997 / 940 FPS，
同一量级。

### 3.3 驱动身份可自证（`/proc/<pid>/maps`）

```
pid=1572
      7 libvulkan_freedreno_husk.so
libgallium-27.0.0-devel.so
```

即桌面进程里加载的确实是这份源码构建产物，不是发行版那份。

### 3.4 桌面

`doro-gnome-shell.log` 在修正后不再出现任何 ZINK/GL 错误，只剩键盘绑定与
`_NET_ACTIVE_WINDOW` 提示；截图显示壁纸、Dock、顶栏、指针正常。

**evidence 370 的"壁纸块状错色"不再复现**：全屏截图中原来那三组洋红竖列
（`[848-879][896-911][1712-1727]`）消失。

---

## 4 未解决：客户窗口内容不上屏（宿主侧阻塞）

现象：桌面图标、应用窗口、`glxgears` 全部不可见，只有 shell 自己画的东西
（壁纸 / Dock / 顶栏 / 指针）正常。

### 4.1 窗口是正常 map 的（`XQueryTree` + `XGetWindowAttributes`）

```
root 0x511 children 21
win=    0xc00007 2360x1080+0+0   depth=0  state=Viewable name='mutter guard window'
win=   0x1a00003 2360x1080+0+0   depth=32 state=Viewable name='Desktop Icons 1'
win=   0x100000d  328x366+52+20  depth=32 state=Viewable name=''
```

（第三条就是 `glxgears`；`Desktop Icons 1` 是 DING。）

### 4.2 但 X 根图里没有它们

`XGetImage(root)` 取平均色，窗口区域与纯壁纸区域一致（只是壁纸渐变本身）：

```
depth 24 bpp 32
gears_rect   (52,20,328x366) rgb= (47, 7, 32)
plain_rect (1000,20,328x366) rgb= (83, 27, 58)
dock_rect   (0,600,70x200)   rgb= (32, 18, 26)
```

配合宿主截图：窗口像素既不在 X 里，也不在屏幕上 → **mutter 没把它们合成进场景**。

### 4.3 断点：DRI3 拿不到 DRM 设备

客户端日志：

```
MESA-EGL: warning: DRI3 error: Could not get DRI3 device
MESA-EGL: warning: Ensure your X server supports DRI3 to get accelerated rendering
```

该文案在 `src/egl/drivers/dri2/platform_x11_dri3.c:517`，只在
**DRI3 扩展存在、而 `x11_dri3_open()` 返回 <0** 时打印。所以不是"X server 没有 DRI3"，
是它**没有可用的 DRM 设备**。

宿主侧证据：

* app 进程 fd 里只有 `107 -> /dev/kgsl-3d0`，没有 `/dev/dri/*`；
* guest 看到的 `/dev/dri/renderD128` 是 shim 造的假节点：

```
/dev/dri/renderD128 -> 1 1 0 b'kgsl' | b'KGSL-backed DRM render node (Husk)'
/dev/dri/card0      -> 1 1 0 b'kgsl' | b'KGSL-backed DRM render node (Husk)'
```

* 该节点在 `runtime/crates/path-shim/src/lib.rs` 的 `adreno_ioctl()` 里**只实现
  `DRM_IOCTL_VERSION` 一条**：

```rust
unsafe fn adreno_ioctl(fd: CInt, request: u64, arg: *mut u8) -> Option<CInt> {
    if request != DRM_IOCTL_VERSION || !adreno_is_device(fd) {
        return None;
    }
    Some(adreno_fill_drm_version(arg))
}
```

而 Mali 侧的 `runtime/crates/drm-shim/src/lib.rs` 是一整套 DRM→kbase 翻译
（`GET_CAP` / gem / mmap / execbuffer / close_bo）。**这就是"天玑有、高通没有"的具体位置。**

### 4.4 结论

这条不是驱动层的账：Turnip 在 guest 内已经渲染正确；缺的是 **DRM/DRI3 语义**
（`GET_CAP(PRIME/SYNCOBJ)`、`PRIME_HANDLE_TO_FD`、`PRIME_FD_TO_HANDLE`、`SYNCOBJ_*`，
落到 KGSL 的 `GPUOBJ_ALLOC_ID` / `MAP_GPUOBJ` / dma-buf import-export），
而且宿主 X server 本身也拿不到真实 DRM 节点（app 只持有 `/dev/kgsl-3d0`）。

两个可选方向（用户未定，不擅自选）：

* **A**：按原计划走 WD/Wayland —— 合成器在 guest 内，不经过宿主 X server 的 DRI3；
* **B**：留在 X11 —— 需要 path-shim 补 KGSL 版 DRM 翻译 **且** 宿主 X server 能拿到可用 DRM 节点。

---

## 5 判定表

| # | 项 | 判定 | 依据 |
|---|---|---|---|
| 1 | KGSL 节点可访问（app uid） | **PASS** | `/proc/<app>/fd/107 -> /dev/kgsl-3d0`；evidence 370 O_RDWR 成功 |
| 2 | Turnip 源码构建带 KGSL 后端 | **PASS** | `TU_HAS_KGSL` 命中；驱动内含 `/dev/kgsl-3d0`；`tu_knl_kgsl.cc.o` 在编译列表 |
| 3 | Turnip 自带 X11 WSI | **PASS** | `NEEDED` 含 `libxcb-dri3.so.0` 等 10 个 xcb/x11 库；`ci/audit-turnip-bundle.sh` 断言 |
| 4 | `vkEnumeratePhysicalDevices` 能出 1 个设备 | **PASS** | zink 选到 pdev，渲染器字符串带 `Adreno (TM) 825 (MESA_TURNIP)` |
| 5 | Vulkan/GL 版本 | **PASS** | Vulkan `1.4`（zink 报告）、GL `4.6`、GLES `3.2` |
| 6 | 吞吐 | **PASS** | 607 / 997 / 940 FPS（328×366，vblank off） |
| 7 | 桌面进程跑的是这份 Husk 驱动 | **PASS** | `maps` 里 7 段 `libvulkan_freedreno_husk.so` |
| 8 | 壁纸块状错色（evidence 370 FAIL 项） | **PASS（已消失）** | 原三组洋红竖列不再出现 |
| 9 | GNOME 会话不再 139 | **PASS** | `doro-gnome-shell.log` 无 GL 错误；截图正常 |
| 10 | 客户窗口内容上屏 | **FAIL** | 窗口 Viewable 但 X 根图与屏幕均无其像素；DRI3 取不到 DRM 设备 |
| 11 | 桌面就绪判定（`tmp/husk-desktop.status`） | **FAIL** | 本次会话桌面非 `husk-desktop.sh` 拉起，`status`/`trace` 均不存在 |
| 12 | 长稳（≥300 s、fds/RSS 采样） | **NOT VERIFIED** | soak 起跑后被用户中止（现场卡住），未取得 ≥300 s 样本。**不写 PASS**，按 TODO 口径标 NOT VERIFIED，待下一轮单独跑 |

---

## 6 自证门禁（可复跑）

新增 `tools/device-tests/29-turnip-kgsl.sh`：把「设备上跑的到底是不是这份高通驱动」
做成 11 条断言。真机实跑输出：

```
29 turnip/kgsl  (3B6585005LE00000)
  PASS  device exposes /dev/kgsl-3d0
  PASS  app uid can open /dev/kgsl-3d0
  PASS  Turnip driver sha256 = 35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5
  PASS  driver references /dev/kgsl-3d0 (TU_HAS_KGSL compiled in)
  PASS  driver links libxcb-dri3 (X11 WSI compiled in)
  PASS  ICD library_path is guest-relative Turnip driver
  PASS  gpu-env records @GPU_FAMILY=adreno-kgsl
  PASS  gpu-env pins VK_ICD_FILENAMES to the canonical Turnip ICD
  PASS  gpu-env forces GALLIUM_DRIVER=zink (native freedreno renders wrong on Adreno 825)
  PASS  live renderer: zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))
  PASS  gnome-shell maps libvulkan_freedreno_husk.so (7 segments)
29 turnip/kgsl: PASS=11 FAIL=0
```

第 4/5 条是 H64/H65 的看门人：少了 `-Dfreedreno-kmds=kgsl` 或 `-Dplatforms=x11`，
驱动里就找不到那两个特征串，脚本立刻 FAIL，不会等到桌面 139 才发现。

---

## 7 固化（本次一并落进仓库）

| 文件 | 改动 |
|---|---|
| `vendor/turnip/d211037c-adreno-825/` | 新增：驱动快照 `.so.gz` + `husk_turnip_guest.json` + `LICENSE-Mesa.txt` + `PROVENANCE.md` + `SHA256SUMS` |
| `tools/guest/install-husk.sh` | 新增 2b-2b-0b：仅有 `/dev/kgsl-3d0` 时解压 Turnip 并核 SHA-256，落 canonical ICD；`adreno-kgsl` 的 ICD 选择把 `husk_turnip_guest.json` 排第一位；gpu-env 在树里有 Husk Turnip 时固定 `zink`，原生 freedreno 只作回退（实测原生壁纸成块状错色） |
| `tools/ci/audit-turnip-bundle.sh` | 新增：断言驱动的 SHA-256、`/dev/kgsl-3d0` 串（证明 `TU_HAS_KGSL`）、`libxcb-dri3.so.0` 串（证明 x11 WSI）、ICD 契约、以及安装器对接 |
| `Makefile` | `make check` 跑上面的 audit；`make dist` 把 `vendor/turnip/` 打进包并断言存在 |
| `tools/build/build-turnip.sh` | 新增：可复现构建配方（含两个 load-bearing 开关与 sysroot 依赖清单） |

与 Mali 完全分开：`vendor/panvk/`（kbase）与 `vendor/turnip/`（KGSL）是两条驱动链、
两份 ICD、两套环境变量面；安装器按设备节点二选一，互不覆盖。
`gpuProfile`（init 第二步的线路选择）当前由宿主写进 `container.properties`
（本机值 `gpuProfile=qualcomm`），Husk 侧的落地口径就是上面这份
「设备节点 → GPU 家族 → 驱动 + ICD + GL 渲染器」映射。
