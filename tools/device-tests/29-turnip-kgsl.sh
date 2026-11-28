#!/bin/sh
# 29 · 高通（Adreno/KGSL）Turnip 链路验收。
#
# Mali 那套判据（husk_panvk_guest.json / libvulkan_panfrost_husk.so）在 Adreno 上
# 全不适用：两个后端、两份 ICD、两套环境变量面。这里只验高通这一条，逐项给出
# PASS/FAIL，任何一项 FAIL 都表示"桌面 GPU 跑的不是我们要测的那份"。
#
#   DEV=<adb serial> PKG=<owner package> ROOTFS=files/rootfs-full \
#   LD=files/rootfs-full/usr/bin/libld.so sh 29-turnip-kgsl.sh
#
# ROOTFS 默认 files/rootfs-full（与本仓库其它设备门禁同一口径，不钉死任何发行版目录）；
# 当前测试机上的活动树是 files/linux/distributions/ubuntu-24.04/rootfs，跑的时候显式传。
set -u
DEV=${DEV:?usage: DEV=<adb serial> [PKG=...] [ROOTFS=...] [LD=...] $0}
PKG=${PKG:-com.linuxhub.myth.husk}
ROOTFS=${ROOTFS:-files/rootfs-full}
LD=${LD:-files/linux/husk/libld.so}
ABS=/data/user/0/$PKG
DRIVER=$ROOTFS/usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so
ICD=$ROOTFS/usr/share/vulkan/icd.d/husk_turnip_guest.json
# Source-built 2026-11-28, see vendor/turnip/d211037c-adreno-825/PROVENANCE.md
WANT_SHA=35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
g() { adb -s "$DEV" shell "run-as $PKG sh -c '$1'" 2>/dev/null; }

echo "29 turnip/kgsl  ($DEV)"

# 1. 设备家族：只有 kgsl-3d0 才算高通链路
if g 'test -e /dev/kgsl-3d0' >/dev/null 2>&1; then
    ok "device exposes /dev/kgsl-3d0"
    # 能在 app uid 下真打开才算（SELinux 域决定，不是文件模式位）
    if g ": <> /dev/kgsl-3d0" >/dev/null 2>&1; then
        ok "app uid can open /dev/kgsl-3d0"
    else
        bad "app uid cannot open /dev/kgsl-3d0"
    fi
else
    bad "no /dev/kgsl-3d0: this is not the Adreno/KGSL link"
fi

# 2. 驱动字节身份
have=$(g "sha256sum $DRIVER 2>/dev/null" | cut -d' ' -f1)
if [ "$have" = "$WANT_SHA" ]; then
    ok "Turnip driver sha256 = $WANT_SHA"
else
    bad "Turnip driver sha256=$have != $WANT_SHA"
fi

# 3. 驱动确实是带 KGSL + X11 WSI 的那份构建
if g "grep -qa /dev/kgsl-3d0 $DRIVER" >/dev/null 2>&1; then
    ok "driver references /dev/kgsl-3d0 (TU_HAS_KGSL compiled in)"
else
    bad "driver has no /dev/kgsl-3d0: built without -Dfreedreno-kmds=kgsl"
fi
if g "grep -qa libxcb-dri3.so.0 $DRIVER" >/dev/null 2>&1; then
    ok "driver links libxcb-dri3 (X11 WSI compiled in)"
else
    bad "driver does not link libxcb-dri3: built without -Dplatforms=x11"
fi

# 4. canonical ICD 契约
lp=$(g "grep -o '/usr/lib/aarch64-linux-gnu/[A-Za-z0-9._-]*\.so' $ICD" | head -n1)
if [ "$lp" = "/usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so" ]; then
    ok "ICD library_path is guest-relative Turnip driver"
else
    bad "ICD library_path='$lp'"
fi

# 5. gpu-env 家族与 ICD 选择
fam=$(g "head -n1 $ROOTFS/etc/husk/gpu-env" | sed 's/^@GPU_FAMILY=//')
if [ "$fam" = adreno-kgsl ]; then
    ok "gpu-env records @GPU_FAMILY=adreno-kgsl"
else
    bad "gpu-env family='$fam' (expected adreno-kgsl)"
fi
if g "grep -q '^VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/husk_turnip_guest.json$' $ROOTFS/etc/husk/gpu-env" >/dev/null 2>&1; then
    ok "gpu-env pins VK_ICD_FILENAMES to the canonical Turnip ICD"
else
    bad "gpu-env does not pin the canonical Turnip ICD"
fi
if g "grep -q '^!GALLIUM_DRIVER=zink$' $ROOTFS/etc/husk/gpu-env" >/dev/null 2>&1; then
    ok "gpu-env forces GALLIUM_DRIVER=zink (native freedreno renders wrong on Adreno 825)"
else
    bad "gpu-env does not force zink"
fi

# 6. 运行时实证：渲染器字符串（需要活着的 X 会话）
LP=$ABS/$ROOTFS/lib/aarch64-linux-gnu:$ABS/$ROOTFS/usr/lib/aarch64-linux-gnu
renderer=$(g "cd $ABS/$ROOTFS && NR_ROOTFS=$ABS/$ROOTFS NR_LD=$ABS/$LD DISPLAY=:0 GALLIUM_DRIVER=zink MESA_LOADER_DRIVER_OVERRIDE=zink VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/husk_turnip_guest.json $ABS/$LD --library-path $LP ./usr/bin/glxinfo -B 2>/dev/null" | sed -n 's/^ *Device: \(zink .*\) (0x.*/\1/p')
case "$renderer" in
    *MESA_TURNIP*) ok "live renderer: $renderer" ;;
    "")            bad "glxinfo returned no renderer (no live X session, or GL stack down)" ;;
    *)             bad "live renderer is '$renderer', not Turnip" ;;
esac

# 7. 桌面进程确实加载了这份驱动
maps=$(g "for p in /proc/[0-9]*; do c=\$(cat \$p/comm 2>/dev/null); [ \"\$c\" = gnome-shell ] && grep -c libvulkan_freedreno_husk.so \$p/maps; done" | head -n1)
if [ "${maps:-0}" -gt 0 ] 2>/dev/null; then
    ok "gnome-shell maps libvulkan_freedreno_husk.so ($maps segments)"
else
    bad "gnome-shell does not map the Husk Turnip driver (or no session)"
fi

echo "29 turnip/kgsl: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
