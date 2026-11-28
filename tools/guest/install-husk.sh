#!/bin/sh
# install-husk.sh - put a Husk rootfs + loader into a plain directory.
#
# This is the "install it like proot-distro does" path: one tarball, one script,
# no adb push per file, no root. What it needs is a writable directory and a
# loader the kernel lets us execute.
#
# The supported target is this app's own private directory (`run-as ... files/...`).
# Termux is NOT a supported environment and is not tested: the guest tree expects
# binaries and libraries that a Termux $PREFIX does not provide, so a run from
# there fails on missing dependencies rather than on anything this script can fix.
#
# usage:
#   install-husk.sh [--rootfs <rootfs.tar[.gz]>] [--dest DIR] [--loader PATH] [--user NAME]
#                  [--fresh] [--upgrade]
#
#   --rootfs  Ubuntu base tarball (uncompressed or .gz)
#   --dest    where the rootfs goes (default: ./root next to this script)
#   --loader  our loader (default: $NR_LD, else ./libld.so next to this script)
#   --user    guest user for the generated launcher (default: root)
#   --fresh   replace a non-empty destination instead of refusing it
#   --upgrade re-run the guest-side steps on an existing tree; no extraction,
#             no --rootfs. This is the upgrade path: it replaces the loader,
#             tools, ICD and PanVK driver without touching /home or dpkg state.
#
# Why two extraction passes: Ubuntu's base tarball contains hard links
# (usr/bin/uncompress -> gunzip, usr/bin/perl -> perl5.38.2, ...). Android
# refuses link(2) inside app data (SELinux), so a plain `tar xf` leaves those
# entries out. Pass 1 lays everything down and tolerates the link errors; pass 2
# re-extracts *through* the shim, whose link() falls back to a copy, so the
# missing names materialise as real files. That fallback is the same code dpkg
# relies on, so this is not a special case for installation.
set -eu

ROOTFS_TAR=
DEST=
LOADER=${NR_LD:-}
USER_NAME=root
FRESH=no
UPGRADE=no
LOADER_DEST=
usage() { sed -n '2,25p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) [ $# -ge 2 ] || { echo "--rootfs needs a value" >&2; exit 64; }; ROOTFS_TAR=$2; shift 2 ;;
        --dest)   [ $# -ge 2 ] || { echo "--dest needs a value" >&2; exit 64; };   DEST=$2; shift 2 ;;
        --loader) [ $# -ge 2 ] || { echo "--loader needs a value" >&2; exit 64; }; LOADER=$2; shift 2 ;;
        --loader-dest) [ $# -ge 2 ] || { echo "--loader-dest needs a value" >&2; exit 64; }; LOADER_DEST=$2; shift 2 ;;
        --user)   [ $# -ge 2 ] || { echo "--user needs a value" >&2; exit 64; };   USER_NAME=$2; shift 2 ;;
        --fresh)  FRESH=yes; shift ;;
        --upgrade) UPGRADE=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install-husk: unknown argument $1" >&2; exit 64 ;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$UPGRADE" = yes ]; then
    [ -n "$DEST" ] || { echo "install-husk: --upgrade needs --dest" >&2; usage >&2; exit 64; }
    [ -f "$DEST/etc/os-release" ] || { echo "install-husk: --upgrade target has no etc/os-release: $DEST" >&2; exit 66; }
else
    [ -n "$ROOTFS_TAR" ] || { echo "install-husk: --rootfs is required" >&2; usage >&2; exit 64; }
fi

# --upgrade swaps libc and the guest tools underneath whatever is already
# running. Doing that to a live session gives half the processes the old build
# and half the new one; the observed symptom is gnome-shell dying with 139.
# Refuse by default and say how to proceed.
if [ "$UPGRADE" = yes ] && [ -z "${HUSK_ALLOW_LIVE_UPGRADE:-}" ]; then
    _busy=
    for _e in /proc/[0-9]*/exe; do
        _t=$(ls -l "$_e" 2>/dev/null | sed 's/.* -> //') || continue
        case "$_t" in
            "$DEST/../.."*|"$HERE/libld.so"|*/husk/libld.so) _busy=$_e ;;
        esac
        [ -n "$_busy" ] && break
    done
    if [ -n "$_busy" ]; then
        echo "install-husk: a Husk session is running ($_busy)." >&2
        echo "  Stop the session (or force-stop the app), then re-run --upgrade." >&2
        echo "  Override only for a throwaway tree: HUSK_ALLOW_LIVE_UPGRADE=1" >&2
        exit 75
    fi
fi

# The patched libc is built for *this* loader. A session that keeps launching an
# older loader while the tree carries the new libc segfaults (exit 139). When the
# tree lives at <app>/files/linux/distributions/<dist>/rootfs, the session loader
# is <app>/files/linux/husk/libld.so; sync it unless told otherwise.
if [ -z "$LOADER_DEST" ] && [ "$UPGRADE" = yes ]; then
    _huskdir=$(cd "$DEST/../.." 2>/dev/null && pwd) || _huskdir=
    [ -n "$_huskdir" ] && [ -d "$_huskdir/husk" ] && LOADER_DEST="$_huskdir/husk/libld.so"
fi
# --rootfs may be a local tarball or a URL; in a terminal (Termux) a URL is the
# normal case, so that path is not a special case here.
is_url=no
if [ "$UPGRADE" = no ]; then
case "$ROOTFS_TAR" in
    http://*|https://*) is_url=yes ;;
    *) [ -f "$ROOTFS_TAR" ] || { echo "install-husk: no such rootfs tarball: $ROOTFS_TAR" >&2; exit 66; } ;;
esac
fi
: "${DEST:=$HERE/root}"
: "${LOADER:=$HERE/libld.so}"

# Everything below works on absolute paths: the launcher we generate has to work
# from any cwd, and half of the failure modes on Android are relative-path ones.
#
# Extraction is not an upgrade operation: a stale /bin directory stops tar from
# creating the usr-merge /bin -> usr/bin link, and pass 2 then fails with
# "usr/bin/env: '/bin/sh': No such file or directory". Refuse a non-empty target
# unless the caller explicitly opts into replacement.
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd -P)
[ "$DEST" != / ] || { echo "install-husk: refusing to use / as --dest" >&2; exit 64; }
if [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    if [ "$UPGRADE" = yes ]; then
        echo "== upgrade target: $DEST (files kept, no extraction) =="
    elif [ "$FRESH" = yes ]; then
        echo "== fresh target: replacing $DEST =="
        rm -rf "$DEST"
        mkdir -p "$DEST"
        DEST=$(cd "$DEST" && pwd -P)
    else
        echo "install-husk: destination is not empty: $DEST" >&2
        echo "               use an empty directory or pass --fresh to replace it" >&2
        exit 65
    fi
fi
OUT=$(dirname "$DEST")

# Version: one source of truth, the VERSION file shipped next to this script
# (repo root when run from a checkout). `./husk --version` prints exactly this
# string, and `make version-check` keeps it equal to the newest CHANGELOG entry.
HUSK_VERSION=${HUSK_VERSION:-}
if [ -z "$HUSK_VERSION" ]; then
    for f in "$HERE/VERSION" "$(pwd)/VERSION"; do
        if [ -f "$f" ]; then HUSK_VERSION=$(cat "$f"); break; fi
    done
fi
: "${HUSK_VERSION:=unknown}"
[ -x "$LOADER" ] || { echo "install-husk: loader not executable: $LOADER" >&2; exit 69; }
LOADER=$(cd "$(dirname "$LOADER")" && pwd)/$(basename "$LOADER")
# a URL is not a path yet; it is turned into one by the download step below
if [ "$UPGRADE" = no ]; then
    [ "$is_url" = yes ] || ROOTFS_TAR=$(cd "$(dirname "$ROOTFS_TAR")" && pwd)/$(basename "$ROOTFS_TAR")
fi

# mksh (Android's /bin/sh) and dash both need a writable TMPDIR for `$(...)`
# capture and here-documents. Under `run-as` nothing in /tmp or /data/local is
# writable, so pick one now instead of failing half-way through the install.
for t in ${TMPDIR:-} "$DEST/tmp" "$OUT/tmp"; do
    [ -n "$t" ] || continue
    if mkdir -p "$t" 2>/dev/null && [ -w "$t" ]; then
        TMPDIR=$(cd "$t" && pwd); export TMPDIR; break
    fi
done
[ -n "${TMPDIR:-}" ] || { echo "install-husk: no writable TMPDIR" >&2; exit 73; }

echo "== husk install =="
if [ "$UPGRADE" = yes ]; then echo "   rootfs : (upgrade, keeping $DEST)"; else echo "   rootfs : $ROOTFS_TAR"; fi
echo "   dest   : $DEST"
echo "   loader : $LOADER"

if [ "$is_url" = yes ]; then
    name=$(basename "${ROOTFS_TAR%%\?*}")
    echo "== download =="
    echo "   from : $ROOTFS_TAR"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 -o "$OUT/$name.part" "$ROOTFS_TAR" || { echo "install-husk: download failed" >&2; exit 67; }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$OUT/$name.part" "$ROOTFS_TAR" || { echo "install-husk: download failed" >&2; exit 67; }
    else
        echo "install-husk: need curl or wget to fetch a URL" >&2; exit 67
    fi
    mv "$OUT/$name.part" "$OUT/$name"
    ROOTFS_TAR=$OUT/$name
    echo "   saved: $ROOTFS_TAR"
fi

# 0. does the kernel let us execute the loader from this location? A noexec
#    mount is the single most confusing failure we have (it looks like the
#    loader is broken), so say it out loud now. Running the loader with no
#    program name prints "missing program name" and exits 1 - that output is
#    exactly what proves exec worked.
probe=$("$LOADER" 2>&1 || true)
case "$probe" in
    *"missing program name"*) ;;
    *)
        echo "install-husk: cannot execute the loader from here:" >&2
        echo "$probe" | head -3 | sed 's/^/    /' >&2
        echo "              a noexec mount looks like this; put the loader where" >&2
        echo "              exec is allowed (an app private dir under run-as allows it," >&2
        echo "              /data/local/tmp and most noexec mounts do not)." >&2
        exit 69 ;;
esac
# Library search path for guest_run()/the loader. It used to be computed inside
# the extraction pass, so --upgrade (which skips extraction) ran every guest call
# with LIBS unset and died under `set -u`.
# 注意：这里**不能**按"目录此刻是否存在"来二选一。--fresh 装到空目录时，DEST 在
# pass 1 之前是空的，`[ -d "$DEST/usr/lib/aarch64-linux-gnu" ]` 判假，于是 LIBS 塌成
# "$DEST/usr/lib"，pass 2 立刻报 `usr/bin/env: libc.so.6: cannot open shared object file`
# （2026-11-27 实测，defect H45）。升级装因为树已经在，所以从来没暴露。
# 搜索路径多列几项没有代价，缺的目录会被 loader 跳过。
LIBS="$DEST/lib/aarch64-linux-gnu:$DEST/usr/lib/aarch64-linux-gnu:$DEST/lib64:$DEST/lib:$DEST/usr/lib"

