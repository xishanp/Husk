# 运行与交付

这份文档回答三件事：**资产怎么装进去**、**环境有什么要求**、**装上发行版之后必须改哪些东西
才能完整跑起来**。

版本 **0.0.2**。

## 1 · 交付形态：打进 APP

Husk 的资产是「我们自己的 loader + 一棵被改过的 Linux 用户态」。它们不能脱离应用沙箱直接
在别的终端环境里用——别的环境没有这套依赖，也没有应用私有目录那种「可写 + 可执行 + 沙箱
允许」的组合。所以交付形态和 proot 方案一样：**作为 assets 打进 APK，首次使用时解压到应用
私有目录**。

APK 内 `assets/husk/arm64-v8a/`：

| 资产 | 作用 |
|---|---|
| `libld.so` | loader，内嵌 path-shim。可执行文件的入口 |
| `libc.so.6` | 打过两处补丁的 glibc（见 §4.1） |
| `husk-ldconfig` | 写 `ld.so.cache` 与 `ld.so.husk-path` 的 Rust 程序，替换发行版的静态 `ldconfig` |
| `husk-usermgr` | `useradd` / `groupadd` / `passwd` 一族的替身（发行版的 shadow 工具在这个 SELinux 域里跑不起来） |
| `husk-su` | 提权替身（`su` 的 PAM 路径在这里不通） |
| `husk-symlinks` | 把 rootfs 里的绝对符号链接改写成相对（否则内核按 Android 根解析，`dlopen` 报 ENOENT），并 `--verify` 确认没有漏网 |

首次使用（应用启动、开会话前）按顺序做这些事，全部自动，不需要用户操作：

1. 解压 `libld.so` 到 `files/linux/husk/libld.so` 并置可执行位；
2. 把 `husk-usermgr`、`husk-su`、`husk-ldconfig` 放进发行版的 `usr/sbin/`；
3. 按 sha256 判断是否替换发行版的 `libc.so.6`——**只替换已知的基线与我们自己发过的补丁版，
   未知发行版一律不覆盖**；
4. 把发行版里所有 `ldconfig` 入口指向 `husk-ldconfig`（原文件留作 `ldconfig.ubuntu`，
   永不执行）；
5. 把 `useradd` / `groupadd` / `usermod` / `userdel` / `groupdel` / `chpasswd` / `passwd` /
   `chfn` / `chsh` 指向 `husk-usermgr`；
6. 建 guest 需要的目录：`run`、`run/doro-audio`、`run/doro-desktop`、`tmp`、
   `tmp/.X11-unix`、`dev/shm`；
7. 写版本标记 `files/linux/husk/assets.version`；标记与 APK 内的
   `ASSET_REVISION` 不一致时重做 1–6 步。

安装器（以及 APK 的资产步骤）还要做两件和"能不能用"直接相关的事：

- **符号链接规范化**：跑一遍 `husk-symlinks --root / --apply`，再用 `--verify` 确认；
  然后用 `ctypes.CDLL('libblas.so.3')` / `liblapack.so.3` 验一次 soname 真能装载。
- **libc 一致性**：把 libc 的 sha256 写进 `<安装目录>/.husk-install-state`。`husk-session.sh`
  每次开会话前比对：被 `apt upgrade` 换掉就自动恢复，恢复不了就拒绝启动（exit 74），
  而不是让你在几步之后收到一句 `Cannot fork`。

## 2 · 跑得动的三条硬前提

不是所有设备都能跑，也不需要所有设备都能跑。下面三条缺一条就跑不起来，其它条件只影响
「跑得多完整」。

