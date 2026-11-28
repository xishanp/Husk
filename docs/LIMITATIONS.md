# 限制与边界

本文件记录当前版本明确做不到、尚未验证或需要宿主配合的部分。没有写在本文不等于已经支持。

参考环境是 arm64 Android 13、kernel 4.19.191、4 KiB 页、Mali-G77 MC9，以 `untrusted_app`
运行。机型只是实测条件，不是运行时的产品绑定。

## 1. 运行环境的三条硬要求

1. **arm64（aarch64）用户态**。loader 的 GOT 改写和 syscall 直通只对这一 ABI 成立。
2. **一个可执行、可写、应用沙箱允许的目录**。Android 上使用应用私有目录；`noexec` 挂载会失败。
3. **系统没有额外封死 `untrusted_app` 的 `execve` / `clone` / `open*`**。厂商 seccomp 或 SELinux
   若另加限制，Husk 没有绕过的余量。

逐项自查和安装后的必要改动见 [`RUNNING.md`](RUNNING.md)。

## 2. 不是安全沙箱

Husk 通过动态链接入口和 GOT 改写实现路径语义。以下代码不受控制：

- 静态链接 ELF；
- 直接发起 raw syscall 的程序；
- 没有经过 Husk loader 启动的进程；
- 尚未覆盖的 libc 内部调用路径。

因此 Husk 适合运行普通、可信的 Linux 用户态，不适合隔离恶意代码。需要强隔离时，应另建
namespace、VM 或独立威胁模型。

## 3. X11 / 桌面是宿主能力

当前发行资产不包含 `Xorg`、`Xvfb` 或应用内 X server。最终树里只有 X11 客户端兼容组件
`Xwayland`，这不能代替 X server。

因此：

- 终端、编译、包管理、GPU compute/离屏渲染可独立验收；
- GNOME/X11 桌面需要宿主 App 提供 X server、输入注入和 Surface 呈现；
- 不能用其他 App、PRoot 旧树或手工复制的 X socket 作为 Husk 独立桌面证据；
- 独立桌面启动状态为 **UNVERIFIED**。

证据：[312](design/evidence/312-x11-host-boundary-20261127.md)。

## 4. GPU

已通过：

- Mali-G77 MC9 直开 `/dev/mali0`；
- PanVK 枚举、compute、离屏 graphics；
- Zink/EGL/GL 默认环境由 loader 注入；
- 2400×1080 重负载 GPU 相对 llvmpipe 快 11.2×；
- Adreno 825 直开 `/dev/kgsl-3d0`，源码构建 Turnip 经 Zink 出 `zink Vulkan 1.4`、GL 4.6 / GLES 3.2，
  glxgears 607–997 FPS，壁纸块状错色消失。

未完成或未验证：

- Adreno 客户窗口内容上屏（宿主 X server 没有 DRM 渲染节点，DRI3 不可用）；
- Adreno 长稳 soak；
- 依赖 geometry shader 的 DXVK 程序；
- GLES 3.2 的真实应用覆盖；
- 窗口内容进入 X server 的零拷贝；
- 所有 Mali 型号、所有 Android 版本。

`PANVK_DXVK_COMPAT=1` 在参考机上仍可触发 PanVK/Bifrost `fa=0x21` 崩溃。默认关闭是规避，
不是编译器修复。

## 5. 呈现链

当前能确认的零拷贝只有应用侧这一段：

```text
AHardwareBuffer -> dma-buf -> SurfaceControl
```

不能把整条链写成零拷贝。若窗口内容来自 X server，参考机上的现实路径仍是：

```text
GPU 表面 -> CPU 回读 -> X server / SHM 拷贝 -> 应用侧 AHB -> 屏幕
```

2400×1080 上 GPU 回读约 14 ms/帧（2026-11-27 早前轮次 `gl-probe` 实测；补丁前同一段记作 30.27 ms，
那次含初始化等待，两个数字不是同一次测量），DRI3 在应用域没有可用 render node，不能只靠 path-shim
修复。原始测量见 evidence 228、290。

## 6. 硬件接口