# Upgrade replaces binaries the running guest still has mapped: cp then fails
# with "Text file busy" (measured: husk-logd holding usr/bin/husk-logd). Stop
# every process whose cmdline points into this tree first - that is also the
# "forced exit" the session contract requires, so the install does not leave a
# half-old session behind.
if [ "$UPGRADE" = yes ]; then
    # /data/user/0 and /data/data are the same tree with different spellings;
    # the running helpers were started with the /data/data one.
    _dest_alt=$(printf '%s' "$DEST" | sed 's|^/data/user/0/|/data/data/|')
    _stopped=0
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null) || continue
        case " $_c " in
            *" $DEST "*|*" $_dest_alt "*)
                # 别把自己（以及拉起自己的父 shell）算进"残留会话"：安装器自己的
                # cmdline 里就带着 --dest 的绝对路径，2026-11-27 实测它 kill 掉了
                # 自己，输出停在 "loader : ..." 那行，installer 静默没做完（defect H44）。
                _pid=${_d#/proc/}
                [ "$_pid" = "$$" ] && continue
                [ "$_pid" = "$PPID" ] && continue
                case " $_c " in *" install-husk.sh "*) continue ;; esac
                kill "$_pid" 2>/dev/null && _stopped=$((_stopped + 1))
                ;;
        esac
    done
    if [ "$_stopped" -gt 0 ]; then
        echo "   stopped $_stopped guest process(es) still running from this tree"
        sleep 2
        for _d in /proc/[0-9]*; do
            [ -r "$_d/cmdline" ] || continue
            _c=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null) || continue
            case " $_c " in
                *" $DEST "*|*" $_dest_alt "*)
                    _pid=${_d#/proc/}
                    [ "$_pid" = "$$" ] && continue
                    [ "$_pid" = "$PPID" ] && continue
                    case " $_c " in *" install-husk.sh "*) continue ;; esac
                    kill -9 "$_pid" 2>/dev/null || true ;;
            esac
        done
        sleep 1
    fi
fi

if [ "$UPGRADE" = no ]; then
# 1. first pass: host tar. Hard links fail on Android; that is expected.
#    Pick the decompressor by magic: toybox tar handles .tar and .tar.gz, but not
#    xz/zstd, and images in the wild come as all four. .gz goes straight through
#    tar (see the gzclose note below); the others are staged to a plain tar.
echo "== pass 1: extract (hard-link errors are expected) =="
magic=$(od -An -tx1 -N6 "$ROOTFS_TAR" | tr -d ' \n')
dec=
rc=0
case "$magic" in
    1f8b*)
        # gzip: let tar decompress. Staging the stream through `gzip -dc > file`
        # is wrong on this device: toybox gzip writes the complete file and then
        # exits 1 with "gzclose: Inappropriate ioctl for device" (measured
        # 2026-11-24), so an honest exit-code check cannot tell that apart from a
        # truncated archive.
        # `set -e` is on, so the status has to be captured inside an `if`;
        # `cmd; rc=$?` would exit before rc is ever read.
        if tar xzf "$ROOTFS_TAR" -C "$DEST" > "$OUT/.husk-pass1.log" 2>&1; then
            rc=0
        else
            rc=$?
        fi ;;
    fd377a585a00*)  dec="xz -dc" ;;
    28b52ffd*)      dec="zstd -dc" ;;
    *)
        # Plain tar (and anything else tar can sniff on its own).
        if tar xf "$ROOTFS_TAR" -C "$DEST" > "$OUT/.husk-pass1.log" 2>&1; then
            rc=0
        else
            rc=$?
        fi ;;
esac
if [ -n "$dec" ]; then
    command -v "${dec%% *}" >/dev/null 2>&1 || { echo "install-husk: $ROOTFS_TAR is compressed but ${dec%% *} is not available" >&2; exit 67; }
    echo "   ($dec -> $OUT/.husk-pass1.tar)"
    $dec "$ROOTFS_TAR" > "$OUT/.husk-pass1.tar" || { echo "install-husk: decompression failed" >&2; exit 67; }
    case "$(od -An -tx1 -N2 "$OUT/.husk-pass1.tar" | tr -d ' \n')" in
        1f8b|fd37|28b5) echo "install-husk: $ROOTFS_TAR is compressed twice (a .gz of a .gz); pass the inner tarball" >&2
                        rm -f "$OUT/.husk-pass1.tar"; exit 67 ;;
    esac
    if tar xf "$OUT/.husk-pass1.tar" -C "$DEST" > "$OUT/.husk-pass1.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    rm -f "$OUT/.husk-pass1.tar"
fi
sed 's/^/   /' "$OUT/.husk-pass1.log"
# Two entry classes cannot be created by the *host* tar and are expected:
#
#  - hard links: SELinux refuses link(2) inside app data (EACCES/EPERM);
#  - symlinks whose target is absolute ("<entry> <target> not under <DEST>"):
#    the host tar resolves the target against the *host* / and refuses to write
#    outside the destination. Inside the guest the very same target is inside
#    the root, so pass 2 creates it, and step 2c then rewrites it to a relative
#    link. A stock Ubuntu base tarball is full of these
#    (/etc/alsa/conf.d/* -> /usr/share/alsa/alsa.conf.d/*, /etc/alternatives/*),
#    so refusing them made "install a normal distribution tarball" impossible:
#    measured 2026-11-26, a stock ubuntu-base/24.04 tree aborted here with 552
#    absolute links and the installer reported "this archive is not usable".
#
# Everything else still aborts. A pipe used to hide tar's exit status here, so a
# truncated or corrupt archive could "succeed" on an os-release check alone.
if [ "$rc" -ne 0 ]; then
    if grep -Eiv 'not under|link|had errors' "$OUT/.husk-pass1.log" \
        | grep -qiE 'error|cannot|denied|corrupt|unexpected'; then
        echo "install-husk: pass 1 failed (tar rc=$rc); this archive is not usable" >&2
        exit 68
    fi
    echo "   (pass 1 could not create hard links or absolute-target symlinks;"
    echo "    pass 2 recreates those names through the shim)"
fi
rm -f "$OUT/.husk-pass1.log"
[ -d "$DEST/bin" ] || { echo "install-husk: pass 1 produced no /bin - bad tarball?" >&2; exit 66; }

# 2. second pass: the guest's own tar through the loader, so link() -> copy.
echo "== pass 2: re-extract through the shim (fixes hard links) =="
mkdir -p "$DEST/tmp"
cp "$ROOTFS_TAR" "$DEST/tmp/.husk-rootfs.tar"
# Pass 2 is the only pass that has to succeed completely: it is the one that
# materialises hard links. So it goes to a log file and its exit status is read
# directly - a `| sed` here would report sed's status and hide a failed extract.
set +e
( cd "$DEST" && NR_ROOTFS=$DEST NR_LD=$LOADER "$LOADER" --library-path "$LIBS" usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NR_ROOTFS=$DEST NR_LD=$LOADER /bin/sh -c \
    'tar -xf /tmp/.husk-rootfs.tar -C / && rm -f /tmp/.husk-rootfs.tar' ) > "$OUT/.husk-pass2.log" 2>&1
rc2=$?
set -e
sed 's/^/   /' "$OUT/.husk-pass2.log"
rm -f "$OUT/.husk-pass2.log" "$DEST/tmp/.husk-rootfs.tar"
if [ "$rc2" -ne 0 ]; then
    echo "install-husk: pass 2 failed (tar rc=$rc2); hard links are not materialised, this tree is broken" >&2
    exit 69
fi
fi   # --upgrade: no extraction

# 2b. a release tarball leaves the mount points out on purpose
#     (tools/guest/make-release.sh): tmp/proc/sys/dev/run/root are recreated
#     here, so an install never inherits sockets or a stale /root.
mkdir -p "$DEST/dev" "$DEST/dev/shm" "$DEST/proc" "$DEST/sys" "$DEST/run" "$DEST/root" "$DEST/tmp"
chmod 1777 "$DEST/tmp"

# Android denies /proc/version to untrusted_app and gets /sys/class/net from
# the platform. The path shim routes both names into the guest root, so the
# installer has to materialise the values that are honest for this device.
# Without these files, configure scripts and network tools see ENOENT even
# though the loader itself is healthy.
_krel=$(uname -r 2>/dev/null || true)
_kver=$(uname -v 2>/dev/null || true)
_kmach=$(uname -m 2>/dev/null || true)
[ -n "$_krel" ] || _krel=unknown
[ -n "$_kmach" ] || _kmach=arm64
mkdir -p "$DEST/proc/sys/kernel"
if [ ! -s "$DEST/proc/version" ]; then
    printf 'Linux version %s (%s) %s\n' "$_krel" "$_kver" "$_kmach" > "$DEST/proc/version"
fi
if [ ! -s "$DEST/proc/sys/kernel/osrelease" ]; then
    printf '%s\n' "$_krel" > "$DEST/proc/sys/kernel/osrelease"
fi
chmod 444 "$DEST/proc/version" "$DEST/proc/sys/kernel/osrelease"

if [ -f "$HERE/guest-config/mksys-net.sh" ]; then
    sh "$HERE/guest-config/mksys-net.sh" "$DEST" >/dev/null
    echo "   wrote /sys/class/net/lo (guest-local network view)"
else
    echo "install-husk: guest-config/mksys-net.sh missing; /sys/class/net will be absent" >&2
fi

