# Husk Turnip（Adreno / KGSL）发行快照

这是 **高通（Adreno）链路** 的 Vulkan 驱动，与 Mali 的 `vendor/panvk/` 是两套互不通用的后端：

| 项 | 值 |
|---|---|
| Mesa 版本 | `27.0.0-devel`（`git-b84f02a451`） |
| 源码快照 | gitlab archive `d211037c`（`mesa-main.tar.gz` 解出 `mesa-d211037c/`） |
| 目标设备 | OPPO PLE110 / SM8735 / **Adreno 825** / Android 16 SDK36 / kernel 6.6.118 / 4K 页 |
| 运行时身份 | `zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`，Mesa `27.0.0` |
| 驱动 SHA-256 | `35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5` |

## 为什么要源码构建，而不是"拿 Mali 那份改"

PanVK 走 `kbase`，Turnip 走 `KGSL/msm`；两者的内核接口、寄存器模型（Valhall vs `ir3`）、
环境变量面（`PANVK_*` vs `FD_*`/`TU_*`）都不一样，Mali 那份二进制里没有 KGSL 代码可改。
可以共享的只有 Vulkan 运行时公共层，`vk_meta` 就是其中一处（见下）。

## 构建参数（缺一个就跑不起来，两个都踩过）

```
meson setup build --cross-file=cross-aarch64.txt \
  -Dbuildtype=release \
  -Dvulkan-drivers=freedreno -Dgallium-drivers= -Dopengl=false \
  -Dplatforms=x11 -Dxlib-lease=disabled \
  -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dtools= \
  -Dfreedreno-kmds=kgsl,msm
```

* `-Dfreedreno-kmds=kgsl` → `TU_HAS_KGSL`，`tu_enumerate_devices()` 里那段 KGSL 枚举才会编译进来。
  漏掉它：`vkEnumeratePhysicalDevices` 返回 `VK_ERROR_INITIALIZATION_FAILED`（0 个设备），
  zink 选不到 pdev，`gnome-shell` 直接退出 139。
* `-Dplatforms=x11` → 编译 `src/vulkan/wsi/wsi_common_x11.c`。漏掉它：窗口/表面创建走到空指针，
  GL 客户端 `pc=0` 段错误。
* `freedreno-kmds` 默认只带 `msm`，不带 `kgsl`；这是最容易漏的一项。

## 源码改动

| 补丁 | 来源 | 说明 |
|---|---|---|
| `docs/design/patches/fristonerr-blit-single-triangle.patch` | 与 Mali 共用同一份源码补丁 | `src/vulkan/runtime/vk_meta_draw_rects.c` 的 `vk_meta_draw_volume` 由「6 顶点/2 三角形 + 顶点缓冲」改成「单三角形 + 精确 scissor」。这是 Vulkan 运行时公共层，两个后端共用，所以同一份补丁两边都要打。 |

KGSL 的 dma-buf 导出**不需要补丁**：本快照上游已带
`kgsl_bo_export_dmabuf()`、`KHR_external_memory_fd`、`EXT_external_memory_dma_buf`。

## 依赖

`NEEDED`：`libm.so.6`、`libxcb-dri3.so.0`、`libxcb.so.1`、`libX11-xcb.so.1`、
`libxcb-present.so.0`、`libxcb-xfixes.so.0`、`libxcb-sync.so.1`、`libxcb-randr.so.0`、
`libxcb-shm.so.0`、`libxshmfence.so.1`、`libgcc_s.so.1`、`libc.so.6`、`ld-linux-aarch64.so.1`。
rootfs（Ubuntu 24.04）自带这些运行时库，安装器不额外装依赖。

## 已知未解决

桌面**客户端窗口内容上不了屏**（窗口 map 正常、`Viewable`，X 根图里没有它们）。原因在宿主
X server 拿不到 DRM 渲染节点（app 进程只持有 `/dev/kgsl-3d0`，没有 `/dev/dri/*`），
`DRI3Open` 失败 → mutter 拿不到 texture-from-pixmap。这条不在驱动侧，见 evidence 371。
