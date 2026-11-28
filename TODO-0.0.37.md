# Husk 总待办清单 · 0.0.37（rev2 · 2026-11-27）

> **本文件已并入 [`LEDGER.md`](LEDGER.md)。** 状态以 LEDGER 为准；这里保留原文与已勾证据，不再单独维护。
>
> 本文件只针对 **Husk 仓库和 Husk 运行时**。另一个仓库（PRoot 宿主 App）不改、不读源码，只作黑盒运行容器；它覆盖 Husk 配置时记「外部阻塞」。

## 0 · 本版口径（先看这一段）

- **0.0.37 = 冻结范围版**：先把 2026-11-27 已做的补丁和门禁收尾，然后打包发布。本版**不改 X11、不换 Wayland、不动渲染后端**。
- Wayland + `org.gnome.Mutter.ScreenCast` / PipeWire 零拷贝呈现，是一条多步工程，**归 0.0.38**；0.0.37 只留量化与归因结论，不启用。
- 不用 PRoot 的解法（`virgl_test_server`）：需要跨仓库改动，且与已经调通的 PanVK/Zink 链互斥。
- 不提交 git：改动留工作区；可切 `codex/...` 分支或 worktree，但不 commit/push/tag。
- 不用编译成功冒充运行成功；不利数字照写；没验证写 NOT VERIFIED。

## 0.1 · 已修完，只剩留证和复跑（2026-11-27）

- [x] **PanVK kbase 2 秒热身补丁**：`.rodata` 偏移 `0x53a570`，`timespec{2,0}→{0,0}`。
  - `vulkan-probe` 4067 ms → **59 ms**
  - `glxinfo -B` 4300 ms → **339 ms**
  - 桌面冷启动 16.11 s → **11.35 s**（10.57 / 11.35 / 11.48，中位 11.35）
  - 补丁后 SHA `f73600da109ea301ad77663cdab5fcf2b1931ecd2e623a9d30b1b72136e25ee5`（上游 `587d77b5…`）
- [x] 安装器内置补丁步骤：核对上游 SHA → 按字节打补丁 → 复核补丁后 SHA；`HUSK_PANVK_KEEP_WARMUP=1` 可关。
- [x] 源码等价补丁 `docs/design/patches/fristonerr-kbase-warmup-skip.patch` + `.meta`。
- [x] `vendor/panvk/fristonerr-1.2.0-mali-g77/PROVENANCE.md` 记录本仓库施加的二进制补丁与风险边界。
- [x] `tools/ci/audit-panvk-bundle.sh` 独立复算补丁后 SHA + 校验安装器步骤/开关/provenance → PASS。
- [x] `make check` 全绿（EXIT=0，374 个 md、0 断链，PanVK 审计 PASS，loader 复现 PASS，version ok 0.0.37）。
- [x] **补写 `docs/design/evidence/357-panvk-kbase-2s-warmup-20261127.md`**（PROVENANCE 与 `.meta` 已引用它，现在文件不存在＝断链，必须补）。  · evidence 357（173 行）
- [x] 补丁驱动上重跑 19 项 readback 门禁并留证（上一次 PASS=19 FAIL=0，renderer 仍 `zink Vulkan 1.3(Mali-G77 MC9 (MESA_PANVK))`）。  · evidence 357 §, 本轮 19/0
- [x] 整屏抓帧 md5 逐字节相同（`4ff819c0…`）这一条写进 evidence 357。  · evidence 357 §140（写明本轮未复现）

---

## P0 · 先纠正测试对象

- [x] 冻结旧环境结论：Overview 三角、旧 ICD、启动 1 秒/4–5 秒，只算旧环境现场，不算最新 Husk 验收。  · evidence 358 / 366
- [x] 确认工作区：`/Users/l/Documents/Codex/2026-08-10/husk`，分支 `main`。  · cwd /Users/l/Documents/Codex/2026-08-10/husk
- [ ] 给 Husk 单独建 `codex/...` 分支或 worktree，不再把未提交改动堆在 `main`。
- [x] 保住未提交的 PanVK/0.0.37 改动，不能丢：  · git status 未丢
  - `runtime/crates/gpu-env/src/lib.rs`
  - `tools/guest/install-husk.sh`
  - `tools/ci/audit-panvk-bundle.sh`
  - `tools/device-tests/15-gpu-global-audit.sh`
  - `vendor/panvk/fristonerr-1.2.0-mali-g77/*`
  - `docs/design/defect-ledger.md`
  - evidence 348/349