# 2b-0. D-Bus and DING both require an identity and a real Desktop directory.
# make-release intentionally omits /root (the verifier's home), so a clean
# install otherwise recreates an empty home and DING exits on ENOENT.
mkdir -p "$DEST/etc" "$DEST/var/lib/dbus" "$DEST/root/Desktop"
chmod 755 "$DEST/root" "$DEST/root/Desktop"
if [ ! -s "$DEST/etc/machine-id" ]; then
    _machine_id=$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null || true)
    [ ${#_machine_id} -eq 32 ] || { echo "install-husk: cannot generate a machine-id" >&2; exit 80; }
    printf '%s\n' "$_machine_id" > "$DEST/etc/machine-id"
fi
chmod 644 "$DEST/etc/machine-id"
# The stock tarball ships var/lib/dbus/machine-id as an *absolute* symlink to
# /etc/machine-id. `cp` would follow it and write the host's /etc — on Android
# that is a read-only system partition ("cp: Read-only file system") and the
# install aborts at the first dbus step. Replace the name with a regular file.
if [ -L "$DEST/var/lib/dbus/machine-id" ]; then rm -f "$DEST/var/lib/dbus/machine-id"; fi
if [ ! -s "$DEST/var/lib/dbus/machine-id" ] || ! cmp -s "$DEST/etc/machine-id" "$DEST/var/lib/dbus/machine-id"; then
    cat "$DEST/etc/machine-id" > "$DEST/var/lib/dbus/machine-id"
fi
chmod 644 "$DEST/var/lib/dbus/machine-id"

# 2b-0b. system-service identities and polkit policy. Ubuntu package postinst
# normally creates these accounts; an extracted release tree does not have a
# running package manager or a successful lock/PAM path. Install the minimum
# identities once, then install the sensor-proxy policy/rule that lets a local
# guest claim the NDK bridge through polkit.
if [ -f "$HERE/guest-config/provision-accounts.sh" ] && \
   [ -f "$HERE/guest-config/guest-accounts.txt" ]; then
    sh "$HERE/guest-config/provision-accounts.sh" "$DEST"
else
    echo "install-husk: guest account provisioner missing; polkit/system services may not start" >&2
fi
if [ -f "$HERE/guest-config/net.hadess.SensorProxy.policy" ] && \
   [ -f "$HERE/guest-config/60-husk-sensor-proxy.rules" ]; then
    mkdir -p "$DEST/usr/share/polkit-1/actions" "$DEST/usr/share/polkit-1/rules.d"
    cp "$HERE/guest-config/net.hadess.SensorProxy.policy" \
        "$DEST/usr/share/polkit-1/actions/net.hadess.SensorProxy.policy"
    cp "$HERE/guest-config/60-husk-sensor-proxy.rules" \
        "$DEST/usr/share/polkit-1/rules.d/60-husk-sensor-proxy.rules"
    chmod 644 "$DEST/usr/share/polkit-1/actions/net.hadess.SensorProxy.policy" \
        "$DEST/usr/share/polkit-1/rules.d/60-husk-sensor-proxy.rules"
    echo "   wrote polkit sensor policy + local claim rule"
else
    echo "install-husk: sensor-proxy polkit files missing; sensor D-Bus claims may be denied" >&2
fi

# 2b-0c. PipeWire's distro default autoloads module-access, which probes
# /proc/<pid>/root to detect Flatpak. Husk intentionally does not pass that
# path through, so the probe returns ENOENT and every client is treated as a
# Flatpak waiting forever for permissions. Install the unrestricted local
# config used by the session. This is required by GNOME Snapshot, whose camera
# provider is GStreamer -> PipeWire -> WirePlumber, not camera.sock.
if [ -f "$HERE/guest-config/pipewire.conf" ]; then
    mkdir -p "$DEST/etc/pipewire"
    cp "$HERE/guest-config/pipewire.conf" "$DEST/etc/pipewire/pipewire.conf"
    chmod 644 "$DEST/etc/pipewire/pipewire.conf"
    echo "   wrote etc/pipewire/pipewire.conf (local media access, no Flatpak probe)"
else
    echo "install-husk: guest-config/pipewire.conf missing; Snapshot camera discovery will fail" >&2
fi

# WirePlumber 0.4.17's stock config loads bluetooth.lua unconditionally. There
# is no BlueZ service in a Husk session; the Lua component aborts during init
# and prevents the V4L2 monitor from ever enumerating the camera facade.
if [ -f "$HERE/guest-config/wireplumber.conf" ]; then
    mkdir -p "$DEST/etc/wireplumber"
    cp "$HERE/guest-config/wireplumber.conf" "$DEST/etc/wireplumber/wireplumber.conf"
    chmod 644 "$DEST/etc/wireplumber/wireplumber.conf"
    echo "   wrote etc/wireplumber/wireplumber.conf (no Bluetooth dependency)"
else
    echo "install-husk: guest-config/wireplumber.conf missing; Snapshot camera discovery will fail" >&2
fi

# spa.v4l2 is loaded by WirePlumber after the guest loader has patched the
# startup objects, so the V4L2 preload must be installed as a separate DSO.
if [ -f "$HERE/guest/libhusk_v4l2.so" ]; then
    mkdir -p "$DEST/usr/lib/aarch64-linux-gnu"
    cp "$HERE/guest/libhusk_v4l2.so" "$DEST/usr/lib/aarch64-linux-gnu/libhusk_v4l2.so"
    chmod 755 "$DEST/usr/lib/aarch64-linux-gnu/libhusk_v4l2.so"
    echo "   wrote usr/lib/aarch64-linux-gnu/libhusk_v4l2.so"
else
    echo "install-husk: guest/libhusk_v4l2.so missing; standard camera clients will not open /dev/video*" >&2
fi

# PipeWire 1.0.5 disconnects an unchanged stream when a reconfigure carries
# range caps. The disconnect can remove a buffer while videoflip still copies
# it, which is the GNOME Snapshot SIGSEGV (139). Install the audited plugin only
# when this rootfs actually carries the GStreamer PipeWire plugin; do not invent
# a package dependency on unrelated trees.
PIPEWIRE_PLUGIN="$HERE/guest/gstreamer-1.0/libgstpipewire.so"
PIPEWIRE_DEST="$DEST/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstpipewire.so"
PIPEWIRE_SHA=5baacf01e9a98f74a0d3fef88f8da16e9d6e54245b82e871a2b6844665ba7f01
if [ -f "$PIPEWIRE_PLUGIN" ]; then
    if [ -f "$PIPEWIRE_DEST" ]; then
        _pw_have=$(sha256sum "$PIPEWIRE_PLUGIN" | cut -d' ' -f1)
        [ "$_pw_have" = "$PIPEWIRE_SHA" ] || {
            echo "install-husk: bundled gstpipewire SHA mismatch: $_pw_have" >&2
            exit 74
        }
        cp "$PIPEWIRE_PLUGIN" "$PIPEWIRE_DEST"
        chmod 644 "$PIPEWIRE_DEST"
        _pw_installed=$(sha256sum "$PIPEWIRE_DEST" | cut -d' ' -f1)
        [ "$_pw_installed" = "$PIPEWIRE_SHA" ] || {
            echo "install-husk: installed gstpipewire SHA mismatch: $_pw_installed" >&2
            exit 74
        }
        echo "   wrote usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstpipewire.so (Snapshot 139 fix)"
    else
        echo "   skipped gstpipewire patch: target rootfs has no GStreamer PipeWire plugin" >&2
    fi
else
    echo "install-husk: guest/gstreamer-1.0/libgstpipewire.so missing; Snapshot may exit 139" >&2
fi

# 2b-1. DING announces itself by scanning /proc/<pid>/cmdline. Android hides some
# host processes from the app UID, and the extension treats one EACCES as a fatal
# init error: dock/DING/wallpaper never appear while gnome-shell looks healthy.
# Skip the unreadable entry; do not weaken /proc or SELinux.
DING_EXT="$DEST/usr/share/gnome-shell/extensions/ding@rastersoft.com/extension.js"
if [ -f "$DING_EXT" ]; then
    # Already guarded? The patch exists in two shapes (single line, or a try
    # block spanning lines) and a host-provided DING can carry its own guard.
    # Ask whether the load_bytes call sits inside a try block within 6 lines,
    # instead of matching one exact spelling of the fix.
    _ding_ok=no
    if awk '
        /try[[:space:]]*\{/ { t = NR }
        /processUser\.load_bytes\(null\)/ { if (t > 0 && NR - t < 7) ok = 1 }
        END { exit ok ? 0 : 1 }' "$DING_EXT"; then _ding_ok=yes; fi
    if [ "$_ding_ok" = no ]; then
        if grep -Fq 'let [binaryData, etag] = processUser.load_bytes(null);' "$DING_EXT"; then
            sed -i 's|let \[binaryData, etag\] = processUser.load_bytes(null);|let binaryData, etag; try { [binaryData, etag] = processUser.load_bytes(null); } catch (e) { continue; }|' "$DING_EXT"
        elif grep -Fq 'let [binaryData] = processUser.load_bytes(null);' "$DING_EXT"; then
            sed -i 's|let \[binaryData\] = processUser.load_bytes(null);|let binaryData; try { [binaryData] = processUser.load_bytes(null); } catch (e) { continue; }|' "$DING_EXT"
        fi
        if awk '
            /try[[:space:]]*\{/ { t = NR }
            /processUser\.load_bytes\(null\)/ { if (t > 0 && NR - t < 7) ok = 1 }
            END { exit ok ? 0 : 1 }' "$DING_EXT"; then _ding_ok=yes; fi
    fi
    if [ "$_ding_ok" = no ]; then
        echo "install-husk: DING /proc compatibility patch did not apply; desktop icons would fail silently" >&2
        exit 80
    fi
    echo "   DING: unreadable /proc entries are skipped"
fi

# 2b-2. resolv.conf. A release tarball leaves it out (it is device identity), and
#       without it `apt-get update` dies on "Temporary failure resolving" while
#       the loader itself looks perfectly healthy. The app path gets this file
#       from the app; a standalone install has to write one.
if [ ! -s "$DEST/etc/resolv.conf" ]; then
    mkdir -p "$DEST/etc"
    {
        for ns in $(getprop net.dns1 2>/dev/null) $(getprop net.dns2 2>/dev/null); do
            case "$ns" in *[0-9]*) echo "nameserver $ns" ;; esac
        done
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
    } > "$DEST/etc/resolv.conf"
    echo "   wrote etc/resolv.conf ($(grep -c nameserver "$DEST/etc/resolv.conf") nameservers)"
fi

# 2b-2b-0. Mali kbase PanVK 发行快照。发行版 Mesa 只带 DRM/Panthor ICD；在只有
#        /dev/mali0 的 Android 设备上，树里没有这颗 glibc PanVK 时 GL 会安静地掉到
#        llvmpipe。这里只在宿主机确有 mali0 且目标树还没有 PanVK 驱动时解压固定快照，
#        不覆盖发行版或其他构建已有的驱动。驱动、ICD 和 MIT 许可证一起落盘。
_bundle_panvk_rel=vendor/panvk/fristonerr-1.2.0-mali-g77
# Keep the verified snapshot at a Husk-owned path. Reusing a vendor-looking
# filename let a stale file in an upgraded tree win the driver search while the
# canonical ICD still pointed at it (v0.0.37 regression: readback SIGSEGV).
_panvk_driver=usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so
# PanVK 驱动：0.0.37 起由源码构建，安装器只核对 SHA-256，不再就地改字节。
#
# 驱动里带两处源码改动（见 vendor/panvk/fristonerr-1.2.0-mali-g77/PROVENANCE.md）：
#   1. kbase 的 2 秒热身改成配置项（默认不睡）：上游每次建 kbase context 无条件
#      nanosleep 2 秒，是给 Mali-G57 绕"第一个 job 被终止"的；G77 不需要，
#      而每个 GL 进程建两次 context 就白等 4 秒（evidence 357）。
#      需要它的机器设 PANVK_KBASE_WARMUP_MS=2000。
#   2. vk_meta 缩放 blit 改单三角形（evidence 365）：原来 6 顶点/2 三角形在 Mali v9
#      上第二个三角形画歪，缩略图出现黑三角。
#
# 以前那种"按偏移改 16 字节"的做法已经废弃：源码改过了，再按旧偏移改就是错。
if ( : <> /dev/mali0 ) 2>/dev/null; then
    _pb="$HERE/$_bundle_panvk_rel"
    if [ -f "$_pb/libvulkan_panfrost_frist370_execva.so.gz" ] && \
       [ -f "$_pb/husk_panvk_guest.json" ]; then
        mkdir -p "$DEST/usr/lib/aarch64-linux-gnu" \
                 "$DEST/usr/share/vulkan/icd.d" \
                 "$DEST/usr/share/licenses/husk" \
                 "$DEST/usr/share/doc/husk/third-party/fristonerr-panvk"
        _pt="$DEST/tmp/.husk-panvk.$$"
        if ! gzip -dc "$_pb/libvulkan_panfrost_frist370_execva.so.gz" > "$_pt"; then
            rm -f "$_pt"
            echo "install-husk: bundled PanVK driver is corrupt" >&2
            exit 76
        fi
        _want=5e06324783ec7947d48782441fd1cac23953c90bd0b31663f98f08b22344c1c3
        _have=$(sha256sum "$_pt" | cut -d' ' -f1)
        if [ "$_have" != "$_want" ]; then
            rm -f "$_pt"
            echo "install-husk: bundled PanVK driver sha256 mismatch: $_have" >&2
            exit 76
        fi
        # 源码已经改过（热身=配置、blit=单三角形），这里只核对身份，不改字节。
        if [ "${PANVK_KBASE_WARMUP_MS:-0}" != 0 ] && [ -n "${PANVK_KBASE_WARMUP_MS:-}" ]; then
            echo "   PanVK: kbase warmup PANVK_KBASE_WARMUP_MS=$PANVK_KBASE_WARMUP_MS ms"
        fi
        echo "   PanVK: source-built driver verified ($_want)"
        chmod 755 "$_pt"
        mv "$_pt" "$DEST/$_panvk_driver"
        cp "$_pb/husk_panvk_guest.json" "$DEST/usr/share/vulkan/icd.d/husk_panvk_guest.json"
        cp "$_pb/LICENSE-Mesa.txt" "$DEST/usr/share/licenses/husk/FristOneRR-PanVK-MIT.txt"
        cp "$_pb/PROVENANCE.md" "$DEST/usr/share/doc/husk/third-party/fristonerr-panvk/PROVENANCE.md"
        chmod 644 "$DEST/usr/share/vulkan/icd.d/husk_panvk_guest.json" \
                  "$DEST/usr/share/licenses/husk/FristOneRR-PanVK-MIT.txt" \
                  "$DEST/usr/share/doc/husk/third-party/fristonerr-panvk/PROVENANCE.md"
        echo "   installed bundled PanVK 1.2.0 ($_panvk_driver)"
        unset _pt _want _have
    else
        echo "   WARNING: /dev/mali0 is available but the release bundle has no PanVK snapshot;" >&2
        echo "            GL will fall back to llvmpipe unless the rootfs already carries a kbase driver." >&2
    fi
    unset _pb
fi
unset _bundle_panvk_rel _panvk_driver

# 2b-2b-0b. 高通（Adreno / KGSL）Turnip 发行快照。发行版 Mesa 的 freedreno ICD 指向
#        发行版自带的 libvulkan_freedreno.so，在只有 /dev/kgsl-3d0 的 Android 设备上
#        那份驱动枚举不出物理设备（zink 选不到 pdev -> gnome-shell 退出 139）。
#        这里只在宿主机确有 kgsl-3d0 时解压 Husk 源码构建的 Turnip，并落一份 guest
#        相对路径的 canonical ICD。与 Mali 的 PanVK 完全分开：两套后端、两套 ICD、
#        两套环境变量面，互不覆盖。
_bundle_turnip_rel=vendor/turnip/d211037c-adreno-825
_turnip_driver=usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so
if ( : <> /dev/kgsl-3d0 ) 2>/dev/null; then
    _tb="$HERE/$_bundle_turnip_rel"
    if [ -f "$_tb/libvulkan_freedreno_husk.so.gz" ] && \
       [ -f "$_tb/husk_turnip_guest.json" ]; then
        mkdir -p "$DEST/usr/lib/aarch64-linux-gnu" \
                 "$DEST/usr/share/vulkan/icd.d" \
                 "$DEST/usr/share/licenses/husk" \
                 "$DEST/usr/share/doc/husk/third-party/husk-turnip"
        _tt="$DEST/tmp/.husk-turnip.$$"
        if ! gzip -dc "$_tb/libvulkan_freedreno_husk.so.gz" > "$_tt"; then
            rm -f "$_tt"
            echo "install-husk: bundled Turnip driver is corrupt" >&2
            exit 76
        fi
        _want=35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5
        _have=$(sha256sum "$_tt" | cut -d' ' -f1)
        if [ "$_have" != "$_want" ]; then
            rm -f "$_tt"
            echo "install-husk: bundled Turnip driver sha256 mismatch: $_have" >&2
            exit 76
        fi
        echo "   Turnip: source-built driver verified ($_want)"
        chmod 755 "$_tt"
        mv "$_tt" "$DEST/$_turnip_driver"
        cp "$_tb/husk_turnip_guest.json" \
           "$DEST/usr/share/vulkan/icd.d/husk_turnip_guest.json"
        cp "$_tb/LICENSE-Mesa.txt" "$DEST/usr/share/licenses/husk/Husk-Turnip-MIT.txt"
        cp "$_tb/PROVENANCE.md" \
           "$DEST/usr/share/doc/husk/third-party/husk-turnip/PROVENANCE.md"
        chmod 644 "$DEST/usr/share/vulkan/icd.d/husk_turnip_guest.json" \
                  "$DEST/usr/share/licenses/husk/Husk-Turnip-MIT.txt" \
                  "$DEST/usr/share/doc/husk/third-party/husk-turnip/PROVENANCE.md"
        echo "   installed bundled Turnip ($_turnip_driver)"
        unset _tt _want _have
    else
        echo "   WARNING: /dev/kgsl-3d0 is available but the release bundle has no Turnip snapshot;" >&2
        echo "            GL will fall back to llvmpipe or to the distro freedreno ICD." >&2
    fi
    unset _tb
fi
unset _bundle_turnip_rel _turnip_driver

# 2b-2b. GPU 运行时默认值：写进 /etc/profile.d，让"进到 guest 里再开程序"也拿到
#        ICD 与 GL 驱动（husk-session.sh 覆盖的是它自己拉起的那一条会话链）。
if [ -f "$HERE/guest-config/husk-gpu-defaults.sh" ]; then
    mkdir -p "$DEST/etc/profile.d"
    cp "$HERE/guest-config/husk-gpu-defaults.sh" "$DEST/etc/profile.d/husk-gpu.sh"
    chmod 644 "$DEST/etc/profile.d/husk-gpu.sh"
    echo "   wrote etc/profile.d/husk-gpu.sh (GPU defaults, escape: HUSK_GPU=llvmpipe)"
else
    # Not fatal (a tree can carry the file already), but it must never be silent:
    # measured 2026-11-24, the release bundle was built without guest-config/ and
    # every install from it had no GPU defaults and no error to show for it.
    echo "   WARNING: no guest-config/husk-gpu-defaults.sh next to the installer;" >&2
    echo "            etc/profile.d/husk-gpu.sh is NOT installed (no GPU defaults)." >&2
fi

# 2b-2b-2. 壁纸预缩放脚本（evidence 195）：放进 rootfs，会话起来后由
#         husk-session.sh 的看护进程调用。没有它壁纸上会缺一块（zink 右侧三角 32% 亮度）。
_wallpaper_scale=
for _ws in \
    "$HERE/guest/wallpaper-scale" \
    "$HERE/../../runtime/target/aarch64-unknown-linux-gnu/release/wallpaper-scale"; do
    [ -x "$_ws" ] && { _wallpaper_scale=$_ws; break; }
done
if [ -n "$_wallpaper_scale" ]; then
    mkdir -p "$DEST/usr/local/share/linuxhub"
    cp "$_wallpaper_scale" "$DEST/usr/local/share/linuxhub/wallpaper-scale"
    chmod 755 "$DEST/usr/local/share/linuxhub/wallpaper-scale"

    # The system bus config the desktop scripts point dbus-daemon at. Ubuntu's
    # own /usr/share/dbus-1/system.conf wants systemd activation and polkit;
    # without a working system bus gnome-shell dies in main.js and the user only
    # sees the "security mode" fallback. Trees produced outside this installer
    # (2.0 trees, hand-assembled desktop trees) do not necessarily carry it, and
    # its absence is silent -- the session scripts just skip starting the bus.
    if [ -f "$HERE/guest-config/linuxhub-system-bus.conf" ]; then
        cp "$HERE/guest-config/linuxhub-system-bus.conf" \
            "$DEST/usr/local/share/linuxhub/linuxhub-system-bus.conf"
        chmod 644 "$DEST/usr/local/share/linuxhub/linuxhub-system-bus.conf"
        echo "   wrote usr/local/share/linuxhub/linuxhub-system-bus.conf (system bus)"
    else
        echo "   WARNING: no guest-config/linuxhub-system-bus.conf next to the installer;" >&2
        echo "            the desktop session may fall back to GNOME security mode." >&2
    fi
    echo "   wrote usr/local/share/linuxhub/wallpaper-scale (Rust wallpaper pre-scale)"
else
    echo "   WARNING: no guest/wallpaper-scale next to the installer;" >&2
    echo "            the wallpaper stays un-fitted (zink: right-side wedge at 32% brightness)." >&2
fi
# 看护脚本本身也必须装上：husk-session.sh 只会调用 $BASE/husk-wallpaper-fit.sh，
# 之前只装了 .js，于是"拟合"这一步在真实安装里从来没跑过（壁纸要么不缩放、要么整张缺失）。
# 这个脚本在发行包里放在顶层（husk-session.sh 按 $BASE/husk-wallpaper-fit.sh 找它），
# 而安装器原先只认 guest/ 下的位置，于是每装一次就多一条 WARNING、并少装一个文件。
for _wf in "$HERE/guest/husk-wallpaper-fit.sh" "$HERE/husk-wallpaper-fit.sh"; do
    [ -f "$_wf" ] && { _wf_src=$_wf; break; }
done
if [ -n "${_wf_src:-}" ]; then
    cp "$_wf_src" "$DEST/usr/local/share/linuxhub/husk-wallpaper-fit.sh"
    chmod 755 "$DEST/usr/local/share/linuxhub/husk-wallpaper-fit.sh"
    echo "   wrote usr/local/share/linuxhub/husk-wallpaper-fit.sh (wallpaper fit + 兜底)"
else
    echo "   WARNING: no guest/husk-wallpaper-fit.sh next to the installer;" >&2
    echo "            the pre-scaled wallpaper will never be generated." >&2
fi

# 2b-2b'. locale 默认值：同一类问题——只写 /etc/default/locale 会被非登录进程绕过。
if [ -f "$HERE/guest-config/husk-locale.sh" ]; then
    mkdir -p "$DEST/etc/profile.d"
    cp "$HERE/guest-config/husk-locale.sh" "$DEST/etc/profile.d/husk-locale.sh"
    chmod 644 "$DEST/etc/profile.d/husk-locale.sh"
    if [ -f "$DEST/usr/lib/locale/locale-archive" ] || [ -d "$DEST/usr/lib/locale/zh_CN.utf8" ]; then
        mkdir -p "$DEST/etc/default"
        printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > "$DEST/etc/default/locale"
        echo "   wrote etc/profile.d/husk-locale.sh + etc/default/locale (zh_CN.UTF-8)"
    else
        echo "   wrote etc/profile.d/husk-locale.sh (no zh_CN.utf8 locale in this rootfs; LANG left alone)"
    fi
else
    echo "WARNING: no guest-config/husk-locale.sh next to the installer; locale defaults are NOT installed." >&2
fi

# 2b-2b''. fcitx5 的默认输入法组（键盘 + 拼音）。只在没有时写，用户改过就不覆盖。
if [ -f "$HERE/guest-config/fcitx5-profile" ] && [ -x "$DEST/usr/bin/fcitx5" ]; then
    if [ ! -f "$DEST/root/.config/fcitx5/profile" ]; then
        mkdir -p "$DEST/root/.config/fcitx5"
        cp "$HERE/guest-config/fcitx5-profile" "$DEST/root/.config/fcitx5/profile"
        chmod 644 "$DEST/root/.config/fcitx5/profile"
        echo "   wrote root/.config/fcitx5/profile (keyboard + pinyin)"
    fi
fi

# 2b-2b'''. 中文界面翻译包（可选）：树包旁边有 husk-lang-zh.tar.gz 就解开。
# 没有也不报错——locale、字体、输入法都不受影响，只是界面文字回到英文。
if [ -f "$HERE/husk-lang-zh.tar.gz" ]; then
    mkdir -p "$DEST/usr/share"
    tar xzf "$HERE/husk-lang-zh.tar.gz" -C "$DEST"
    n=$(ls "$DEST/usr/share/locale-langpack/zh_CN/LC_MESSAGES/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -lt 400 ]; then
        echo "install-husk: lang pack unpacked only ${n:-0} .mo files - do not ship this tree" >&2
        exit 74
    fi
    echo "   installed zh_CN lang pack ($n .mo files in usr/share/locale-langpack)"
else
    echo "   no husk-lang-zh.tar.gz next to the installer; UI text stays English"
fi

# 2b-2c. 同一份默认值也给加载器。`/etc/profile.d` 只对登录 shell 生效；cron、systemd
#        user unit、桌面 fork 出来的进程、`env -i`、`ssh host -- prog` 都读不到它，
#        于是同一个 rootfs 里会出现"终端里的程序吃 GPU、别处的掉回 llvmpipe"。
#        加载器只在这些变量"没人设置过"时补默认值，程序自己 export 的永远优先；
#        覆盖/屏蔽只用于清掉旧 2.0 会话硬塞的 swrast 默认值。
#        文件第一行记录 GPU 家族；rootfs 被搬到别的 GPU 家族时，加载器不会注入
#        错误家族的 ICD/驱动，登录 shell 仍会按当前设备节点重新探测。
#        ICD 文件名随 Mesa 构建变，所以在这里解析一次写死，不在 Rust 里猜。
mkdir -p "$DEST/etc/husk"
: > "$DEST/etc/husk/gpu-env"
_husk_gpu_family=software
if ( : <> /dev/mali0 ) 2>/dev/null; then
    _husk_gpu_family=mali-kbase
elif ( : <> /dev/kgsl-3d0 ) 2>/dev/null; then
    _husk_gpu_family=adreno-kgsl
elif ( : <> /dev/dri/renderD128 ) 2>/dev/null; then
    _husk_gpu_family=drm-node
fi
_husk_icd=
if [ "$_husk_gpu_family" = mali-kbase ]; then
    # Do not select a shipping ICD by glob order. Some PanVK manifests in the
    # tree contain host absolute /data/data/... library_path values; the shim
    # translates those as guest paths and the Vulkan loader then dereferences a
    # null library. Generate one canonical manifest with a guest path, and only
    # advertise it when its driver really exists.
    _husk_driver=
    for _drv in \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost_frist370_execva.so \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost_frist370.so \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost_x11.so \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost_g77.so \
        usr/lib/aarch64-linux-gnu/libvulkan_panfrost.so
    do
        if [ -r "$DEST/$_drv" ]; then
            _husk_driver=$_drv
            break
        fi
    done
    if [ -n "$_husk_driver" ]; then
        _husk_api=1.0.0
        for _src in \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_guest.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_frist370_execva.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_frist370.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_x11.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_g77.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk.json
        do
            [ -r "$_src" ] || continue
            _candidate=$(sed -n 's/.*"api_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_src" | head -n 1)
            case "$_candidate" in
                ""|*[!0-9.]*) ;;
                *) _husk_api=$_candidate; break ;;
            esac
        done
        mkdir -p "$DEST/usr/share/vulkan/icd.d"
        {
            echo '{'
            echo '  "ICD": {'
            echo "    \"api_version\": \"$_husk_api\","
            echo '    "library_arch": "64",'
            echo "    \"library_path\": \"/$_husk_driver\""
            echo '  },'
            echo '  "file_format_version": "1.0.1"'
            echo '}'
        } > "$DEST/usr/share/vulkan/icd.d/husk_panvk_guest.json"
        chmod 644 "$DEST/usr/share/vulkan/icd.d/husk_panvk_guest.json"
        _husk_icd=/usr/share/vulkan/icd.d/husk_panvk_guest.json
        echo "   wrote usr/share/vulkan/icd.d/husk_panvk_guest.json (guest-relative: /$_husk_driver)"
        # The host pins one legacy manifest name of its own accord
        # (doro-gpu-run hard-codes husk_panvk_frist370_execva.json). Deleting
        # that file makes gnome-shell exit 139 on 2026-11-27 hardware, so the
        # tree cannot ship "canonical only". Keep the legacy names but retarget
        # them at the canonical driver: same manifest content, no second .so,
        # and no .bak-* copy left for the loader to pick up by accident.
        for _legacy in \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_frist370_execva.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_frist370.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_x11.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk_g77.json \
            "$DEST"/usr/share/vulkan/icd.d/husk_panvk.json
        do
            [ -f "$_legacy" ] || continue
            {
                echo '{'
                echo '  "ICD": {'
                echo "    \"api_version\": \"$_husk_api\","
                echo '    "library_arch": "64",'
                echo "    \"library_path\": \"/$_husk_driver\""
                echo '  },'
                echo '  "file_format_version": "1.0.1"'
                echo '}'
            } > "$_legacy"
            chmod 644 "$_legacy"
            echo "   retargeted $(basename "$_legacy") -> /$_husk_driver"
        done
        rm -f "$DEST"/usr/share/vulkan/icd.d/husk_panvk*.json.bak-* 2>/dev/null || true
        # 0.0.37 · 清掉实验期留下的过期 ICD 与驱动副本（evidence 357 §7 / defect H43）。
        # 两份驱动字节相同时它们不致命，但只要驱动一升级，旧副本就可能先被选中；而且
        # husk_panvk_nosleep_test.json 这种"名字带 nosleep"的清单会让人误判补丁状态。
        # 只在 canonical 驱动确实存在时才删，绝不把树上唯一的驱动删掉。
        if [ "$_husk_driver" = usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so ]; then
            rm -f "$DEST"/usr/share/vulkan/icd.d/*nosleep*.json 2>/dev/null || true
            for _stale in \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk_nosleep.so \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so.bak-orig \
                usr/lib/aarch64-linux-gnu/.libvulkan_panfrost_husk.so.bak-orig \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_x11.so \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_frist370_execva.so \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_frist370.so \
                usr/lib/aarch64-linux-gnu/libvulkan_panfrost_g77.so
            do
                [ -f "$DEST/$_stale" ] || continue
                rm -f "$DEST/$_stale"
                echo "   removed stale GPU artifact $_stale"
            done
            unset _stale
        fi
    else
        echo "   no PanVK driver in the tree; refusing to select a manifest without its driver" >&2
    fi
    unset _husk_driver _husk_api _src _candidate _drv
elif [ "$_husk_gpu_family" = adreno-kgsl ]; then
    # Husk 自己那份排在第一位：发行版 freedreno ICD 在 kgsl 上枚举不出设备。
    for _c in \
        "$DEST"/usr/share/vulkan/icd.d/husk_turnip_guest.json \
        "$DEST"/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
        "$DEST"/usr/share/vulkan/icd.d/freedreno_icd.json \
        "$DEST"/usr/share/vulkan/icd.d/*freedreno*.json \
        "$DEST"/usr/share/vulkan/icd.d/*turnip*.json
    do
        [ -r "$_c" ] || continue
        _husk_icd="/usr/share/vulkan/icd.d/${_c##*/}"
        break
    done
fi

{
    echo "@GPU_FAMILY=$_husk_gpu_family"
    if [ "$_husk_gpu_family" = mali-kbase ] && [ -n "$_husk_icd" ]; then
        echo "VK_ICD_FILENAMES=$_husk_icd"
        echo "VK_DRIVER_FILES=$_husk_icd"
        # LinuxHub 2.0 的会话脚本会 export swrast/llvmpipe；Husk 原生路径已在
        # evidence 187/191 证实整屏 zink 可用，所以覆盖这两个旧默认值。
        echo "!MESA_LOADER_DRIVER_OVERRIDE=zink"
        echo "!GALLIUM_DRIVER=zink"
        # LIBGL_ALWAYS_SOFTWARE 比 GALLIUM_DRIVER 更优先，必须让它不可见。
        echo "-LIBGL_ALWAYS_SOFTWARE"
        echo "MESA_GLES_VERSION_OVERRIDE=3.2"
        # PanVK 构建默认打开 DXVK 兼容特性并暴露 geometryShader；zink 的
        # 四边形模拟 GS 会打崩当前 Bifrost 后端。普通 GL/桌面默认关闭，
        # DXVK 程序可在自己的环境里显式覆盖成 1。
        echo "PANVK_DXVK_COMPAT=0"
        # GTK4 的 GL 后端在 zink/PanVK 上有可复现的三角缺口；只影响 GTK 自己。
        echo "GSK_RENDERER=cairo"
    elif [ "$_husk_gpu_family" = adreno-kgsl ] && [ -n "$_husk_icd" ]; then
        echo "VK_ICD_FILENAMES=$_husk_icd"
        echo "VK_DRIVER_FILES=$_husk_icd"
        echo "TURNIP_KMD=kgsl"
        echo "FD_FORCE_KGSL=1"
        echo "MESA_VK_WSI_PRESENT_MODE=mailbox"
        echo "vblank_mode=0"
        echo "-LIBGL_ALWAYS_SOFTWARE"
        # GTK4 的 GL 后端在 zink 上仍有可复现的绘制缺口（与 Mali 同一个问题），
        # 只影响 GTK 自己，桌面合成仍然走 zink。
        echo "GSK_RENDERER=cairo"
        # 原生 freedreno（kgsl_dri）在 Adreno 825 上实测壁纸成块状错色（evidence 370/371），
        # 所以只要树里有 Husk 的 Turnip，就固定走 zink -> Turnip；原生只作为回退。
        _husk_gl=zink
        if [ ! -r "$DEST/usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so" ]; then
            _husk_native_gl=0
            for _d in "$DEST"/usr/lib/*/dri/kgsl_dri.so "$DEST"/usr/lib/*/dri/freedreno_dri.so; do
                if [ -r "$_d" ]; then _husk_native_gl=1; break; fi
            done
            [ "$_husk_native_gl" = 1 ] && _husk_gl=native
            unset _husk_native_gl _d
        fi
        if [ "$_husk_gl" = native ]; then
            echo "!MESA_LOADER_DRIVER_OVERRIDE=kgsl"
            echo "!GALLIUM_DRIVER=freedreno"
        else
            echo "!MESA_LOADER_DRIVER_OVERRIDE=zink"
            echo "!GALLIUM_DRIVER=zink"
        fi
        unset _husk_gl
    fi
} > "$DEST/etc/husk/gpu-env"
chmod 644 "$DEST/etc/husk/gpu-env"
if [ -n "$_husk_icd" ]; then
    echo "   wrote etc/husk/gpu-env ($_husk_gpu_family, ICD: $_husk_icd)"
elif [ "$_husk_gpu_family" = mali-kbase ] || [ "$_husk_gpu_family" = adreno-kgsl ]; then
    echo "   no matching GPU ICD in the tree; etc/husk/gpu-env records $_husk_gpu_family only" >&2
else
    echo "   wrote etc/husk/gpu-env ($_husk_gpu_family; no driver override)"
fi
unset _c _d _husk_icd _husk_native_gl _husk_gl _husk_gpu_family

# 2b-4. 外观默认值：gschema override。Ubuntu 的 Yaru 外观是 `ubuntu-settings` 用
#       gschema override 钉出来的，这个 rootfs 里没有那个包（yaru 的主题文件都在），
#       于是 GTK 程序全是 Adwaita + Cantarell —— 外壳有 Yaru、窗口是白板，就是用户看到的
#       "主题全丢了"。这里补一份同义的最小 override，并重新编译 schema。
#       只写默认值：用户/程序 set 过的键优先。
LOOK="$HERE/guest-config/husk-look.override"
if [ -f "$LOOK" ] && [ -d "$DEST/usr/share/themes/Yaru" ] &&
   [ -d "$DEST/usr/share/fonts/truetype/ubuntu" ] && [ -x "$DEST/usr/bin/glib-compile-schemas" ]; then
    mkdir -p "$DEST/usr/share/glib-2.0/schemas"
    cp "$LOOK" "$DEST/usr/share/glib-2.0/schemas/99-husk-look.gschema.override"
    chmod 644 "$DEST/usr/share/glib-2.0/schemas/99-husk-look.gschema.override"
    # No `| sed` on the compile itself: a pipeline returns the *last* command's
    # status, which is how a failed unpack once reported success (evidence review
    # 2026-11-24, BUG-01). Log to a file, test the real exit code, then indent.
    _looklog="$OUT/.husk-look.log"
    if ( cd "$DEST" && NR_ROOTFS=$DEST NR_LD=$LOADER "$LOADER" --library-path "$LIBS" usr/bin/env -i \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            NR_ROOTFS=$DEST NR_LD=$LOADER usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas ) \
            > "$_looklog" 2>&1
    then
        sed 's/^/   /' "$_looklog"
        echo "   wrote usr/share/glib-2.0/schemas/99-husk-look.gschema.override (Yaru / Ubuntu 11)"
    else
        sed 's/^/   /' "$_looklog"
        echo "   WARNING: glib-compile-schemas failed (rc=$?); override written but NOT compiled," >&2
        echo "            so GTK programs keep Adwaita defaults." >&2
    fi
    rm -f "$_looklog"
elif [ -f "$LOOK" ]; then
    echo "   no Yaru theme / Ubuntu font / glib-compile-schemas in this tree; look defaults skipped" >&2
fi

# 2b-5. PulseAudio 客户端关掉 SHM。guest 里的 pulse 客户端与服务器走 memfd 共享内存
#       握手时会被服务器断连（"Received SHM frame on a socket where SHM is disabled"），
#       结果就是"装了 pulseaudio 但没有一个程序能出声"。关掉 SHM 走纯 socket 即可，
#       实测 evidence 193。放在 client.conf.d 里是因为 Debian/Ubuntu 的 pulse 会读这个目录。
PULSECONF="$HERE/guest-config/pulse-client-no-shm.conf"
if [ -f "$PULSECONF" ] && [ -d "$DEST/usr/lib/pulse-16.1+dfsg1" ]; then
    mkdir -p "$DEST/etc/pulse/client.conf.d"
    cp "$PULSECONF" "$DEST/etc/pulse/client.conf.d/99-husk-no-shm.conf"
    chmod 644 "$DEST/etc/pulse/client.conf.d/99-husk-no-shm.conf"
    echo "   wrote etc/pulse/client.conf.d/99-husk-no-shm.conf (enable-shm=no)"
fi

# 2b-3. log directories apt and dpkg expect. The release tarball drops var/log
#       (session logs of the verifying device); without these, every install
#       prints `E: Directory '/var/log/apt/' missing` and apt still exits with an
#       error code even though the package went in.
mkdir -p "$DEST/var/log/apt" "$DEST/var/log/apt/periodic"
: > "$DEST/var/log/dpkg.log"

# 2c. absolute symlinks. The guest loader is a host process, so the kernel
#     resolves a link target against the *host* root: /etc/alternatives/...
#     escapes the tree and dlopen() reports ENOENT for a library that is right
#     there (evidence 155). Rewrite them relative, then verify none is left.
echo "== symlinks: absolute -> relative =="
if [ -f "$HERE/husk-symlinks" ]; then
    cp "$HERE/husk-symlinks" "$DEST/usr/bin/husk-symlinks"
    chmod 755 "$DEST/usr/bin/husk-symlinks"
fi
guest_run() {
    ( cd "$DEST" && NR_ROOTFS=$DEST NR_LD=$LOADER "$LOADER" --library-path "$LIBS" usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        NR_ROOTFS=$DEST NR_LD=$LOADER "$@" )
}
if [ -x "$DEST/usr/bin/husk-symlinks" ]; then
    # Both calls report through a log file, for the same reason as pass 2: a
    # `| sed` would make a failing `--verify` look like success.
    set +e
    guest_run usr/bin/husk-symlinks --root / --apply > "$OUT/.husk-sym.log" 2>&1
    rc_apply=$?
    guest_run usr/bin/husk-symlinks --root / --verify --quiet >> "$OUT/.husk-sym.log" 2>&1
    rc_verify=$?
    set -e
    sed 's/^/   /' "$OUT/.husk-sym.log"
    rm -f "$OUT/.husk-sym.log"
    if [ "$rc_apply" -ne 0 ] || [ "$rc_verify" -ne 0 ]; then
        echo "install-husk: absolute symlinks still escape the rootfs (apply rc=$rc_apply, verify rc=$rc_verify); those names will not dlopen" >&2
        exit 71
    fi
else
    echo "   (this bundle has no husk-symlinks; absolute links, if any, stay)" >&2
fi

# 2d. the guest libc is not stock (slot page + clone3 -> ENOSYS, LIMITATIONS 4).
#     If the tree carries a different libc than the one this bundle shipped, it
#     is either a distro upgrade or a stale image; both die later with a
#     misleading `Cannot fork`. Put the bundled one back and say so.
echo "== libc =="
shipped_libc="$HERE/libc.so.6"
tree_libc="$DEST/usr/lib/aarch64-linux-gnu/libc.so.6"
[ -f "$tree_libc" ] || tree_libc="$DEST/lib/aarch64-linux-gnu/libc.so.6"
libc_sha=
if [ -f "$shipped_libc" ] && [ -f "$tree_libc" ]; then
    want=$(sha256sum "$shipped_libc" | cut -d' ' -f1)
    have=$(sha256sum "$tree_libc" | cut -d' ' -f1)
    if [ "$want" != "$have" ]; then
        echo "   tree libc $(echo "$have" | cut -c1-12) != bundle $(echo "$want" | cut -c1-12): restoring"
        cp "$shipped_libc" "$DEST/usr/lib/aarch64-linux-gnu/libc.so.6"
        [ "$tree_libc" = "$DEST/lib/aarch64-linux-gnu/libc.so.6" ] && \
            cp "$shipped_libc" "$DEST/lib/aarch64-linux-gnu/libc.so.6"
        chmod 755 "$DEST/usr/lib/aarch64-linux-gnu/libc.so.6"
        have=$(sha256sum "$DEST/usr/lib/aarch64-linux-gnu/libc.so.6" | cut -d' ' -f1)
        [ "$want" = "$have" ] || { echo "install-husk: libc restore failed" >&2; exit 72; }
    fi
    libc_sha=$want
    echo "   libc $(echo "$libc_sha" | cut -c1-12) matches the bundle"

if [ -n "$LOADER_DEST" ] && [ -f "$LOADER" ]; then
    echo "== session loader =="
    want_ld=$(sha256sum "$LOADER" | cut -d' ' -f1)
    have_ld=
    [ -f "$LOADER_DEST" ] && have_ld=$(sha256sum "$LOADER_DEST" | cut -d' ' -f1)
    if [ "$want_ld" = "$have_ld" ]; then
        echo "   $LOADER_DEST already $(echo "$want_ld" | cut -c1-12)"
    else
        if cp "$LOADER" "$LOADER_DEST" 2>/dev/null; then
            chmod 711 "$LOADER_DEST"
            have_ld=$(sha256sum "$LOADER_DEST" | cut -d' ' -f1)
            [ "$want_ld" = "$have_ld" ] || { echo "install-husk: loader sync failed" >&2; exit 76; }
            echo "   $LOADER_DEST -> $(echo "$want_ld" | cut -c1-12) (was ${have_ld:-absent})"
        else
            echo "install-husk: cannot replace $LOADER_DEST (running session?);" >&2
            echo "  a tree with the new libc and the old loader segfaults (exit 139)." >&2
            exit 76
        fi
    fi
fi
else
    echo "   (no bundled libc.so.6 next to the installer; keeping the tree's own)" >&2
fi
{
    echo "version=$HUSK_VERSION"
    echo "libc_sha256=${libc_sha:-unknown}"
    echo "loader_sha256=$(sha256sum "$LOADER" | cut -d' ' -f1)"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/.husk-install-state"

# 2c-bis. locale archive。由包直接拼出来的树（`nr-tools rootfs`，或任何不是
#     debootstrap 做出来的树）只有 /usr/share/i18n/*，没有
#     /usr/lib/locale/locale-archive —— 那个文件是包的 postinst 生成的，手工解包
#     永远不跑 postinst。缺了它 `LC_ALL=zh_CN.UTF-8 locale charmap` 是空的、每个
#     中文程序静默回落 C，表现就是"进系统全是英文"（2026-11-26 在干净树上实测：
#     同一棵树装完 66 个包，charmap 为空，生成 archive 后 charmap=UTF-8、
#     %A=星期一，2.3 秒）。必须在设备上生成：localedef 是 aarch64 程序，构建机
#     跑不了，所以这一步只能在安装时做。
echo "== locale =="
if [ -e "$DEST/usr/lib/locale/locale-archive" ]; then
    echo "   locale-archive already present"
elif [ -x "$DEST/usr/bin/localedef" ] && [ -f "$DEST/usr/share/i18n/locales/zh_CN" ]; then
    printf 'zh_CN.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\n' > "$DEST/etc/locale.gen"
    _rc=0
    set +e
    for _l in zh_CN.UTF-8 en_US.UTF-8; do
        guest_run usr/bin/localedef -i "${_l%%.*}" -f UTF-8 "$_l" > "$OUT/.husk-locale.log" 2>&1
        _rc=$?
        [ "$_rc" -eq 0 ] || break
    done
    set -e
    if [ "$_rc" -ne 0 ]; then
        echo "install-husk: localedef failed for ${_l:-?} (rc=$_rc) - do not ship this tree" >&2
        sed 's/^/    /' "$OUT/.husk-locale.log" | head -5 >&2
        exit 76
    fi
    rm -f "$OUT/.husk-locale.log"
    # localedef 建出来的 archive 是 0600：非 root 的 guest 用户读不到，等于没生成。
    [ -f "$DEST/usr/lib/locale/locale-archive" ] && chmod 644 "$DEST/usr/lib/locale/locale-archive"
    echo "   generated zh_CN.UTF-8 + en_US.UTF-8 ($(ls -l "$DEST/usr/lib/locale/locale-archive" 2>/dev/null | cut -d' ' -f5) bytes)"
    # 2b-2b' 那一步在生成之前判过一次，所以它只能记"没有 zh_CN.utf8，LANG 不动"。
    # 现在有了，就把默认值写上——中文优先是产品默认，不是可选项。
    mkdir -p "$DEST/etc/default"
    printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > "$DEST/etc/default/locale"
    echo "   wrote etc/default/locale (zh_CN.UTF-8)"
else
    echo "   (this tree has no locales data - locales package missing; no zh_CN.UTF-8)" >&2
fi

# 注意顺序：这一步必须排在 2d 之后。在 2d 之前跑会失败——树自带的（被 nr-tools
# 打过 slot 补丁的）libc 下 shim 的路径改写没有生效，localedef 里每个 /usr/... 都
# 落到宿主根上，报 `cannot create temporary file: /usr/lib/locale/locale-archive.*:
# No such file or directory`（2026-11-26 实测：同一棵树，2d 之前跑 rc=1，2d 之后
# 跑 rc=0 并生成 archive）。这就是这个块被放在这里的原因，别往前挪。
# 2e. guest 工具替换：App 路径里这一步由资产步骤做（docs/RUNNING.md §1 的 2/4/5），
#     独立安装（tarball + install-husk.sh）此前**完全没有做**，于是用它装出来的树里
#     useradd / groupadd / passwd / su / ldconfig 全是发行版原版：
#
#       * shadow 的 lckpwdf() 用 link(2) 判断数据库是否被占用，本 SELinux 域拒绝
#         link(2)，所以 groupadd 永远回 "lock file already used (nlink: 1)"、rc=10，
#         useradd 再回 "group '1500' does not exist"、rc=6，凡是 postinst 建号的包
#         全部装不上。实测 2026-11-26：gate A 的 user management 8 项全红，根因
#         就在这里（不是 husk-usermgr 的问题，是它根本没被装进来）。
#       * ldconfig 会用发行版自己的库重写 ld.so.cache，把 loader 的搜索路径写坏。
#
# 原文件一律保留成 <name>.shadow / ldconfig.ubuntu，永不删除：装坏了还能换回去。
echo "== guest tools (useradd/groupadd/passwd/su/ldconfig) =="
HSBIN="$DEST/usr/sbin"
mkdir -p "$HSBIN"
_tool_missing=
for t in husk-usermgr husk-su husk-ldconfig; do
    if [ -f "$HERE/$t" ]; then
        cp "$HERE/$t" "$HSBIN/$t" && chmod 755 "$HSBIN/$t"
        # Older installs left a second copy in usr/bin. PATH searches usr/sbin
        # first, but absolute /usr/bin/su and third-party scripts used the stale
        # binary. Keep both spellings byte-identical to this bundle.
        cp "$HERE/$t" "$DEST/usr/bin/$t" && chmod 755 "$DEST/usr/bin/$t"
    else
        echo "   WARNING: no $t next to the installer" >&2
        _tool_missing="$_tool_missing $t"
    fi
done
# Desktop supervision used to shell out to x11-utils/xdotool. Those are test
# packages, not part of a minimal distro tree, so a healthy GNOME session was
# reported as wm=no/ding=no and DING fallback silently did nothing. This helper
# only dlopens libX11/libXtst and is required by both session entries.
mkdir -p "$DEST/usr/bin"
# Audio is a standard Linux interface: the app owns the AAudio bridge, while
# these guest helpers provision PulseAudio and move PCM between its pipe
# modules and the app sockets. Keep them in the bundle instead of requiring a
# manual copy from a developer checkout.
for t in audio-setup audio-relay audio-capture audio-probe; do
    if [ -f "$HERE/$t" ]; then
        cp "$HERE/$t" "$DEST/usr/bin/$t" && chmod 755 "$DEST/usr/bin/$t"
    else
        echo "install-husk: $t is missing from the bundle; audio setup/playback may be unavailable" >&2
    fi
done
if [ -f "$HERE/husk-window-wait" ]; then
    cp "$HERE/husk-window-wait" "$DEST/usr/bin/husk-window-wait"
    chmod 755 "$DEST/usr/bin/husk-window-wait"
else
    echo "install-husk: husk-window-wait is missing from the bundle; desktop self-check would silently fail" >&2
    exit 79
fi
if [ -f "$HERE/husk-logd" ]; then
    mkdir -p "$DEST/usr/bin"
    cp "$HERE/husk-logd" "$DEST/usr/bin/husk-logd"
    chmod 755 "$DEST/usr/bin/husk-logd"
    echo "   installed usr/bin/husk-logd (guest /dev/log sink)"
else
    echo "install-husk: husk-logd missing; guest syslog and /dev/log will be absent" >&2
fi

if [ -x "$HSBIN/husk-usermgr" ]; then
    for c in useradd groupadd usermod userdel groupdel chpasswd passwd chfn chsh; do
        for d in usr/sbin usr/bin sbin bin; do
            p="$DEST/$d/$c"
            [ -e "$p" ] || continue
            [ -L "$p" ] && continue
            mv "$p" "$p.shadow" || { echo "install-husk: cannot move $d/$c" >&2; exit 76; }
            echo "   $d/$c -> husk-usermgr (distro binary kept as $c.shadow)"
        done
        ln -sf husk-usermgr "$HSBIN/$c" || { echo "install-husk: cannot link $c" >&2; exit 77; }
        # Keep the usr/bin spelling too. The distro binary used to live there and
        # both the host layer and third-party scripts call that exact path
        # (measured 2026-11-27: the app's sudo-access step ran chown/chmod on
        # /usr/bin/passwd, failed, and aborted the session start-up).
        if [ ! -e "$DEST/usr/bin/$c" ]; then
            ln -s ../sbin/husk-usermgr "$DEST/usr/bin/$c" 2>/dev/null || true
        fi
        # /usr/sbin 已经覆盖 PATH；/sbin 与 /usr/sbin 在 usrmerge 树里是同一个目录。
        [ -L "$DEST/sbin" ] || ln -sf husk-usermgr "$DEST/sbin/$c" 2>/dev/null || true
    done
    # su: 发行版走 PAM，本域里 PAM 会话建立不起来（husk-su 的注释里有原始错误）。
    for d in usr/bin bin; do
        p="$DEST/$d/su"
        [ -e "$p" ] && [ ! -L "$p" ] && { mv "$p" "$p.shadow"; echo "   $d/su -> husk-su (distro binary kept as su.shadow)"; }
    done
    ln -sf husk-su "$DEST/usr/bin/su" 2>/dev/null || true
fi
if [ -x "$HSBIN/husk-ldconfig" ]; then
    for d in usr/sbin sbin; do
        p="$DEST/$d/ldconfig"
        [ -e "$p" ] || continue
        [ -L "$p" ] && continue
        mv "$p" "$p.ubuntu" && echo "   $d/ldconfig -> husk-ldconfig (distro binary kept as ldconfig.ubuntu)"
    done
    ln -sf husk-ldconfig "$HSBIN/ldconfig"
fi

# DT_RUNPATH is resolved inside glibc's loader, where HusK cannot interpose the
# path. Record every absolute RUNPATH directory once at install time; the app and
# the session launcher turn each guest path into <rootfs><path> for
# --library-path. Without this Nautilus cannot load libunity-protocol-private.so.0
# even though the file is present under usr/lib/.../libunity.
if [ -x "$HSBIN/husk-ldconfig" ]; then
    _husk_ldpath="$DEST/etc/ld.so.husk-path"
    ( cd "$DEST" && NR_ROOTFS="$DEST" NR_LD="$LOADER" \
        "$LOADER" --library-path "$LIBS" usr/sbin/husk-ldconfig \
        --library-path-file /etc/ld.so.husk-path ) || {
        echo "install-husk: failed to generate /etc/ld.so.husk-path" >&2
        exit 75
    }
    [ -s "$_husk_ldpath" ] || {
        echo "install-husk: /etc/ld.so.husk-path is missing or empty" >&2
        exit 75
    }
    _bad_ldpath=$(while IFS= read -r _d; do
        [ -z "$_d" ] && continue
        [ "${_d#\#}" != "$_d" ] && continue
        [ -d "$DEST$_d" ] || printf '%s\n' "$_d"
    done < "$_husk_ldpath")
    [ -z "$_bad_ldpath" ] || {
        echo "install-husk: RUNPATH directories do not exist in the tree:" >&2
        printf '%s\n' "$_bad_ldpath" | head -10 | sed 's/^/    /' >&2
        exit 75
    }
    LIBS="$LIBS:$(sed -n 's|^|'"$DEST"'|p' "$_husk_ldpath" | tr '\n' ':')"
    echo "   wrote etc/ld.so.husk-path ($(grep -vc '^#' "$_husk_ldpath") RUNPATH directories)"
fi
# Image caches. A rootfs assembled by unpacking .deb files does not run their
# postinst scripts, so both files are absent even though the packages and all
# loader modules are installed. libgdk-pixbuf then sees only its two built-ins
# and GTK reports "Unrecognized image file format" for PNG/SVG icons and the
# wallpaper. Generate both caches here, where the guest tools and path shim are
# available; a desktop tree must not report a successful install without them.
echo "== image loader caches =="
_mime_dir="$DEST/usr/share/mime"
if [ -x "$DEST/usr/bin/update-mime-database" ] && [ -d "$_mime_dir/packages" ]; then
    _mimelog="$OUT/.husk-mime.log"
    set +e
    guest_run usr/bin/update-mime-database /usr/share/mime > "$_mimelog" 2>&1
    _rc_mime=$?
    set -e
    sed 's/^/   /' "$_mimelog"
    rm -f "$_mimelog"
    [ "$_rc_mime" -eq 0 ] && [ -s "$_mime_dir/mime.cache" ] || {
        echo "install-husk: update-mime-database failed (rc=$_rc_mime); image formats will be unrecognized" >&2
        exit 73
    }
    chmod 644 "$_mime_dir/mime.cache"
    echo "   wrote usr/share/mime/mime.cache ($(wc -c < "$_mime_dir/mime.cache" | tr -d ' ') bytes)"
else
    echo "   (no update-mime-database or MIME package data; image MIME cache skipped)"
fi

_gb_dir="$DEST/usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders"
_gb_query=
for _q in "$DEST/usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"           "$DEST/usr/bin/gdk-pixbuf-query-loaders"; do
    if [ -x "$_q" ]; then
        case "$_q" in
            "$DEST"/*) _gb_query=${_q#"$DEST"/} ;;
        esac
        break
    fi
done
if [ -n "$_gb_query" ] && [ -d "$_gb_dir" ]; then
    _gblog="$OUT/.husk-gdk-pixbuf.log"
    # gdk-pixbuf looks for the cache beside the loader directory, not inside
    # it: .../gdk-pixbuf-2.0/2.10.0/loaders.cache. Writing
    # .../2.10.0/loaders/loaders.cache makes the install look successful while
    # every PNG/SVG remains unregistered (caught by 20-tree-integrity.sh).
    _gb_cache="${_gb_dir%/loaders}/loaders.cache"
    set +e
    guest_run "$_gb_query" > "$_gb_cache" 2> "$_gblog"
    _rc_gb=$?
    set -e
    sed 's/^/   /' "$_gblog"
    rm -f "$_gblog"
    if [ "$_rc_gb" -ne 0 ] || [ ! -s "$_gb_cache" ]; then
        echo "install-husk: gdk-pixbuf-query-loaders failed (rc=$_rc_gb); PNG/SVG loaders are not registered" >&2
        exit 74
    fi
    _gb_n=$(grep -c '^"/usr/lib/.*/libpixbufloader-.*\.so"' "$_gb_cache" || true)
    if [ "${_gb_n:-0}" -lt 2 ]; then
        echo "install-husk: loaders.cache has only ${_gb_n:-0} guest loader path(s)" >&2
        exit 74
    fi
    if grep -qF "$DEST/" "$_gb_cache"; then
        echo "install-husk: loaders.cache contains a host rootfs prefix" >&2
        exit 74
    fi
    chmod 644 "$_gb_cache"
    echo "   wrote usr/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache ($_gb_n loaders)"
else
    echo "   (no gdk-pixbuf-query-loaders or loader modules; image loader cache skipped)"
fi
unset _mime_dir _mimelog _rc_mime _gb_dir _gb_query _q _gblog _gb_cache _rc_gb _gb_n

_unreplaced=$(ls "$DEST"/usr/sbin/{useradd,groupadd,chpasswd} 2>/dev/null | while read -r f; do [ -L "$f" ] || echo "$f"; done)
[ -z "$_unreplaced" ] || { echo "install-husk: these are still the distro tools:" >&2; echo "$_unreplaced" | sed 's/^/    /' >&2; exit 78; }
echo "   ok: useradd/groupadd/usermod/userdel/groupdel/chpasswd/passwd/chfn/chsh -> husk-usermgr"

# 3. session script + launcher, both in the parent of the rootfs. Absolute paths
#    are baked in: $0 inside the launcher is the launcher, not the rootfs.
if [ "$HERE/husk-session.sh" != "$OUT/husk-session.sh" ]; then
    cp "$HERE/husk-session.sh" "$OUT/husk-session.sh"
fi
chmod 755 "$OUT/husk-session.sh"
if [ -f "$HERE/husk-system-services.sh" ]; then
    if [ "$HERE/husk-system-services.sh" != "$OUT/husk-system-services.sh" ]; then
        cp "$HERE/husk-system-services.sh" "$OUT/husk-system-services.sh"
    fi
    chmod 755 "$OUT/husk-system-services.sh"
else
    echo "install-husk: husk-system-services.sh missing; polkitd/iio-sensor-proxy will not auto-start" >&2
fi
# The desktop and the LinuxHub .husk host both invoke this helper through the
# guest loader. Keep it inside the rootfs so the command name is stable.
if [ -f "$HERE/husk-media-session.sh" ]; then
    mkdir -p "$DEST/usr/local/bin"
    cp "$HERE/husk-media-session.sh" "$DEST/usr/local/bin/husk-media-session"
    chmod 755 "$DEST/usr/local/bin/husk-media-session"
else
    echo "install-husk: husk-media-session.sh missing; PipeWire/WirePlumber will not auto-start" >&2
fi
# husk-desktop.sh 是"起一个可用桌面会话"的单一入口（evidence 200）：清残留、清安全模式
# 标记、起双总线、起 shell、自检。放在 rootfs 旁边，和 husk-session.sh 同级。
if [ "$HERE/husk-desktop.sh" != "$OUT/husk-desktop.sh" ]; then
    cp "$HERE/husk-desktop.sh" "$OUT/husk-desktop.sh"
fi
chmod 755 "$OUT/husk-desktop.sh"
# husk-session.sh 从 $BASE（= rootfs 的父目录）里找这两个看护脚本。以前只把
# husk-wallpaper-fit.sh 装进 share/linuxhub、husk-ding-fallback.sh 则哪儿都没装，
# 于是 `[ -x $BASE/husk-ding-fallback.sh ]` 永远为假：桌面图标掉了没人补，
# 壁纸只能靠 husk-desktop.sh 那条 $ROOTFS 回退路径兜。两个都放到位。
for f in husk-ding-fallback.sh husk-wallpaper-fit.sh; do
    if [ -f "$HERE/$f" ]; then
        [ "$HERE/$f" = "$OUT/$f" ] || cp "$HERE/$f" "$OUT/$f"
        chmod 755 "$OUT/$f"
        echo "   wrote $f (next to husk-session.sh)"
    else
        echo "   WARNING: no $f next to the installer; the session cannot fall back" >&2
    fi
done
cat > "$OUT/husk" <<LAUNCHER
#!/bin/sh
# generated by install-husk.sh on $(date +%Y-%m-%d)
# rootfs: $DEST
# loader: $LOADER
#
#   ./husk                     - interactive shell
#   ./husk run ubuntu          - the same thing; one rootfs per install, so the
#                                name is accepted and documented, not looked up
#   ./husk run ubuntu -c 'id'  - run one command inside the guest
#   ./husk --version           - print the release this tree came from
HUSK_VERSION=$HUSK_VERSION
case "\${1:-}" in
    -V|--version) echo "husk \$HUSK_VERSION"; exit 0 ;;
    run) shift; [ \$# -gt 0 ] && shift ;;   # drop "run" and the distro name
esac
[ \$# -gt 0 ] || set -- usr/bin/bash -l
# "-c 'cmd'" (and any other leading option) is meant for the shell, not for
# husk-session.sh: that would try to exec a program called "-c".
case "\${1:-}" in -*) set -- usr/bin/bash "\$@" ;; esac
# husk-session.sh finds the loader through NR_LD; the rootfs is passed explicitly.
NR_LD="$LOADER" exec "$OUT/husk-session.sh" "$DEST" --user $USER_NAME -- "\$@"
LAUNCHER
chmod 755 "$OUT/husk"

# 4. verification that does not lie: run the guest's own tools.
echo "== verify =="
out=$( cd "$DEST" && NR_ROOTFS=$DEST NR_LD=$LOADER "$LOADER" --library-path "$LIBS" usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NR_ROOTFS=$DEST NR_LD=$LOADER /bin/sh -c \
    'head -1 /etc/os-release; echo "bins=$(ls /usr/bin | wc -l)"; ls -l /usr/bin/uncompress /usr/bin/perl5.38.2 2>/dev/null | sed "s/  */ /g"' 2>&1 || true )
echo "$out" | sed 's/^/   /'
case "$out" in
    *"PRETTY_NAME=\"Ubuntu"*) ;;
    *) echo "install-husk: verification failed - the guest did not answer from its own rootfs" >&2; exit 70 ;;
