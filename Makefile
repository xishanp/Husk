# One entry point per thing a contributor or a release needs.
#
#   make check   type-check the runtime for the target it actually runs on
#   make lint    formatting gate (what CI runs)
#   make test    unit tests; needs an arm64 Linux host (the shim is inline asm)
#   make loader  rebuild the embedded loader into the APK's jniLibs
#   make apk     loader + ArkTS-free Rust app .so + Gradle assembleDebug
#   make bench   three-runner benchmark (needs a device)
#   make gate-a  the 38-item acceptance gate + path/V4L2/DRM probes (needs a device)
#   make server-parity  90-item Linux surface matrix; Rust libc checks (needs a device)
#   make readback-audit  complete 19-case Rust GPU readback suite (needs a device)
#   make gpu-audit  desktop shell + nested GTK app hardware-GPU inheritance (needs a device)
#   make gpu-soak  4 concurrent Rust GPU soaks, 300 s each (needs a device)
#   make camera-audit  V4L2 mmap + GStreamer v4l2src through the fixture (needs a device)
#   make docs    markdown link check
#   make dist    release artifacts + SHA256SUMS

SHELL       := /bin/sh
TARGET      := aarch64-unknown-linux-gnu
MANIFEST    := runtime/Cargo.toml
PROFILE_DIR := runtime/target/$(TARGET)/release
HUSK_TOOLS  := runtime/target/debug/husk-tools
NDK_BIN     := $(if $(filter %/bin,$(NDK)),$(NDK),$(NDK)/bin)
GUEST_SYSROOT ?= /tmp/nr-toolchain/root

.PHONY: all check lint test test-device tools nr-tools loader preloads apk bench gate-a readback-audit gpu-audit gpu-soak camera-audit audio-audit server-parity virt-race docs dist clean version-check version-bump release-audit \
        libc-patch libc-verify

all: lint check version-check

# What README promises `make check` does: formatting, type check for the target
# the runtime actually runs on, lints, shell syntax, doc links and the version
# triple. Before, `check` only ran the cargo check and the other gates lived in
# separate targets, so "make check passed" said less than it looked like.
check:
	cargo fmt --all --check --manifest-path $(MANIFEST)
# --workspace, not a hand-written -p list. The list used to name 12 of the 39
# crates; a type error in audio-relay / video-bridge / husk-record / any probe
# stayed invisible to `make check` and CI while `cargo check --workspace` saw it.
# Measured 2026-11-26 (evidence 293): injected E0308 in audio-relay -> the 12-crate
# list exited 0, --workspace failed. Same rule as .github/workflows/ci.yml.
	CC_aarch64_unknown_linux_gnu=$(NDK_BIN)/clang \
	CFLAGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu --sysroot=$(GUEST_SYSROOT)" \
	AR_aarch64_unknown_linux_gnu=$(NDK_BIN)/llvm-ar \
	  cargo check --manifest-path $(MANIFEST) --target $(TARGET) --workspace
	cargo test --manifest-path $(MANIFEST) -p gpu-env -p session-env -p usermgr -p nr-tools -p location-probe -p audio-capture-probe -p runtime-probe -p husk-tools
# No --all-targets: path-shim is no_std and its test harness collides with the
# crate's own panic handler (duplicate lang item). Warnings there are tracked
# separately; this gate fails on errors.
	CC_aarch64_unknown_linux_gnu=$(NDK_BIN)/clang \
	CFLAGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu --sysroot=$(GUEST_SYSROOT)" \
	AR_aarch64_unknown_linux_gnu=$(NDK_BIN)/llvm-ar \
	  cargo clippy --manifest-path $(MANIFEST) --target $(TARGET) --workspace
	cargo check --manifest-path app-rs/Cargo.toml --target aarch64-linux-android --lib --bin husk-session-guard
	sh tools/ci/test-locale-defaults.sh
	sh tools/ci/test-guest-rootfs-selection.sh
	sh tools/ci/check-fork-safety.sh
	sh tools/ci/check-shell.sh
	sh tools/ci/audit-readme-header.sh
	sh tools/ci/audit-release-offline.sh
	sh tools/ci/audit-runtime-package.sh
	sh tools/ci/audit-git-refs.sh
	sh tools/ci/test-version-bump.sh
	sh tools/ci/test-release-notes.sh
	sh tools/ci/test-session-gpu-escape.sh
	sh tools/ci/test-session-rootfs-bundle.sh
	sh tools/ci/audit-panvk-bundle.sh
	sh tools/ci/audit-turnip-bundle.sh
	sh tools/ci/test-runtime-boundary.sh
	sh tools/ci/test-runtime-private-paths.sh
	sh tools/ci/test-pipewire-plugin-audit.sh
