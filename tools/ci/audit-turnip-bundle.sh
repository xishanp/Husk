#!/bin/sh
# Release gate for the vendored Qualcomm (Adreno/KGSL) Turnip snapshot.
#
# The Adreno chain fails in two ways that a green build cannot see:
#   1. the driver was built without `-Dfreedreno-kmds=kgsl`, so TU_HAS_KGSL is
#      undefined, tu_enumerate_devices() returns VK_ERROR_INCOMPATIBLE_DRIVER and
#      vkEnumeratePhysicalDevices reports 0 devices -> zink picks no pdev and
#      gnome-shell exits 139;
#   2. the driver was built without `-Dplatforms=x11`, so wsi_common_x11.c is not
#      compiled and surface creation jumps through a NULL pointer (pc=0 SIGSEGV).
# Both defects shipped once. Assert the bytes and the two link signatures.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
V="$ROOT/vendor/turnip/d211037c-adreno-825"
DRIVER_GZ="$V/libvulkan_freedreno_husk.so.gz"
ICD="$V/husk_turnip_guest.json"
INSTALL="$ROOT/tools/guest/install-husk.sh"
PROV="$V/PROVENANCE.md"
# Source-built 2026-11-28 from mesa-d211037c (Mesa 27.0.0-devel) on the
# OPPO PLE110 / Adreno 825 target. See PROVENANCE.md for the meson line.
WANT_SO=35577a1a08ddbad0fada23e2aae3a1ad7b6a0c6b1c45e470b7eb9dab89ad75f5
TMP=${TMPDIR:-/tmp}/husk-turnip-audit.$$
trap 'rm -f "$TMP"' EXIT HUP INT TERM

fail() { echo "turnip bundle: FAIL: $*" >&2; exit 1; }

[ -f "$DRIVER_GZ" ] || fail "missing $DRIVER_GZ"
[ -f "$ICD" ] || fail "missing $ICD"
[ -f "$V/LICENSE-Mesa.txt" ] || fail "missing Mesa license"
[ -f "$PROV" ] || fail "missing provenance"
[ -f "$INSTALL" ] || fail "missing installer"

gzip -dc "$DRIVER_GZ" > "$TMP" || fail "driver gzip is corrupt"
have=$(sha256sum "$TMP" | cut -d' ' -f1)
[ "$have" = "$WANT_SO" ] || fail "decompressed driver sha256 $have != $WANT_SO"

# TU_HAS_KGSL: the string is only reachable through the KGSL enumeration path.
# Without it the driver cannot see /dev/kgsl-3d0 at all.
grep -qa '/dev/kgsl-3d0' "$TMP" \
    || fail "driver has no /dev/kgsl-3d0 reference: built without -Dfreedreno-kmds=kgsl (TU_HAS_KGSL)"
# x11 WSI: only linked when -Dplatforms=x11 compiles wsi_common_x11.c.
grep -qa 'libxcb-dri3\.so\.0' "$TMP" \
    || fail "driver does not link libxcb-dri3: built without -Dplatforms=x11 (no X11 WSI)"

grep -q '"library_path"[[:space:]]*:[[:space:]]*"/usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so"' "$ICD" \
    || fail "ICD library_path is not the guest-relative Turnip driver path"

# The installer must reference the bundle, the driver path and the canonical ICD,
# otherwise a release tar installs silently without any Adreno driver.
grep -q 'vendor/turnip/d211037c-adreno-825' "$INSTALL" \
    || fail "install-husk.sh does not reference the Turnip bundle"
grep -q 'usr/lib/aarch64-linux-gnu/libvulkan_freedreno_husk.so' "$INSTALL" \
    || fail "install-husk.sh does not install the Turnip driver"
grep -q 'icd.d/husk_turnip_guest.json' "$INSTALL" \
    || fail "install-husk.sh does not install the canonical Turnip ICD"
grep -q "$WANT_SO" "$INSTALL" \
    || fail "install-husk.sh does not pin the Turnip driver sha256"

# Provenance must record the two build switches that caused the 139 defects.
grep -q 'freedreno-kmds=kgsl' "$PROV" || fail "provenance does not record -Dfreedreno-kmds=kgsl"
grep -q 'platforms=x11' "$PROV" || fail "provenance does not record -Dplatforms=x11"

echo "turnip bundle: OK ($WANT_SO)"