esac
# The hard links pass 2 exists for must now be real, readable files. Test them
# positively: a previous version grepped the combined transcript and matched the
# "cannot access" error text, i.e. it passed exactly when the file was missing.
#
# 每个名字单独判，并且只在它"本该存在"时才判：早先两条 && 串在一起，任何一棵
# 没装 perl 的树都会报 "hard links missing; pass 2 did not go through the shim"，
# 而真实情况是 uncompress 好好地在（2026-11-26 在 66 包的干净树上实测：文件
# 2346 字节、pass 2 成功，报告却是失败）。perl 只在装了 perl 的树上才检查。
hl=$( cd "$DEST" && NR_ROOTFS=$DEST NR_LD=$LOADER "$LOADER" --library-path "$LIBS" usr/bin/env -i \
    PATH=/usr/bin:/bin NR_ROOTFS=$DEST NR_LD=$LOADER /bin/sh -c \
    'miss=
     for f in /usr/bin/uncompress; do [ -s "$f" ] || miss="$miss $f"; done
     if [ -e /usr/bin/perl ]; then [ -s /usr/bin/perl5.38.2 ] || miss="$miss /usr/bin/perl5.38.2"; fi
     echo "missing:${miss:-none}"' 2>&1 | tail -1 )
case "$hl" in
    *missing:none*) echo "== ok: hard links materialised (uncompress$([ -e "$DEST/usr/bin/perl" ] && echo ' + perl5.38.2') are real files) ==" ;;
    *)   echo "install-husk: warning -$hl; pass 2 did not go through the shim" >&2 ;;