# Two builds of the same inputs must be byte-identical (defect H37: one 869888 B
# build published /proc/self/exe, another 738816 B build silently did not, and
# only 3 of 38 acceptance checks noticed). Guard against non-determinism here,
# not on a device.
	sh tools/ci/check-loader-repro.sh
	@$(MAKE) --no-print-directory tools
	$(HUSK_TOOLS) check-links
	@$(MAKE) --no-print-directory version-check

lint:
	cargo fmt --all --check --manifest-path $(MANIFEST)

# Repository tooling is Rust too (it used to be three Python scripts): build it
# for the host and call it. Never built for $(TARGET) -- it runs on the dev box.
tools:
	cargo build --manifest-path $(MANIFEST) -p husk-tools

nr-tools:
	cargo build --manifest-path $(MANIFEST) -p nr-tools

# The guest libc is not stock (slot page + clone3 -> ENOSYS, LIMITATIONS 4), and
# `apt upgrade` of libc6 puts the distro's copy back. This re-applies both
# transforms to whatever libc the tree has now, with the assertions the old
# shell script could not make (nr-tools libc-patch; evidence 170).
DEV        ?= UKHMMB8PYTGECMNV
PKG        ?= com.linuxhub.myth.husk
DEV_ROOTFS ?= files/linux/distributions/ubuntu-24.04/rootfs
DEV_LIBC   := $(DEV_ROOTFS)/usr/lib/aarch64-linux-gnu/libc.so.6
# `husk-session` refuses to start a tree whose guest libc is not the one the
# install recorded, and restores it from the copy that sits next to the rootfs.
# Both therefore have to move together with the patch, or the repair the error
# message recommends ("re-run make libc-patch") leaves a tree that then refuses
# to start. The release input is glibc 2.39-0ubuntu8.12; its patched output is
# 16d5ba21... after the current 104/109-hook transform (evidence 322).
BUNDLED_LIBC := $(patsubst %/rootfs,%,$(DEV_ROOTFS))/libc.so.6
INSTALL_STATE := $(patsubst %/rootfs,%,$(DEV_ROOTFS))/.husk-install-state
LIBCTMP    := runtime/target/libc-patch

# Where the pristine libc comes from. The installer ships a libc that is
# *already* patched, so the tree's own copy cannot be re-patched ("no clone3 site
# left"). Pass STOCK=<a stock glibc 2.39 libc.so.6>, or keep a .stock copy next
# to the live one on the device.
STOCK      ?=

libc-patch: nr-tools
	@mkdir -p $(LIBCTMP)
	@if [ -n "$(STOCK)" ]; then \
	    cp "$(STOCK)" $(LIBCTMP)/libc.so.6.stock; \
	    echo "stock libc from $(STOCK)"; \
	elif adb -s $(DEV) shell "run-as $(PKG) sh -c 'test -f $(DEV_LIBC).stock'" >/dev/null 2>&1; then \
	    adb -s $(DEV) shell "run-as $(PKG) sh -c 'cat $(DEV_LIBC).stock'" > $(LIBCTMP)/libc.so.6.stock; \
	    echo "stock libc from $(DEV_LIBC).stock"; \
	else \
	    adb -s $(DEV) shell "run-as $(PKG) sh -c 'cat $(DEV_LIBC)'" > $(LIBCTMP)/libc.so.6.stock; \
	    echo "stock libc from the live tree (fails if it is already patched; pass STOCK=)"; \
	fi
	runtime/target/debug/nr-tools libc-patch $(LIBCTMP)/libc.so.6.stock $(LIBCTMP)/libc.so.6 \
	    --table tools/loader/libc-interpose.txt
	adb -s $(DEV) shell "run-as $(PKG) sh -c 'cat > $(DEV_LIBC).husk'" < $(LIBCTMP)/libc.so.6
	@# Do not park a copy of the *patched* libc as .stock: the pull above would
	@# then treat it as pristine and the transform would fail with "no clone3 site
	@# left" on a tree that was fine.
	adb -s $(DEV) shell "run-as $(PKG) sh -c 'mv $(DEV_LIBC).husk $(DEV_LIBC); chmod 755 $(DEV_LIBC); sha256sum $(DEV_LIBC)'"
	cp $(LIBCTMP)/libc.so.6 tools/loader/libc-nop.so.6
	@echo "tools/loader/libc-nop.so.6 refreshed from this run (generated artifact; consumed by make dist)"
	@# Keep the bundle and the recorded hash in step with the tree (see the note
	@# above BUNDLED_LIBC): the launcher compares the two, and a tree whose libc
	@# no longer matches its own record is refused at startup.
	adb -s $(DEV) shell "run-as $(PKG) sh -c 'cat > $(BUNDLED_LIBC)'" < $(LIBCTMP)/libc.so.6
	adb -s $(DEV) shell "run-as $(PKG) sh -c 'chmod 755 $(BUNDLED_LIBC)'"
	@sha=$$(cd $(LIBCTMP) && sha256sum libc.so.6 | cut -d' ' -f1); \
	 echo "recording libc_sha256=$$sha in $(INSTALL_STATE)"; \
	 adb -s $(DEV) shell "run-as $(PKG) sh -c 'S=$(INSTALL_STATE); \
	     [ -f \$$S ] || exit 0; \
	     sed -i s/^libc_sha256=.*/libc_sha256=$$sha/ \$$S'" 

