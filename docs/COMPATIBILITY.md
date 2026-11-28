# 兼容性

同一份 rootfs 上，什么能用、什么不能用。「可用」指在目标机上真的执行过并得到预期结果，
不是「包已经装了」。

参考环境（实测条件，不是要求）：arm64 Android 13、kernel 4.19.191、4 KiB 页，以
`untrusted_app` 运行，无 root。具体机型与 SoC 见 `docs/STATUS.md`。

最终树现状（2026-11-27）：`TREE_INTEGRITY PASS=23 FAIL=0`、Gate A `PASS=34 FAIL=0 SKIP=1`、
A-hw `PASS=14 FAIL=0`、GPU 默认值 `PASS=9 FAIL=0`。离线树没有 apt index，因此 apt 解析项
按 SKIP 记录。证据见 evidence 308–310、323。

## shell、工具链、语言运行时

| 项 | Husk | proot | proot-distro | 证据 |
|---|---|---|---|---|
| `bash` / coreutils | 可用 | 可用 | 可用 | bench `have_*` |
| `git`（clone + status） | 可用，889 ms | 可用 | 可用 | bench `git_clone` |
| `python3` + `json` | 可用，88 ms | 可用 | 可用 | bench `python_json` |
| `python3 -c 'import numpy'` | 可用 1.26.4，410 ms | 可用 | 可用 | bench `python_numpy`、evidence 155 |
| `gcc` 编译 hello | 可用，165 ms | 可用 | 可用 | bench `gcc_hello` |
| `make -j4`（200 目标，链接产物 91 KB） | 可用，5 194 ms | 可用 | 可用 | bench `make_j4`、evidence 155 |
| `vim` / `nano` / `node` | 可用 | 可用 | 可用 | bench `have_*` |
| `apt-get install` / `dpkg -l` / `dpkg --configure -a` | 可用 | 可用 | 可用 | evidence 154 |
| `ldconfig`（`husk-ldconfig`） | 可用，950 条 / 6 目录 | 用树自带的静态 ldconfig | 同 proot | evidence 154 |

## 系统服务（guest 内）

| 项 | Husk | 证据 |
|---|---|---|
| dbus 会话总线（`dbus-send --session ListNames`） | 可用 | evidence 152 |
| polkit 授权（`pkcheck --action-id … power-off`） | 可用，rc=0 | evidence 151 |
| 无障碍总线 at-spi | 可用 | evidence 151 |
| gvfs（`gio mount -l`） | 可用，不回退到会话总线 | evidence 152 |
| RandR（`xrandr --version`） | 可用，无缩放告警 | evidence 152 |

## GPU

| 项 | Husk（当前版本的树） | 证据 |
|---|---|---|
| `/dev/mali0` 直开 | 可用 | evidence 156 |
| PanVK（kbase 后端）枚举 + compute + 离屏 graphics | 可用，`Mali-G77 MC9` | evidence 156 |
| GL/EGL 经 Zink 落到 GPU | 可用，renderer `zink Vulkan 1.3(Mali-G77 MC9)`；GLES 上限 3.2（靠 `MESA_GLES_VERSION_OVERRIDE`，zink 默认只报 ES 2.0，真实应用未验） | evidence 156、182 |
| 高通 KGSL 直开 `/dev/kgsl-3d0` | 可用，参考机 `Adreno 825`（OPPO PLE110 / SM8735 / Android 16） | 370、371 |
| Turnip（KGSL 后端，源码构建） | 可用：`zink Vulkan 1.4(Adreno (TM) 825 (MESA_TURNIP))`，GL 4.6 / GLES 3.2，`direct rendering: Yes` | 371 |
| 高通 GL 吞吐 | glxgears 328×366、vblank off：607 / 997 / 940 FPS | 371 |
| 高通壁纸/GL 客户端画面正确性 | 壁纸块状错色消失；GNOME 不再退出 139 | 371 |
| 高通桌面窗口内容上屏 | **不可用**：宿主 X server 取不到 DRM 渲染节点，`DRI3 error: Could not get DRI3 device`，mutter 无法合成客户窗口；属宿主侧阻塞 | 371 §4 |
| GPU 并发与长稳（无 X） | 4 路并发 × 300 s（Rust 门禁）：每路约 570–572 fps，fd 不变、RSS +244 kB、GL 错误 0；固定管线（即时模式 + 光照）320 fps | evidence 292、329 |
| GPU 宿主窗口路径 | 历史 X11 窗口结果使用 LinuxHub 2.0 提供的 X server。**Husk 运行资产本身不带 X server**，独立桌面启动为 UNVERIFIED；窗口内容进入 X server 仍不是零拷贝 | evidence 165、245、278、292、312 |

不开 Zink 时 GL 落在 `llvmpipe`；开了 zink 但用发行版自带的 `panfrost_icd.json` 会
`VK_ERROR_INCOMPATIBLE_DRIVER`，因为它要的是 DRM render node，本机只有 kbase。
高通侧同理：发行版预编译 `freedreno_icd*.json` 在 KGSL 上枚举出 0 个物理设备，桌面直接 139；
默认必须选 `husk_turnip_guest.json`（我们源码构建的 Turnip）。

## 浏览器

不可用，原因明确：随附 rootfs 来自离线包索引，其中没有浏览器包
（`epiphany-browser` / `firefox` 均 `Unable to locate package`；`xterm`、
`gnome-terminal`、`nautilus` 等则在索引内）。要装浏览器需要换一份完整镜像源，不在本版范围。

## 不在支持范围

Termux 不是交付形态（`LIMITATIONS.md` §3）。

硬件按宿主能力分四类，逐类理由见 [`design/hardware-interface-map.md`](design/hardware-interface-map.md)：
传感器已经以 NDK → IIO 影子树的方式接入（中转，5 类默认传感器和 guest sysfs 读取实测通过）；
定位已以 `LocationManager.getLastKnownLocation()` → gpsd Unix socket 的方式接入（中转，只覆盖
last-known，不冒充持续 GNSS）；USB / 蓝牙仍卡在 `hasCode=false` 下缺少回调垫片；NFC 与指纹
不需要。被宿主挡住的能力贴的是原始错误串，不用「未做」代替分类。

guest 内的 VA-API 全链已通到 `vaapih264dec` 出真实帧（evidence 81–87），但只有解码方向。
窗口呈现仍不是零拷贝（DRI3 未通，宿主 X server 在本机应用域没有可用 render node）。
X11/桌面属于宿主集成，Husk 运行资产不携带 X server；见 `LIMITATIONS.md` §3、§5。