esac

# 4b. the check that would have caught both symlink bugs: a soname that only
#     resolves when the /etc/alternatives chain is relative. BLAS is optional:
#     a desktop image with python3 but without libblas3/liblapack3 is valid, so
#     only test sonames that the tree actually contains.
if [ -x "$DEST/usr/bin/python3" ]; then
    sonames=
    for n in libblas.so.3 liblapack.so.3; do
        if find "$DEST/lib" "$DEST/usr/lib" -name "$n" -print -quit 2>/dev/null | grep -q .; then
            sonames="$sonames $n"
        fi
    done
    if [ -n "$sonames" ]; then
        son=$( guest_run /usr/bin/python3 -c \
            "import ctypes,sys; [ctypes.CDLL(n) for n in sys.argv[1:]]; print('sonames ok')" $sonames \
            2>&1 | tail -2 )
        echo "$son" | sed 's/^/   /'
        case "$son" in
            *"sonames ok"*) ;;
            *) echo "install-husk: soname resolution failed ($sonames) - do not ship this tree" >&2
               exit 73 ;;
        esac
    else
        echo "   skipped BLAS/LAPACK soname check (not installed in this tree)"
    fi
fi

# 5. runtime identity. Every deployment records what is actually on disk so a
#    test result is tied to this exact tree instead of "whatever the app had last
#    week". tools/device-tests/23-runtime-identity.sh re-derives the same six
#    hashes and fails when any of them moved.
_id_sha() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo missing; fi; }
_id_git=unknown
if [ -f "$HERE/RUNTIME-IDENTITY" ]; then
    _v=$(sed -n 's/^commit=//p' "$HERE/RUNTIME-IDENTITY" | head -1)
    [ -n "$_v" ] && _id_git=$_v