# What the release artifact has to satisfy, checked without a device. Pass
# STOCK=<a stock glibc 2.39 libc.so.6> to also prove the whole transform is
# byte-stable against tools/loader/libc-nop.so.6.
libc-verify: nr-tools
	@mkdir -p $(LIBCTMP)
	runtime/target/debug/nr-tools libc-patch tools/loader/libc-nop.so.6 x \
	    --table tools/loader/libc-interpose.txt --assert-only
	@if [ -n "$$STOCK" ]; then \
	    runtime/target/debug/nr-tools libc-patch "$$STOCK" $(LIBCTMP)/verify.so.6 \
	        --table tools/loader/libc-interpose.txt && \
	    cmp $(LIBCTMP)/verify.so.6 tools/loader/libc-nop.so.6 && \
	    echo "byte-identical to tools/loader/libc-nop.so.6"; \
	else \
	    echo "(set STOCK=<stock glibc 2.39 libc.so.6> to also check byte identity)"; \
	fi

# The unit tests are aarch64 Linux binaries: the dev box can only *build* them.
# Before, the link fell through to the host cc and died on GNU-only flags
# (--fix-cortex-a53-843419 ...) on macOS, so "make test" never ran anywhere:
# every "tests green" claim rested on `make check`, which only type-checks.
TEST_LINK = -C linker=$(NDK_BIN)/clang -C link-arg=--target=aarch64-linux-gnu \
            -C link-arg=--sysroot=$(GUEST_SYSROOT)
TEST_PKGS = -p runtime-core -p nr-tools -p gpu-env -p v4l2-shim

test:
	@test -n "$NDK" || { echo "set NDK=<ndk>/bin" >&2; exit 1; }
	RUSTFLAGS="$(TEST_LINK)" cargo test --manifest-path $(MANIFEST) --target $(TARGET) \
		$(TEST_PKGS) --no-run

# Run those binaries where they actually belong: on aarch64 Linux, i.e. inside
# the device tree. A green build is not a green test.
test-device: test
# `$$` 是必须的：写成 `$DEV` 时 make 会把 `$D` 展开成空、留下字面量 "EV"，
# 于是目标永远报 `adb: device 'EV' not found`（2026-11-27 实测，defect H46）。
	@test -n "$$DEV" || { echo "set DEV=<adb serial>" >&2; exit 1; }
	DEV="$$DEV" PKG="$${PKG:-com.linuxhub.myth.husk}" \
		ROOTFS="$${ROOTFS:-files/rootfs-full}" \
		LD="$${LD:-files/linux/husk/libld.so}" sh tools/device-tests/run-unit-tests.sh

loader:
	@test -n "$$NDK" || { echo "set NDK=<ndk>/bin (needs clang + llvm-objcopy)" >&2; exit 1; }
	sh tools/loader/build-embedded-loader.sh

# --- LD_PRELOAD layers -----------------------------------------------------
# Two separate .so, not part of the loader: they cover libraries that dlopen
# *after* start (Mesa's libgbm/libdrm, GStreamer's libgstvideo4linux2), whose
# calls never pass the loader's GOT patch.
#
# v4l2-preload refers to its libc symbols with GLIBC versions
# (open64@GLIBC_2.17 ...). An unversioned definition does not satisfy those
# references, so the map in crates/v4l2-preload/exports.map has to be on the
# link line. That map was committed long ago and referenced by nothing: a plain
# `cargo build --release -p v4l2-preload` failed with
#   symbol open64@GLIBC_2.17 has undefined version
# while `cargo check` (which never links) stayed green. Hence this target.
# `cd runtime` matters: runtime/.cargo/config.toml is what points the
# aarch64-unknown-linux-gnu link at rust-lld. Running cargo from the repo root
# picks up no config and tries the host `cc`, which cannot link these objects.
PRELOAD_RUSTFLAGS = -C link-arg=-z -C link-arg=max-page-size=0x10000 \
                    -C link-arg=-z -C link-arg=separate-loadable-segments \
                    --remap-path-prefix=$$HOME=/build/home \
                    --remap-path-prefix=$(GUEST_SYSROOT)=/build/sysroot