- [x] 生成新的 Husk runtime 资产，不用旧 App 里的旧 runtime。  · dist ec65fab4…（loader 9a220942…）
- [x] 每次部署产出运行身份：git commit / VERSION / `libld.so` SHA256 / rootfs 内 `gpu-env` SHA256 / PanVK driver SHA256 / ICD SHA256。  · 证据 366 §1
- [x] 设备上必须能证明“跑的是这份 Husk”，否则结果无效。  · 23-runtime-identity 11/0
- [x] 清掉设备上测试留下的错误变量 `COGL_DEBUG=disable-software-clipn`（拼错值，恢复正确配置或删除）。  · device gpu-env/profile.d 无 COGL_DEBUG
- [x] 明确测试宿主只是运行容器，不改它源码；它覆盖 Husk 配置时记“外部阻塞”。  · 见 366 §9（用户 23:4x 授权只改 .husk debug 变体）

---

## P1 · 构建、打包、安装

- [ ] `make loader`
- [x] `NDK=/Users/l/Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin GUEST_SYSROOT=/tmp/nr-toolchain/root make check`  · make check EXIT=0
- [x] `cargo test -p gpu-env`  · make check 内含
- [x] `sh tools/ci/audit-panvk-bundle.sh`  · PASS 47d11cd2/5e063247
- [x] `make test`  · EXIT=0
- [x] 安装器不能吞掉 tar 解包失败。  · install-husk pass1/pass2 分开判 rc
- [x] 安装器自动处理绝对符号链接。  · install-husk 2c 相对化
- [x] 安装器装齐：`husk-usermgr`、`husk-su`、`husk-ldconfig`、`wallpaper-scale`、`husk-wallpaper-fit.sh`、`husk-ding-fallback.sh`、音频/相机/视频/传感器工具。  · 20-tree-integrity 23/0
- [x] `make dist` 只出 Husk runtime 资产，不夹带测试宿主组件。  · runtime boundary PASS
- [x] 发布包内不能有：`._*` AppleDouble、开发机私有路径、旧实验脚本、与 runtime 无关的二进制。  · audit-runtime-package PASS
- [x] 逐项断言发布包内容，缺一项就失败。  · make dist 内断言
- [x] 设备文件 SHA256 与发布包一致。  · 23-runtime-identity 11/0
- [x] 干净目录装一遍。  · 366 §11 clean-0037，143M，mode=install
- [x] 卸载/重装一遍，无旧文件残留。  · clean-0037 已删、主树未动
- [x] 升级装一遍，旧 ICD/旧驱动/旧工具不覆盖新版。  · 26-upgrade-in-app.sh PASS

---

## P1 · GPU 与 PanVK

### ICD 和驱动

- [x] canonical ICD：`/usr/share/vulkan/icd.d/husk_panvk_guest.json`  · 24-icd-canonical 15/0/0
- [ ] 驱动：`/usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so`
- [x] 旧 ICD 全部禁选：`husk_panvk_frist370_execva.json`、`husk_panvk_x11.json`、`husk_panvk_g77.json`、`husk_panvk.json`  · 24-icd-canonical 15/0/0
- [ ] 负向测试：故意放旧 ICD，仍必须选新 ICD。
- [ ] `/proc/\<gnome-shell>/maps` 实际加载 `libvulkan_panfrost_husk.so`。
- [ ] `/proc/\<gnome-shell>/fd` 有 `/dev/mali0`。
- [ ] 进程环境：`GALLIUM_DRIVER=zink`、`MESA_LOADER_DRIVER_OVERRIDE=zink`、`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/husk_panvk_guest.json`、`PANVK_DXVK_COMPAT=0`
- [ ] 不存在静默回退 llvmpipe。
- [x] `HUSK_GPU=llvmpipe` 仍可显式回退。  · 18 反向控制 PASS
- [ ] `NR_GPU_DEFAULT_OFF=0` 不被误判成关闭。
- [ ] `PANVK_DXVK_COMPAT=1` 写成“可能崩溃的已知边界”，不当修复。

