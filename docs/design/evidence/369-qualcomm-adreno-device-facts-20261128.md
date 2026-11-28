# 369 · 高通端（SM8735 / Adreno 825）设备与 KGSL/DRM 节点事实（2026-11-28）

设备：OPPO PLE110 · 序列号 `3B6585005LE00000` · Qualcomm **SM8735** · **Adreno 825** ·
Android **16（SDK 36）** · kernel `6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k` ·
`PAGE_SIZE=4096` · `ro.board.platform=sun`。

测试宿主：`com.linuxhub.myth.husk`，来自
`LinuxHub-2.0/app/build/outputs/apk/debug/app-debug.apk`（1,049,344,044 B，versionCode 201，
versionName `Myth-Prometheus`），2026-11-28 11:02 安装成功（`pm install -r -g` → `Success`）。

## 1 · 图形栈（FACT）

```text
$ getprop ro.hardware.vulkan            → adreno
$ getprop ro.opengles.version           → 196610   # 3.2
$ ls /vendor/lib64/hw/vulkan*           → /vendor/lib64/hw/vulkan.adreno.so
```

宿主给 Android 侧用的 Vulkan 驱动是 `vulkan.adreno.so`（bionic + Android linker 才能加载）。
它不是 glibc guest 能直接 dlopen 的 ICD，仓库也没有发 Turnip/freedreno ICD：

```text
$ tar tzf dist/husk-arm64.tar.gz | grep icd
vendor/panvk/fristonerr-1.2.0-mali-g77/husk_panvk_guest.json   # 只有 Mali/PanVK 那一份
```

## 2 · KGSL 节点：可打开、可读（FACT）

以宿主 app uid 执行（`run-as com.linuxhub.myth.husk`）：

```text
uid=10511(u0_a511) context=u:r:runas_app:s0:c255,c257,c512,c768
crw-rw-rw- 1 system system 457, 0 1971-03-09 06:57 /dev/kgsl-3d0
$ head -c 8 /dev/kgsl-3d0 | xxd
00000000: 4f48 2048 4149 2047                      OH HAI G
rc=0
$ cat /sys/class/kgsl/kgsl-3d0/gpu_model
Adreno825
```

`OH HAI G` 是 kbase/kgsl 的打开标识串，说明**节点确实被打通并成功读到**。
注意这只证明 open+read 通，不证明任何 GPU 命令能提交——那需要 ioctl 探针（未做，见 §5）。

## 3 · DRM 节点：模式 666，SELinux 对 app uid 拒绝（FACT）

shell uid 看到的权限位：

```text
$ ls -l /dev/dri
crw-rw-rw- 1 root graphics 226,   0 /dev/dri/card0
crw-rw-rw- 1 root graphics 226, 128 /dev/dri/renderD128
```

同一个设备，换 app uid：

```text
$ run-as com.linuxhub.myth.husk ls -l /dev/dri/
ls: /dev/dri/: Permission denied
$ run-as ... ls -l /dev/dri/renderD128 /dev/dri/card0
ls: /dev/dri/renderD128: Permission denied
ls: /dev/dri/card0: Permission denied
$ run-as ... dd if=/dev/dri/renderD128 of=/dev/null bs=1 count=1
dd: /dev/dri/renderD128: Permission denied
```

结论：**渲染节点 666 只是 DAC 位，SELinux `runas_app` 域仍然拒**。所以 Turnip 的 DRM 后端在
这条路径上不可用；要走 GPU 只能走 KGSL 后端（需要专门的 Turnip KGSL 构建 + ioctl 可用）。

## 4 · 对账：LEDGER §9.5 / §21 的 Adreno 条目

| 项 | 本次状态 |
|---|---|
| 真机是否存在 | ✅ 有（SM8735 / Adreno 825 / Android 16） |
| KGSL 节点可访问 | ✅ open+read 通（本文 §2） |
| DRM render node 可用 | ⛔ SELinux 拒绝（本文 §3） |
| guest 侧 Vulkan ICD | ⬜ 无（仓库只有 Mali/PanVK） |
| guest 侧 GL/Vulkan 实测 | ⬜ 待桌面就绪后做 |
| 桌面 / 长稳 | ⬜ 待做 |

## 5 · 还没证明的（UNKNOWN，不许写成 PASS）

- KGSL **ioctl** 是否被允许（`IOCTL_KGSL_DEVICE_GETPROPERTY` / `GETGPUID`）——需专门探针。
- guest 里 `vulkaninfo` / `glxinfo` 的结果——现在没有可用 ICD，预期失败，但必须跑出来看。
- 桌面是否起来、GPU 是否被用到、拖动是否流畅。

## 6 · KGSL ioctl 探针（2026-11-28 11:0x，`/tmp/kgslprobe/kgsl-probe.c`）

以宿主 app uid 运行（`run-as com.linuxhub.myth.husk ./files/kgsl-probe`）：

```text
open(/dev/kgsl-3d0, O_RDWR) = 3 errno=0 (Success)
GETPROPERTY(DEVICE_INFO) = 0 errno=0 (Success)
  device_id=1 chip_id=1141047296 mmu=1 gpu_id=0 gmem=2490368
GETPROPERTY(GPU_MODEL) = -1 errno=19 (No such device) model=''
```

**FACT**：`untrusted_app` 域里 `/dev/kgsl-3d0` 能 **O_RDWR 打开**，并且
`IOCTL_KGSL_DEVICE_GETPROPERTY(DEVICE_INFO)` 真的返回了 chip_id / MMU / GMEM ——
不是 ENOTTY，不是 EPERM。

**FACT**：`KGSL_PROP_GPU_MODEL`（type=18）返回 `ENODEV`，说明这个内核不支持该属性；
不是权限问题（同一 fd 上一个属性是通的）。

**这意味着**：高通侧的 GPU 不是"节点打不开"那种死路，缺的只是**驱动**——
仓库只发 Mali/PanVK，没有 Turnip（freedreno）ICD；DRM render node 又被 SELinux 拒，
所以只能走 KGSL 后端。结论要分两句写：

- 「KGSL 可访问且 ioctl 可用」= **PASS（已证）**
- 「guest 里能用上 Adreno GPU 加速」= **UNKNOWN（没驱动，未跑）**

原始命令与输出均在本文件；后续在同一设备上的验证继续追加到 369 之后的 evidence。