| # | 硬前提 | 为什么是硬的 | 不满足时的样子 | 怎么确认 |
|---|---|---|---|---|
| 1 | **arm64（aarch64）** | 用户态是 aarch64 ELF，loader 的 GOT 改写与 syscall 直通只对这一个 ABI 成立 | 直接 `Exec format error` | `uname -m` → `aarch64` |
| 2 | **一个能执行、可写、沙箱允许的目录** | loader 自己要被 `exec`，用户态二进制也要；Android 上满足这三个条件的只有应用私有目录（开发机可用 `/data/local/tmp`），`noexec` 挂载直接失败 | 看起来像 loader 坏了：`cannot execute the loader from here` | 直接跑 `<loader>`，它应回 `missing program name`（说明 exec 成功） |
| 3 | **系统对 `untrusted_app` 的 seccomp / SELinux 没有额外收紧** | 用户态要 `execve` / `clone` / `open*` 直通内核。AOSP 默认策略会拒 `clone3`（我们的 libc 补丁把它改成 `ENOSYS` 让 glibc 回落），但厂商若另外封了 `execve` 一类，就没有可绕的余地 | `Bad system call`，进程当场被杀 | 跑 `tools/device-tests/01-functional-matrix.sh`，或先跑 `bin/true` |

还有一个我们踩过、但不算硬前提的坑：**页大小**。loader 与 guest 工具都按 64 KiB 对齐，4 / 16 /
64 KiB 内核都合法；如果自己重新编译，`-z max-page-size` 必须跟目标设备匹配。

## 3 · 环境

通用要求（这是我们验证过的形态，不是唯一可能）：

| 项 | 要求 | 参考环境（我们实测的那台） |
|---|---|---|
| 架构 | arm64 | arm64 |
| 系统 | Android（实际只验证了 13；更低版本未验证，`8+` 是推断） | Android 13（SDK 33） |
| 页大小 | 4 KiB | 4 KiB（16/64 KiB 只在 QEMU 上验证过） |
| 内核 | 能跑 `untrusted_app` 的 SELinux 策略 | 4.19.191 |
| 权限 | 普通应用即可，无 root、无 Shizuku、未解 Bootloader | 同左 |
| 目录 | 能执行、可写：应用私有目录（`run-as … files/…`） | `files/linux/…` |
| 空间 | 发行版树 ×2（解包 + 缓存） | ~2.5 GB |
| 构建 | NDK（构建 loader）、cargo、python3 | NDK 29、stable |

设备型号、SoC、内核版本这些只作为**参考**写在这里和 `docs/STATUS.md` 里；运行时不绑定某个
设备族——loader 的补丁点按 glibc 版本断言，设备信息只影响实测数字，不影响契约。

## 4 · 装上发行版后必须改的 7 件事

| # | 改什么 | 为什么 | 不改会怎样 | 谁来做 |
|---|---|---|---|---|
| 1 | `libc.so.6` 打两处补丁 | libc 内部调用（`nss_files` 的 `fopen`、`opendir`、`realpath`）没有 GOT 可改，需要 slot 页；`clone3` 被 Android seccomp 杀，要改成返回 `ENOSYS` 让 glibc 走旧路径 | 第一条 `pthread` / `getent` 就 `Bad system call` | APK 首次使用自动 |
| 2 | 绝对符号链接改相对 | 内核按 `/` 解析链接目标，rootfs 里的绝对链接会逃到 Android 根 | 明明存在的库 `ENOENT`（如 `libblas.so.3`） | 打包时由 `tools/guest-config/relative-symlinks.py --apply` |
| 3 | `ldconfig` 换成 `husk-ldconfig` | 发行版的 `ldconfig.real` 是静态二进制，shim 够不到，它去写 Android 的 `/etc` | `dpkg --configure` 失败、`apt` 拒绝继续 | APK 首次使用自动 |
| 4 | 建 `dev/shm` | POSIX 共享内存目录，Android 侧没有；proot 以前靠 bind 提供，现在没有 bind | 每个 `shm_open()` 都是 `ENOENT` | APK 首次使用自动 |
| 5 | 生成 `/etc/ld.so.husk-path` | 嵌套 exec 的库目录：glibc 在 loader 内部解析 `DT_RUNPATH`，没有 GOT 可改，只能把发行版声明的目录接到 `--library-path` | `sudo` 找不到 `libsudo_util.so.0`、`gsettings` 报 `libpxbackend-1.0.so` | `husk-ldconfig --library-path-file`（初始化、装包后、启动、开会话四个时机） |
| 6 | 提权与账户工具换成 `husk-su` / `husk-usermgr` | 发行版 `su` 的 PAM 栈在这里答 `System error`；shadow 工具的 `lckpwdf()` 需要 `link(2)`，被 SELinux 拒绝 | `su - user -c …` 失败，装包时建不用户 | APK 首次使用自动 |
| 7 | `tmp` 可写 + `TMPDIR` 指向它 | `run-as` 下 `/tmp` 不可写，`$(...)` 与 here-doc 要写临时文件 | 安装脚本半途失败 | 安装器 / APK 自动 |