V4L2_MAP = $(CURDIR)/runtime/crates/v4l2-preload/exports.map
NM ?= $(NDK_BIN)/llvm-nm

preloads:
	cd runtime && RUSTFLAGS="$(PRELOAD_RUSTFLAGS)" CARGO_PROFILE_RELEASE_STRIP=symbols \
	  cargo build --release --target $(TARGET) -p drm-preload
	cd runtime && RUSTFLAGS="$(PRELOAD_RUSTFLAGS) -C link-arg=--version-script=$(V4L2_MAP) -C link-arg=-soname=libhusk_v4l2.so" \
	  CARGO_PROFILE_RELEASE_STRIP=symbols \
	  cargo build --release --target $(TARGET) -p v4l2-preload
	@sh tools/ci/audit-preload-exports.sh "$(NM)"

# The APK is two native pieces and one Gradle skeleton: the embedded loader
# (jniLibs/libld.so) and the App's own .so (jniLibs/libhuskapp.so). Both are
# build outputs and neither is tracked, so a clean clone builds them here.
JNI := app/app/src/main/jniLibs/arm64-v8a
CC_ANDROID := $(NDK_BIN)/aarch64-linux-android24-clang

apk:
	@test -n "$$NDK" || { echo "set NDK=<ndk>/bin (needs clang, llvm-objcopy, llvm-ar)" >&2; exit 1; }
	@$(MAKE) --no-print-directory loader
	mkdir -p $(JNI)
	# Xlorie-era builds left this file behind in the ignored jniLibs directory;
	# AGP would package any stale .so even after the source dependency is gone.
	rm -f $(JNI)/libXlorie.so
	CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$(CC_ANDROID) \
	CC_aarch64_linux_android=$(CC_ANDROID) AR_aarch64_linux_android=$(NDK_BIN)/llvm-ar \
	  cargo build --release --manifest-path app-rs/Cargo.toml --target aarch64-linux-android \
	    --lib --bin husk-session-guard
	cp app-rs/target/aarch64-linux-android/release/libhuskapp.so $(JNI)/
	# Android only extracts/executes native libraries below jniLibs. Keep the
	# guard's .so suffix so the package manager extracts it, even though it is a
	# PIE executable rather than a shared library.
	cp app-rs/target/aarch64-linux-android/release/husk-session-guard $(JNI)/libhuskguard.so
	chmod 755 $(JNI)/libhuskguard.so
	cd app && ./gradlew :app:assembleDebug
	@ls -l $(JNI) app/app/build/outputs/apk/debug/*.apk

# 第 8 轮的发行树验收：从 tar 装一棵树，然后体检 + 门禁 A + 读回套一次跑完。
#   make release-tree-check DEV=<serial> TAR=/tmp/husk-desktop.tar.gz
#   (BUNDLE=files/linux-clean 是设备上那份带 install-husk.sh / libld.so 的 bundle)
#
# 为什么要有这一条：出厂桌面树曾经同时踩到两个"不报错、只是不能用"的坑——862 个包
# 只有 92 个 .list，以及树里没有 locale-archive（界面全英文，evidence 298）。单跑
# 门禁 A 看不出来，单跑体检又不测运行时，所以发版前必须两条一起跑。
release-tree-check:
	@test -n "$$DEV" || { echo "set DEV=<serial>" >&2; exit 1; }
	@test -n "$$TAR" || { echo "set TAR=<rootfs.tar.gz>" >&2; exit 1; }
	BUNDLE=$${BUNDLE:-files/linux-clean}; DEST=$${DEST:-files/release-tree/root}; \
	adb -s "$$DEV" push "$$TAR" /data/local/tmp/husk-release-tree.tar.gz >/dev/null && \
	adb -s "$$DEV" shell "run-as $${PKG:-com.linuxhub.myth.husk} sh -c 'cat /data/local/tmp/husk-release-tree.tar.gz > files/release-tree.tar.gz'" && \
	adb -s "$$DEV" shell "run-as $${PKG:-com.linuxhub.myth.husk} sh -c 'cd $$BUNDLE && TMPDIR=/data/data/$${PKG:-com.linuxhub.myth.husk}/files/tmp sh install-husk.sh --rootfs ../release-tree.tar.gz --dest ../release-tree/root --loader ./libld.so'"
	DEV=$$DEV PKG=$${PKG:-com.linuxhub.myth.husk} ROOTFS=$${DEST:-files/release-tree/root} EXPECT=$${EXPECT:-base} \
		sh tools/device-tests/20-tree-integrity.sh
	DEV=$$DEV PKG=$${PKG:-com.linuxhub.myth.husk} ROOTFS=$${DEST:-files/release-tree/root} \
		LD=$${BUNDLE:-files/linux-clean}/libld.so EXPECT_PKGS_MIN=$${EXPECT_PKGS_MIN:-700} \
		sh tools/device-tests/14-gate-a-acceptance.sh

bench:
	sh tools/bench/install.sh
	sh tools/bench/run-interleaved.sh $${REPS:-5}
	@$(MAKE) --no-print-directory tools
	$(HUSK_TOOLS) bench-compare docs/design/evidence/bench-*-il.log

# 门禁 A = 38 项验收 + 覆盖度探针 + 补充组/session locale/身份初始化/组表竞态/session guard/rootfd/最终 symlink 真机回归。
# 探针单列一步，因为 locale 看 env -i 后的真实值，竞态看宿主哨兵是否被改动。
readback-audit:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		GL_PROBE=$${GL_PROBE:-$(PROFILE_DIR)/gl-probe} \
		EXPECT_RENDERER=$${EXPECT_RENDERER-zink} \
		sh tools/device-tests/19-readback-suite.sh

gpu-audit:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		GL_PROBE=$${GL_PROBE:-$(PROFILE_DIR)/gl-probe} \
		sh tools/device-tests/19-readback-suite.sh
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		ENV=DISPLAY=:0,XDG_RUNTIME_DIR=/tmp/runtime-husk \
		sh tools/device-tests/run-guest.sh 15-gpu-global-audit.sh

gpu-soak:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		GL_PROBE=$${GL_PROBE:-$(PROFILE_DIR)/gl-probe} \
		SOAK_SECONDS=$${SOAK_SECONDS:-300} JOBS=$${JOBS:-4} SIZE=$${SIZE:-2400x1080} \
		sh tools/device-tests/21-gpu-soak-audit.sh

server-parity:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		RUNTIME_PROBE=$${RUNTIME_PROBE:-$(PROFILE_DIR)/runtime-probe} \
		sh tools/device-tests/run-server-parity.sh

gate-a:
	DEV=$${DEV:?} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/14-gate-a-acceptance.sh
	sh tools/probe/run-coverage-probe.sh "$${DEV}" "$${ROOTFS:-}" "$${LD:-}"
	ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/probe/coverage-sweep.sh "$${DEV}"
	sh tools/device-tests/run-dpkg-conffile-mode-probe.sh "$${DEV}"
	sh tools/device-tests/run-v4l2-ref-probe.sh "$${DEV}"
	sh tools/device-tests/run-drm-fd-probe.sh "$${DEV}"
	sh tools/device-tests/run-fd-identity-probe.sh "$${DEV}"
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-supplementary-groups-probe.sh
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-session-locale-probe.sh
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-identity-init-race-probe.sh
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-groups-race-probe.sh
	DEV=$${DEV} sh tools/device-tests/run-session-guard-probe.sh
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-rootfd-close-range-probe.sh
	DEV=$${DEV} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-path-race-probe.sh

camera-audit:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-/data/user/0/$${PKG:-com.linuxhub.myth.husk}/files/rootfs-full} \
		LD=$${LD:-/data/user/0/$${PKG:-com.linuxhub.myth.husk}/files/linux/husk/libld.so} \
		sh tools/device-tests/run-camera-fixture.sh "$${DEV}"

audio-audit:
	DEV=$${DEV:?set DEV=<adb serial>} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} \
		LD=$${LD:-files/linux/husk/libld.so} \
		PROFILE_DIR=$${PROFILE_DIR:-$(PROFILE_DIR)} \
		sh tools/device-tests/22-audio-audit.sh

rootfd-race:
	DEV=$${DEV:?} PKG=$${PKG:-com.linuxhub.myth.husk} \
		ROOTFS=$${ROOTFS:-files/rootfs-full} LD=$${LD:-files/linux/husk/libld.so} \
		sh tools/device-tests/run-rootfd-close-range-probe.sh

virt-race:
	@test -n "$${DEV:-}" || { echo "set DEV=<serial> and the device paths" >&2; exit 1; }
	sh tools/device-tests/run-virt-concurrency-probe.sh \
		"$${DEV}" "$${PKG:-com.linuxhub.myth.husk}" \
		"$${ROOTFS:?set ROOTFS}" "$${LD:?set LD}" "$${ROUNDS:-4000}"

docs: tools
	$(HUSK_TOOLS) check-links

# One version string, three places: VERSION (what `./husk --version` prints),
# the newest CHANGELOG heading, and the release-tag link that heading points at.
version-check:
	@v=$$(cat VERSION); \
	printf '%s\n' "$$v" | awk -F. 'NF != 3 || $$1 !~ /^[0-9]+$$/ || $$2 !~ /^[0-9]+$$/ || $$3 !~ /^[0-9]+$$/ || $$1 > 99 || $$2 > 99 || $$3 > 99 { exit 1 }' || { \
	    echo "invalid version (expected X.Y.Z with components 0..99): $$v" >&2; exit 1; \
	}; \
	c=$$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | grep -v -e '^Unreleased$$' -e '^未发布$$' | head -1); \
	if [ "$$v" != "$$c" ]; then \
	    echo "version mismatch: VERSION=$$v CHANGELOG=$$c" >&2; exit 1; \
	fi; \
	grep -q "releases/tag/v$$v" CHANGELOG.md || { \
	    echo "CHANGELOG has no releases/tag/v$$v link" >&2; exit 1; }; \
	echo "version ok: $$v"
version-bump:
	@sh tools/ci/version-bump.sh

# Network-backed: requires an authenticated gh CLI. Checks the README hero,
# contiguous base-100 tags, tag annotations, Release titles, and the canonical
# `## 概要` body contract on every published release.
release-audit:
	@sh tools/ci/audit-release-names.sh

# Two artifacts: the launcher bundle (loader + installer + session script) and,
# built on a device from a verified tree, the rootfs tarball itself. Both get a
# SHA256SUMS; the release notes quote those hashes.
dist: preloads
	@test -n "$$NDK" || { echo "set NDK=<ndk>/bin" >&2; exit 1; }
	@if [ ! -f tools/loader/libc-nop.so.6 ] && [ -z "$(LIBC)" ]; then \
	    echo "missing guest libc artifact; set LIBC=<pristine glibc 2.39 libc.so.6> or run make libc-patch on a device" >&2; \
	    exit 1; \
	fi
	LIBC="$(LIBC)" sh tools/loader/build-embedded-loader.sh
	@test -f tools/loader/libc-nop.so.6 || { echo "guest libc artifact was not produced" >&2; exit 1; }
	sh tools/guest-config/build-guest-tools.sh
	sh tools/guest-config/build-logd.sh
	@mkdir -p dist
	cp tools/loader/ld-embedded.so dist/libld.so
	@chmod 755 dist/libld.so   # tar keeps the mode; a 644 loader is "not executable"
	cp $(PROFILE_DIR)/husk-ldconfig $(PROFILE_DIR)/husk-usermgr \
	   $(PROFILE_DIR)/husk-su $(PROFILE_DIR)/husk-symlinks \
	   $(PROFILE_DIR)/husk-window-wait $(PROFILE_DIR)/husk-logd \
	   $(PROFILE_DIR)/audio-setup $(PROFILE_DIR)/audio-relay \
	   $(PROFILE_DIR)/audio-capture $(PROFILE_DIR)/audio-probe dist/
	cp tools/loader/libc-nop.so.6 dist/libc.so.6   # the artifact `make libc-patch` refreshed
	cp tools/guest/install-husk.sh tools/guest/husk-session.sh \
	   tools/guest/husk-desktop.sh tools/guest/husk-ding-fallback.sh \
	   tools/guest/husk-wallpaper-fit.sh tools/guest/husk-system-services.sh \
	   tools/guest/husk-media-session.sh dist/
	@mkdir -p dist/guest dist/guest/gstreamer-1.0 dist/guest-config
	cp $(PROFILE_DIR)/wallpaper-scale dist/guest/
	@chmod 755 dist/guest/wallpaper-scale
	cp $(PROFILE_DIR)/libhusk_v4l2.so dist/guest/
	@chmod 755 dist/guest/libhusk_v4l2.so
	cp vendor/pipewire/libgstpipewire.so dist/guest/gstreamer-1.0/
	@chmod 644 dist/guest/gstreamer-1.0/libgstpipewire.so
	cp tools/guest-config/husk-gpu-defaults.sh tools/guest-config/husk-look.override \
	   tools/guest-config/husk-locale.sh tools/guest-config/fcitx5-profile \
	   tools/guest-config/pulse-client-no-shm.conf tools/guest-config/pipewire.conf \
	   tools/guest-config/wireplumber.conf \
	   tools/guest-config/linuxhub-system-bus.conf \
	   tools/guest-config/provision-accounts.sh tools/guest-config/guest-accounts.txt \
	   tools/guest-config/net.hadess.SensorProxy.policy \
	   tools/guest-config/60-husk-sensor-proxy.rules \
	   tools/guest-config/mksys-net.sh dist/guest-config/
	@mkdir -p dist/vendor/panvk dist/vendor/pipewire/src/gst dist/vendor/turnip
	cp -R vendor/panvk/fristonerr-1.2.0-mali-g77 dist/vendor/panvk/
# 高通（Adreno/KGSL）与 Mali 是两条独立驱动链；发布包必须同时携带，安装器按设备节点二选一。
	cp -R vendor/turnip/d211037c-adreno-825 dist/vendor/turnip/
	cp vendor/pipewire/1.0.5-gst-caps-subset.patch vendor/pipewire/COPYING \
	   vendor/pipewire/PROVENANCE.md dist/vendor/pipewire/
	cp vendor/pipewire/src/gst/gstpipewiresrc.c dist/vendor/pipewire/src/gst/
	cp VERSION dist/VERSION
# Deployment identity: the loader hash and the commit that produced it travel with
# the bundle, and install-husk.sh records the same six values into the tree's
# etc/husk/runtime-identity. tools/device-tests/23-runtime-identity.sh compares them.
	{ printf 'commit=%s\n' "$$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"; \
	  printf 'version=%s\n' "$$(cat VERSION)"; \
	  printf 'loader_sha256=%s\n' "$$(sha256sum dist/libld.so | cut -d' ' -f1)"; \
	  printf 'pipewire_plugin_sha256=%s\n' "$$(sha256sum dist/guest/gstreamer-1.0/libgstpipewire.so | cut -d' ' -f1)"; \
	  printf 'built=%s\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > dist/RUNTIME-IDENTITY
	@if [ -f tools/langpack/husk-lang-zh.tar.gz ]; then \
	    cp tools/langpack/husk-lang-zh.tar.gz dist/; \
	    tar tzf dist/husk-lang-zh.tar.gz | grep -qx 'usr/share/locale-langpack/zh_CN/LC_MESSAGES/gnome-shell.mo' || \
	        { echo "dist: lang pack is missing gnome-shell.mo" >&2; exit 1; }; \
	else \
	    echo "dist: no tools/langpack/husk-lang-zh.tar.gz; UI text will stay English" >&2; \
	fi
	COPYFILE_DISABLE=1 tar czf dist/husk-arm64.tar.gz -C dist \
	    libld.so libc.so.6 husk-ldconfig husk-usermgr husk-su husk-symlinks \
	    husk-window-wait husk-logd audio-setup audio-relay audio-capture audio-probe \
	    guest guest-config vendor install-husk.sh husk-session.sh husk-desktop.sh \
	    husk-ding-fallback.sh husk-wallpaper-fit.sh husk-system-services.sh \
	    husk-media-session.sh \
	    husk-lang-zh.tar.gz VERSION RUNTIME-IDENTITY
	@sh tools/ci/audit-runtime-boundary.sh dist/husk-arm64.tar.gz
	@sh tools/ci/audit-runtime-private-paths.sh dist/husk-arm64.tar.gz
	@sh tools/ci/audit-pipewire-plugin.sh dist/guest/gstreamer-1.0/libgstpipewire.so
# The installer writes /etc/profile.d/husk-gpu.sh from guest-config/, and skips it
# silently when the file is not next to it: a bundle without it installs a tree
# with no GPU defaults and no error. Asserted on the tarball, not on dist/.
# macOS 的 bsdtar 会把每个文件的扩展属性写成 AppleDouble 伴生项（._husk-su 之类），
# 它们也跟着发出去：解开后是 163 字节的垃圾，`tar tzf | wc -l` 直接多出 4 项。实测
# 2026-11-26 的 dist 里就有 4 个。COPYFILE_DISABLE=1 关掉它，并在这里断言没有漏网。
	@if tar tzf dist/husk-arm64.tar.gz | grep -qE '(^|/)\._'; then \
	    echo "dist: AppleDouble entries in the bundle:" >&2; \
	    tar tzf dist/husk-arm64.tar.gz | grep -E '(^|/)\._' | sed 's/^/    /' >&2; exit 1; \
	fi
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/husk-gpu-defaults.sh' || \
	    { echo "dist: bundle is missing guest-config/husk-gpu-defaults.sh" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'husk-logd' || \
	    { echo "dist: bundle is missing husk-logd; /dev/log and syslog would be absent" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/mksys-net.sh' || \
	    { echo "dist: bundle is missing guest-config/mksys-net.sh; /sys/class/net would be absent" >&2; exit 1; }
# 少了 locale 默认值，装出来的树不会报错，只是桌面回到英文界面、中文按日文字形渲染。
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/husk-locale.sh' || \
	    { echo "dist: bundle is missing guest-config/husk-locale.sh" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/fcitx5-profile' || \
	    { echo "dist: bundle is missing guest-config/fcitx5-profile" >&2; exit 1; }
# Same failure mode for the look defaults: a bundle without them installs a tree where
# the shell is Yaru and every app window is Adwaita, and nothing says why.
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/husk-look.override' || \
	    { echo "dist: bundle is missing guest-config/husk-look.override" >&2; exit 1; }
# The desktop session falls back to GNOME's "security mode" when this file is
# absent, while the installer itself succeeds.  Assert it on the tarball.
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/linuxhub-system-bus.conf' || \
	    { echo "dist: bundle is missing guest-config/linuxhub-system-bus.conf" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/pipewire.conf' || \
	    { echo "dist: bundle is missing guest-config/pipewire.conf; Snapshot cannot enumerate cameras" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/wireplumber.conf' || \
	    { echo "dist: bundle is missing guest-config/wireplumber.conf; WirePlumber shuts down without it" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest/libhusk_v4l2.so' || \
	    { echo "dist: bundle is missing guest/libhusk_v4l2.so; standard camera clients cannot open /dev/video*" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest/gstreamer-1.0/libgstpipewire.so' || \
	    { echo "dist: bundle is missing the gstpipewiresrc redundant-negotiation fix" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/provision-accounts.sh' || \
	    { echo "dist: bundle is missing guest-config/provision-accounts.sh" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/guest-accounts.txt' || \
	    { echo "dist: bundle is missing guest-config/guest-accounts.txt" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/net.hadess.SensorProxy.policy' || \
	    { echo "dist: bundle is missing the sensor proxy policy" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'guest-config/60-husk-sensor-proxy.rules' || \
	    { echo "dist: bundle is missing the sensor claim rule" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'husk-system-services.sh' || \
	    { echo "dist: bundle is missing husk-system-services.sh" >&2; exit 1; }
	@tar tzf dist/husk-arm64.tar.gz | grep -qx 'husk-media-session.sh' || \
	    { echo "dist: bundle is missing husk-media-session.sh" >&2; exit 1; }
# A bundle without the kbase PanVK snapshot installs successfully on Mali and then silently
# renders with llvmpipe. Assert the compressed driver, guest-relative ICD and license.
	@for f in \
	    vendor/pipewire/1.0.5-gst-caps-subset.patch \
	    vendor/pipewire/PROVENANCE.md \
	    vendor/pipewire/COPYING \
	    vendor/pipewire/src/gst/gstpipewiresrc.c \
	    vendor/panvk/fristonerr-1.2.0-mali-g77/libvulkan_panfrost_frist370_execva.so.gz \
	    vendor/panvk/fristonerr-1.2.0-mali-g77/husk_panvk_guest.json \
	    vendor/panvk/fristonerr-1.2.0-mali-g77/LICENSE-Mesa.txt \
	    vendor/panvk/fristonerr-1.2.0-mali-g77/PROVENANCE.md \
	    vendor/turnip/d211037c-adreno-825/libvulkan_freedreno_husk.so.gz \
	    vendor/turnip/d211037c-adreno-825/husk_turnip_guest.json \
	    vendor/turnip/d211037c-adreno-825/PROVENANCE.md; do \
	    tar tzf dist/husk-arm64.tar.gz | grep -qx "$$f" || \
	        { echo "dist: bundle is missing $$f" >&2; exit 1; }; \
	done
# 0.0.6 补的三条断言：这几个文件少了不会报错，只会让装出来的树缺一件东西
# （husk-session.sh 的 `[ -x ... ]` 判假、pulse 客户端静默丢掉 enable-shm=no）。
	@for f in husk-desktop.sh husk-media-session.sh husk-ding-fallback.sh husk-wallpaper-fit.sh \
	          husk-window-wait guest/wallpaper-scale guest-config/pulse-client-no-shm.conf; do \
	    tar tzf dist/husk-arm64.tar.gz | grep -qx "$$f" || \
	        { echo "dist: bundle is missing $$f" >&2; exit 1; }; \
	done
	@rm -f dist/libld.so dist/libc.so.6 dist/husk-ldconfig dist/husk-usermgr \
	    dist/husk-su dist/husk-symlinks dist/husk-window-wait dist/husk-logd dist/install-husk.sh dist/husk-session.sh \
	    dist/husk-desktop.sh dist/husk-media-session.sh dist/husk-ding-fallback.sh dist/husk-wallpaper-fit.sh \
	    dist/husk-system-services.sh \
	    dist/husk-lang-zh.tar.gz dist/VERSION
	@rm -rf dist/guest dist/guest-config dist/vendor
	@cd dist && sha256sum husk-arm64.tar.gz > SHA256SUMS && cat SHA256SUMS

clean:
	cargo clean --manifest-path $(MANIFEST)