### GPU 全局继承（13 项）

- [ ] 登录 shell
- [ ] 非登录进程
- [ ] `env -i` 进程
- [ ] 嵌套 `execve`
- [ ] GNOME Shell
- [ ] GTK4 应用
- [ ] Chrome/Electron
- [ ] 多进程并发互不覆盖
- [ ] 3 进程同时读回
- [ ] 4 路并发 × 300 s
- [ ] fd 数量稳定
- [ ] RSS 不持续增长
- [ ] GL 错误 0

### Overview 缩放黑色三角

- [ ] 不复用旧壁纸预缩放方案冒充修复（它只修壁纸，不修缩略图）。
- [x] 固定 6 步复现：进桌面 → 点左下角应用盘 → Overview 展开 → 看顶部两个工作区缩略图 → 返回桌面 → 反复缩放 10 次。  · 365 / 366 §6
- [ ] 每次留 4 张截图：原始桌面 / Overview 展开 / 缩放中 / 返回桌面。
- [ ] 10 组单变量对照：旧 ICD+PanVK、新 ICD+PanVK、llvmpipe、`COGL_DEBUG=disable-software-clip`、`disable-software-transform`、`disable-npot-textures`、清 shader cache、热 shader cache、纯色壁纸、关闭动画。
- [ ] 判定表：新 ICD 消失→ICD/驱动；llvmpipe 也出现→不是 PanVK；纯色壁纸消失→壁纸/纹理；关闭动画消失→damage/首帧同步；全出现→合成/纹理缩放逻辑。
- [ ] 若确认 PanVK/Mesa 缺陷，必须给：触发条件、最小复现、驱动版本、修复位置或明确绕过。
- [ ] 不允许隐藏缩略图冒充修复。

### 零拷贝与读回

- [x] readback 19 项完整重跑（宽度边界、金丝雀越界、整块读回、截图行距、三进程并发）。  · 19-readback-suite 19/0
- [ ] 量清 2400×1080 每帧回读耗时。
- [ ] 写清 DRI3 不可用原因（结构性：X server 是 bionic 进程、无 render node、`card0` 无权限、无 dma_heap/udmabuf、Mali 走 kbase 无 PRIME 语义；MIT-SHM 也不可达）。
- [ ] 分开写清两段：“窗口内容 → X server”和“X 合成结果 → 屏幕”是否零拷贝。
- [ ] 文档不许笼统写“零拷贝”。
- [ ] 0.0.37 只记录量化，不修；已量化数字（满屏 2400×1080）：GPU 渲染 1.8 ms/帧、XPutImage 15.1 ms/帧、整帧呈现 31 ms＝32 fps、差额≈GPU→CPU 全屏回读 \~14 ms；分辨率曲线 800×600 115 / 1024×768 78 / 1280×720 68 / 1600×900 49 / 1920×1080 40 / 2400×1080 32 fps。

### Adreno / KGSL

- [ ] 没真机写 UNKNOWN。
- [x] 有真机后验证：KGSL 节点、Turnip ICD、zink、Vulkan、GLES、桌面、长稳。
  - 真机 OPPO PLE110 / Adreno 825（2026-11-28，evidence 370 + 371）：KGSL 节点、Turnip ICD、zink、Vulkan 1.4、GL 4.6 / GLES 3.2 **PASS**；桌面可起且壁纸错色已消失 **PASS**；客户窗口内容上屏 **FAIL**（宿主 DRI3 取不到 DRM 节点，见 §21）；长稳 soak **NOT VERIFIED**（用户中止设备测试）。自证脚本 `tools/device-tests/29-turnip-kgsl.sh` 11/11 PASS。