fi
_id_driver="$DEST/usr/lib/aarch64-linux-gnu/libvulkan_panfrost_husk.so"
_id_icd="$DEST/usr/share/vulkan/icd.d/husk_panvk_guest.json"
_id_gpuenv="$DEST/etc/husk/gpu-env"
_id_pipewire="$DEST/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstpipewire.so"
mkdir -p "$DEST/etc/husk"
{
    echo "version=$HUSK_VERSION"
    echo "git_commit=$_id_git"
    echo "mode=$([ "$UPGRADE" = yes ] && echo upgrade || echo install)"
    echo "loader_sha256=$(sha256sum "$LOADER" | cut -d' ' -f1)"
    echo "libc_sha256=${libc_sha:-unknown}"
    echo "gpu_env_sha256=$(_id_sha "$_id_gpuenv")"
    echo "panvk_driver_sha256=$(_id_sha "$_id_driver")"
    echo "icd_sha256=$(_id_sha "$_id_icd")"
    echo "pipewire_plugin_sha256=$(_id_sha "$_id_pipewire")"
    echo "ran_at_epoch=$(date -u +%s)"
} > "$DEST/etc/husk/runtime-identity"
cp "$DEST/etc/husk/runtime-identity" "$OUT/.husk-install-state" 2>/dev/null || true
echo "== runtime identity =="
sed 's/^/   /' "$DEST/etc/husk/runtime-identity"

cat <<DONE

== done ==
  $OUT/husk -- usr/bin/bash -l -c 'id; head -1 /etc/os-release'
DONE