| 设备类 | 状态 | 说明 |
|---|---|---|
| GPU | 直连 | Mali：`/dev/mali0` + PanVK；Adreno：`/dev/kgsl-3d0` + 源码构建 Turnip。Adreno 的 GL 链已通，桌面窗口上屏未通（宿主 DRI3） |
| 相机 | 中转 | 标准 V4L2 facade，后端 Camera2；不支持 DMABUF/controls |
| 音频 | 中转 | PulseAudio → Rust relay → AAudio；无 `/dev/snd` |
| 视频解码 | 中转 | VA-API → MediaCodec；标准 VA-API 路径目前只有 720p Constrained Baseline 实测通过，1080p 与 High profile 会停摆（`367-video-va-ab-20261128`），不能宣称播放器可用 |
| 传感器 | 中转 | NDK → IIO 影子树 → `iio-sensor-proxy`；D-Bus 输出已在参考机验证，当前只映射五类默认传感器 |
| 定位 | 中转（仅 last-known） | `LocationManager.getLastKnownLocation()` → gpsd JSON；持续定位、后台定位、GNSS 原始测量未实现 |
| USB / 蓝牙 | 权限或厂商限制 | 仍受宿主侧权限与回调限制；当前只支持明确的功能子集 |
| NFC / 指纹 | 不需要 | 没有可复用的标准 Linux 设备语义 |

“直连”只对 GPU 成立。相机、音频、视频、传感器和定位都是中转；定位当前只有 last-known 子集。

## 7. 安装与升级

发行版树不能直接原样运行，必须由安装器完成：

- libc 两处补丁；
- 绝对符号链接改写为相对链接；
- `ldconfig` 替换为 `husk-ldconfig`；
- `useradd` / `groupadd` / `passwd` 一族替换为 `husk-usermgr`；
- `su` 替换为 `husk-su`；
- 创建 `dev/shm`、`run`、`tmp` 和 install-state。

`apt upgrade` 若覆盖 `libc6`，会话入口会校验哈希并尝试恢复；失败时拒绝启动，不继续运行坏树。
未知发行版不会自动覆盖 libc。

## 8. 启动成本与性能

Husk 不在运行时逐条拦截 syscall，路径密集负载通常明显快于 PRoot。但短进程每次启动都要重新
装载并完成 GOT 改写。2026-11-27 单次现场采样中：

```text
stat x 20,000        Husk 741.2 ms    PRoot 2,338.7 ms
open+close x 20,000 Husk 980.9 ms    PRoot 5,676.3 ms
/bin/true x 50       Husk 708.5 ms    PRoot 323.6 ms
```

因此不能宣传成“所有负载都更快”。大块顺序 I/O 基本打平，短进程启动当前反而更慢。

## 9. 平台覆盖

已验证：

- arm64；
- Android 13；
- kernel 4.19.191；
- 4 KiB 页；
- Mali-G77 MC9；
- Adreno 825（OPPO PLE110 / SM8735 / Android 16 / kernel 6.6.118）的 KGSL + Turnip + Zink GL 链路；
- glibc 2.39 参考树。

未验证或未知：

- 16 KiB / 64 KiB 页真机；
- 其他 Android 版本；
- 其他厂商 SELinux/seccomp；
- Adreno 客户窗口合成、Adreno 长稳、其他 Adreno 型号；
- 其他 glibc 版本；
- 多设备升级与迁移。

## 10. Termux

Termux 不是交付形态。Husk 的用户态二进制、库、安装路径和 App bridge 都依赖 Android 应用
私有目录；把它当 Termux 包使用会缺少依赖和可执行目录。

## 11. 仍需补测的项目

- 相机 DMABUF、V4L2 controls、跨进程假 fd；
- 持续定位、后台定位、GNSS 原始测量；
- USB、蓝牙；
- 窗口内容到 X server 的 dma-buf 直传；
- 负载型长稳和更多 GPU 应用；
- 16K/64K 页真机；
- Adreno 窗口合成路径（DRI3 / WD）与负载型长稳。

这些项目的现状以 [`STATUS.md`](STATUS.md) 和对应 evidence 文件为准。