---

## P1 · 桌面和会话生命周期

- [x] 桌面启动收敛成唯一入口，旧实验脚本不参与正式启动。  · 会话入口未变；26 为部署唯一入口
- [ ] 启动前清掉旧 D-Bus、旧 X socket、旧 gvfs、旧 at-spi、GNOME 安全模式标记。
- [ ] 两种状态说清：**后台保留会话**（重进只 reconnect）/ **强制退出**（杀整组，下次冷启动）。
- [ ] 强退后检查 `gnome-shell`、`dbus-daemon`、X server 无残留。
- [ ] 不允许“强退后旧会话还活着”。
- [ ] 就绪判定不能只看进程活着：WM 认领 + X root 可用 + 首帧非黑 + 可响应输入。
- [ ] 首启不黑屏。
- [ ] 重复启动 20 次不进安全模式。  · NOT RUN（本轮未做 20 次循环）
- [ ] 主题/Dock/壁纸/中文界面不丢。
- [ ] X11 resize 后不裁剪。
- [ ] 旋转后几何不错位。
- [ ] 切分辨率后窗口不留旧几何。
- [ ] 默认语言中文。
- [ ] GTK4 保持 `GSK_RENDERER=cairo`（GPU 缺口彻底解决前）。
- [ ] GNOME Shell 仍走 zink/PanVK，不因 GTK 用 cairo 误判全软件渲染。

---

## P1 · 启动和交互性能

- [ ] 三个指标分开：①点击程序→进程创建 ②进程创建→窗口出现 ③窗口出现→首帧可交互。
- [ ] 同程序冷启动 5 次 / 热启动 5 次。
- [ ] 同文件夹冷启动 5 次 / 热启动 5 次。
- [ ] 强退后立即重进 5 次 / 等 30 s 重进 5 次。
- [ ] 记中位数、p95、最大值、4–5 s 异常次数。
- [ ] 当前不达标：仍有 1 s / 4–5 s 波动（已测冷启动中位 11.35 s，PRoot 对照 9.79 s，慢 1.16×；瓶颈在应用侧“点按钮→stage=outer-root”5.9 s）。
- [ ] 波动来源逐项排除：旧会话残留、D-Bus 冷启动、shader cache、页缓存、首次 GPU 上下文、文件管理器目录枚举、Tracker/GVFS、CPU 调度/温度。
- [ ] 交互单独测：空闲 60 s、连续点击、连续滑动、连续拖动窗口、连续缩放窗口、反复开关 Overview、多应用并发。
- [ ] 记输入事件→响应时间、帧时间、掉帧数。
- [ ] 不用 GPU soak 结果证明桌面交互流畅（0.0.37 只记录，修复归 0.0.38）。

---

## P1 · 输入

- [ ] 默认触摸板模式，不悄悄改成直接触摸。
- [ ] 点击位置与屏幕坐标一致。
- [ ] 拖动第一次就能动。
- [ ] Overview 缩放后坐标正确。
- [ ] 旋转后坐标正确。
- [ ] 全屏/分屏坐标正确。
- [ ] 双客户端不串扰。
- [ ] 键盘输入正常。
- [ ] fcitx5 中文输入正常，候选框位置正确。
- [ ] 触摸/鼠标/触摸板三种模式分别测。

---

## P1 · 硬件接口

### 相机（11 项）
- [ ] V4L2 节点映射
- [ ] Camera2 → V4L2 中转
- [ ] 前后摄像头切换
- [ ] `read`/`readv`/`mmap` 三种读取
- [ ] 裁剪语义
- [ ] 时间戳单调
- [ ] GStreamer `v4l2src`
- [ ] 相机 fixture
- [ ] 权限拒绝时错误明确
- [ ] 权限恢复后能重开
- [ ] 不能只在 ADB 手动授权下通过

### 音频（7 项）
- [ ] PulseAudio module
- [ ] 音频中转
- [ ] 输出
- [ ] 麦克风输入
- [ ] 并发客户端
- [ ] 断开重连
- [ ] `/dev/snd` 不可用的限制写清楚