两点补充：

- **虚拟所有权**：rootfs 里的文件一律报 `0:0`，guest 自己 `chown`/创建的文件记在
  `/var/lib/husk/owners` 这张 inode 例外表里。表是按设备文件系统的 inode 号记的，**换设备必须
  丢掉这张表**（打包 release 时已排除）。
- **`apt upgrade` 会撤销第 1 条**：升级 `libc6` 会把补丁版换回 stock，之后 `getent shadow`
  返回空、提权失败、会话起不来（报错是误导性的 `/bin/sh: 1: Cannot fork`）。重跑
  `tools/guest-config/install-libc-patch.sh` 或换一个 `ASSET_REVISION` 让 APK 重刷。

## 5 · 启动契约

两个环境变量必须同时给，缺一个就「看起来像 shim 坏了」：

```
NR_ROOTFS=<rootfs 绝对路径>  NR_LD=<loader 绝对路径>  NR_LIBRARY_PATH=<发行版库目录>
  <loader> --library-path "$NR_LIBRARY_PATH" usr/bin/env -i PATH=... /bin/sh -c '...'
```

- 程序路径必须是**相对**路径，进程的工作目录必须是 rootfs 根；
- `--library-path` 是**替换**而不是追加：`lib/aarch64-linux-gnu` 与
  `usr/lib/aarch64-linux-gnu` 必须显式列出；
- `NR_LD` 是嵌套 exec 回灌 loader 用的，缺了它嵌套 exec 会掉回宿主。

## 6 · 验证清单

```sh
# 用户态是自己的
cat /etc/os-release | head -2
uname -m

# 包管理器
dpkg -l | wc -l
apt-get update && apt-get install -y vim

# 工具链
gcc --version | head -1
make -j4                     # 200 目标工程

# 共享内存与账户
python3 -c "import numpy; print(numpy.arange(200000).sum())"
getent passwd | head -3
```

独立安装（不装 APK）的验收多两条，实测见 `docs/design/evidence/157-standalone-install-c4.md`：

```sh
./husk --version                                  # husk 0.0.2
./husk run ubuntu -c 'apt-get update'             # 需要 resolv.conf，见 §7
./husk run ubuntu -c 'eglinfo -B | grep -i renderer'
# 期望：zink Vulkan 1.3(Mali-G77 MC9 (MESA_PANVK))，不是 llvmpipe
```

期望：命令全部返回 0 且输出来自**rootfs 自己**（不是 Android 的 `/etc`）。任何一条报
`Bad system call`、`ENOENT`、`Can't stat /lib`，对照 §3 的表定位是哪一步没做。

## 7 · 排错

| 现象 | 原因 |
|---|---|
| `Bad system call` | §3.1 libc 补丁没打 |
| 库明明存在却 `ENOENT` | §4.2 绝对符号链接没改 |
| `dpkg` 报 `Can't stat /lib` | §3.3 静态 `ldconfig` 没换 |
| `sudo` 缺 `libsudo_util.so.0` | §4.5 `ld.so.husk-path` 没生成 |
| `su: System error` | §4.6 `husk-su` 没装上 |
| `no writable TMPDIR` | §4.7 |
| `make` 的输出消失 | 取样问题，不是运行时问题：`adb shell` 给 guest 的 stdout 是 socket |
| `apt-get update` 报 `Temporary failure resolving` | 没有 `etc/resolv.conf`：release 包按设计不含它，独立安装由 `install-husk.sh` 写（先取 `net.dns1/2`，再兜底 1.1.1.1 / 8.8.8.8） |
| `E: Directory '/var/log/apt/' missing` | release 包不含 `var/log`；安装器会建 `var/log/apt` 与 `var/log/dpkg.log` |
| `./husk run ubuntu -c '…'` 报 `usr/bin/env: '/-c'` | 旧启动器把 `-c` 当程序名；现在的启动器首参以 `-` 开头会前置 `usr/bin/bash` |
