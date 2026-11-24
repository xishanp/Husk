# 路线图

这份文件是**对外承诺**的范围。内部口径在 [`docs/GOALS.md`](docs/GOALS.md)；两份冲突时以
GOALS 为准，并改这份文件。

## 已交付（0.0.1，2026-11-24）

- **loader + path shim**：glibc 用户态作为普通应用进程直接在 Android 内核上跑，零 `ptrace`、
  零 namespace、零虚拟化。
- **guest 基础与容器打平**：`bash`、locale、用户管理、`dpkg`、`apt`（装包与配置）、`getent`、
  `sudo`（走 guest 自己的替身），实测清单见 [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)。
- **会话稳定**：参考设备上 30 分钟空载，RSS 不涨、线程数与 fd 数不变、零僵尸（evidence 153）。
- **可重跑的对比**：一条命令把同一份 rootfs 交给三个运行器，数字与日志都在仓库里
  （[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)）。

## 下一步（按挡不挡用户排，不按好玩程度排）

1. **CI 接上**：workflow 已写好，推送 token 还差 `workflow` 权限；接上后徽章才有真状态。
2. **独立安装走通**：不装 APK，只用 tarball + `install-husk.sh` + `./husk run` 起 `bash`、跑
   `apt`。
3. **GPU 从「能算」到「能上线」**：补 WSI / swapchain，让窗口表面交给 GPU 直接呈现；
   现在是 `AHardwareBuffer` → dma-buf → `SurfaceControl` 这条零拷贝链在走。
4. **静态二进制**：拦不住，看到的是 Android 路径；需要链接层答案或显式白名单。
5. **第二个发行版**：loader 是版本断言的，换树要重新验证，不是加分支。
6. **编解码零拷贝**：H.264 走平台解码器已验证；HEVC / VP9 / AV1 与相机缓冲还在拷贝。

## 不做

`root`、解 Bootloader、硬件虚拟化、`ptrace`、Termux 作为交付形态、跨机型适配，以及任何把
软件渲染说成硬件加速的说法。