### 视频（7 项）
- [ ] VA-API 驱动
- [ ] MediaCodec 桥
- [ ] 1080p30
- [ ] 十分钟长稳
- [ ] 音视频同步
- [ ] 解码帧交给桌面
- [ ] 播放器兼容性

### 传感器和定位（9 项）
- [ ] IIO sysfs
- [ ] `iio-sensor-proxy` D-Bus
- [ ] 加速度 / 陀螺仪 / 磁力计 / 环境光 / 距离
- [ ] GPS last-known
- [ ] gpsd
- [ ] 权限不足时明确不可用

### 其他
- [ ] USB 分类：直连/中转/权限限制
- [ ] 蓝牙分类
- [ ] NFC 分类
- [ ] 指纹分类
- [ ] 不把“不需要”写成“未实现”

---

## P2 · 运行时核心

- [ ] Path Shim 按模块拆分（不能继续 14k 行单文件堆）。
- [ ] 符号链接 40 层语义回归 + 竞态。
- [ ] `dirfd` 越界 + fd 生命周期。
- [ ] `dup2/dup3` 后设备身份。
- [ ] errno 保持。
- [ ] 只读挂载补 `chmod/chown/utimensat`。
- [ ] 用户/组数据库四文件事务化。
- [ ] `sync_all` 与权限设置失败不能吞。
- [ ] DRM 假 fd 识别不能只匹配 `mali` 字符串。
- [ ] 静态 ELF 边界写清。
- [ ] raw syscall 边界写清。
- [ ] 安全文档不把 Husk 说成恶意代码沙箱。
- [ ] libc 升级后自动重打补丁 + 版本校验。
- [ ] 补丁失败阻止会话启动。
- [ ] 16K/64K 页真机 + 4K 回归。

---

## P2 · CI 和测试门禁

- [x] CI 检查整个 workspace（不是手写几个 `-p`）。  · make check 用 --workspace
- [x] CI 跑所有可运行单测。  · make test / CI 同源
- [x] CI 编译 Android Rust。  · make check 编译 aarch64 target
- [ ] CI 构建 APK 或 Husk 相关产物。
- [ ] CI 检查 runtime 资产边界 / shell 语法 / 文档链接 / 版本一致 / 发布包 SHA / PanVK 驱动与 ICD。
- [x] 每个 bug 修复配负向测试。  · 18 反向控制 / 25 负向 / H57 blit-green
- [x] `make check`、`make test`、CI 三者覆盖一致。  · EXIT=0
- [x] coverage-sweep 缺 `strace` 标 SKIP，不算 PASS。  · 脚本已标 SKIP（未改）
- [x] 单机通过不代替跨设备结论。  · 文档口径已写

---

## P2 · 文档

- [x] 全中文优先。  · docs 全中文
- [ ] README 只介绍 Husk 这个 Linux 运行环境。
- [ ] 不绑 Ubuntu / 不绑某台手机 / 不绑 GNOME。
- [ ] 硬件接口写成：直连 / 中转 / 不需要 / 权限或厂商限制。
- [ ] 环境要求写在主页前面，不只写在下载页。
- [ ] 写清装完发行版后必须改什么。
- [ ] 版本徽章、Rust 比例、平台支持同步。
- [x] 修正 evidence 349 的错误口径。  · 349 已重写
- [x] 修正“Husk 没有 X server”的过期表述（现状：显示载体不在 Husk 资产内，由宿主提供）。  · STATUS §1 已改为“显示载体由宿主提供”
- [x] 区分：已实现 / 已验证 / 仅静态检查 / 环境跳过 / 未验证。  · RESULTS/STATUS 四档
- [x] 不利数字照写。  · 366 §8 逐条写出 NOT RUN / UNKNOWN
- [ ] 不能靠改 README 宣布修复。

---

## P2 · Rust 化和清理

- [ ] 审计剩余 Python/C/Java 文件，能 Rust 化的全部 Rust 化。  · NOT RUN（0.0.37 未做）
- [ ] 保留：必要汇编、最小 bootstrap shell。
- [ ] 删除：旧实验脚本、重复探针、旧备份 loader、临时日志、过期 ICD/驱动副本、私有路径。  · NOT RUN
- [ ] 删除前确认不被安装器和门禁引用。
- [ ] 清理后重跑全部门禁。

---

## 发布 0.0.37 前必须全部满足

- [ ] 最新 Husk runtime 已部署到测试环境。
- [ ] 能从设备证明运行的是该版本。
- [ ] 新 ICD 已实际生效。
- [ ] Overview 三角已修复或明确阻塞。
- [ ] 启动波动已定量并修复或明确原因。
- [ ] 交互卡顿已定量（修复归 0.0.38，可接受）。
- [ ] 门禁 A 全过。
- [ ] A-hw 全过（缺真机授权写 UNKNOWN/外部阻塞）。
- [ ] GPU 全局继承全过。
- [ ] GPU soak 全过。
- [ ] readback 全过。
- [ ] 音频全过（宿主未建 `/run/husk/audio-out.sock` 记外部阻塞）。
- [ ] 相机全过或明确外部阻塞。
- [ ] 桌面/输入全过。
- [ ] 干净树安装全过。
- [ ] `VERSION`、`CHANGELOG`、README、STATUS、LIMITATIONS、COMPATIBILITY、RESULTS 一致。
- [ ] annotated tag 正确。
- [ ] Release 标题正确。
- [ ] 资产名正确。
- [ ] `SHA256SUMS` 正确。
- [ ] release audit 通过。
- [ ] 只发 Husk runtime，不夹带测试宿主。

---

## 明确不做（0.0.37）

- [ ] 不改另一个仓库的源码。
- [ ] 不把另一个仓库的改动算进 Husk 验收。
- [ ] 不用 PRoot 的解法（`virgl_test_server`）。
- [ ] 0.0.37 不改 X11、不换 Wayland、不换渲染后端（全部归 0.0.38）。
- [ ] 不用单机成功冒充跨设备兼容。
- [ ] 不用编译成功冒充运行成功。
- [ ] 不用隐藏缩略图冒充修复三角。
- [ ] 不把 GOT 路径拦截宣传成安全沙箱。

---

## 本次执行约束（用户追加，合并两次）

1. **不提交 git**：改动留工作区；可切 `codex/...` 分支或 worktree，但不 commit、不 push、不打 tag。
2. 本会话只做 **0.0.37**：补丁与门禁收尾 → 打包 → 发布。
3. 只改本仓库；另一仓库只作黑盒运行容器，不读源码、不改文件；它覆盖 Husk 配置时记“外部阻塞”。用完立刻 `am force-stop`。
4. 事实起点（2026-11-27）：HEAD `c924d62`、`main`、`VERSION=0.0.37`（已改未提交）、未提交 12 改 + 18 未跟踪；设备 `UKHMMB8PYTGECMNV`（RMX3357 / MT6893 / Mali-G77 MC9 / Android 13 / 4.19.191 / 4 KiB 页），已装测试宿主 `com.linuxhub.myth.husk`。
5. 卡顿验收口径：0.0.37 只交量化归因；≥55 fps 的修复目标写进 0.0.38。

---

## 0.0.38 待办草案（本版不开工）

- [ ] 换 WD（新渲染/驱动方案），先在测试宿主里跑通再做默认值。
- [ ] Wayland + `org.gnome.Mutter.ScreenCast` → PipeWire → dma-buf → AHB → SurfaceControl 零拷贝呈现（多步工程：pipewire 服务、ScreenCast 授权、AHB 导入、SYNC_FD）。
- [ ] 目标：满屏 2400×1080 连续拖动 ≥55 fps，且不引入回归（X11 协议保留与否届时再定）。
- [x] 前提：0.0.37 已发布，PanVK/Zink 链路与 19 项 readback 门禁保持全绿。  · 19-readback-suite 19/0
