<!-- Landing page: title, icon, centered summary, stack badges, navigation. -->
<h1 align="center">Husk</h1>

<p align="center">
  <img src="docs/assets/brand/husk-mark-hexagon-h-512.png" width="128" alt="Husk">
</p>

<p align="center">
  <strong>A native Linux runtime for Android.</strong><br>
  Runs a real glibc Linux userland directly on the Android kernel: no PRoot tracer and no second VM.
</p>

<p align="center">
  <img alt="Runtime: Husk" src="https://img.shields.io/badge/runtime-Husk-111827?style=flat-square">
  <img alt="Userland: glibc" src="https://img.shields.io/badge/userland-glibc-0F766E?style=flat-square">
  <img alt="Ubuntu 24.04" src="https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white">
  <img alt="GNOME 46 / X11 host" src="https://img.shields.io/badge/Desktop-GNOME%2046%20%2F%20X11-4A86CF?style=flat-square&logo=gnome&logoColor=white">
  <img alt="PanVK + Turnip / Zink" src="https://img.shields.io/badge/GPU-PanVK%20%2B%20Turnip%20%2F%20Zink-7C3AED?style=flat-square">
  <img alt="Android ARM64" src="https://img.shields.io/badge/Platform-Android%20ARM64-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="Rust 1.75+" src="https://img.shields.io/badge/Rust-1.75%2B-DEA584?style=flat-square&logo=rust&logoColor=white">
  <img alt="License: Apache-2.0" src="https://img.shields.io/badge/License-Apache--2.0-2563EB?style=flat-square">
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="README_EN.md">English</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="SECURITY.md">Security</a>
</p>

---

## Overview

Husk runs an unmodified glibc Linux ARM64 userland as ordinary Android application processes.
Programs issue syscalls directly to the Android kernel. There is no root requirement, namespace,
virtual machine, or per-syscall `ptrace` interception.

Path rewriting happens at load time: the loader redirects path-related function entries to the
Husk path-shim, which maps guest absolute paths into the application-private rootfs and then calls
the real libc/kernel entry point. After startup, the program's own syscalls go straight to the
kernel.

PRoot rewrites every path-related syscall through a tracer. Husk rewrites the GOT once at load
time. The difference grows with path and syscall density and disappears for large sequential I/O.

The reference environment is Ubuntu 24.04, glibc 2.39, arm64 Android 13, and Mali-G77. Exact device
conditions and evidence are recorded in [`docs/STATUS.md`](docs/STATUS.md) and
[`docs/RESULTS.md`](docs/RESULTS.md).

## Requirements

Three hard requirements:

| # | Requirement | Failure mode |
|---|---|---|
| 1 | **arm64 / aarch64** | `Exec format error` |
| 2 | **A writable, executable, sandbox-allowed directory** | The loader cannot execute or a `noexec` mount fails |
| 3 | **No extra seccomp/SELinux restriction for `untrusted_app`** | `Bad system call` or a killed process |

Reference setup: Android 13, kernel 4.19.191, 4 KiB pages, no root, no Shizuku, locked bootloader.
16/64 KiB page devices remain UNVERIFIED on real hardware.

## Install and start

Production deployment ships `dist/husk-arm64.tar.gz` in APK assets, extracts it into the app-private
directory, then runs the installer to prepare the rootfs. The installer installs the loader and
patched libc, normalizes absolute symlinks, replaces guest `ldconfig` and user/group tools, creates
runtime directories, and records `etc/husk/runtime-identity`.

```sh
tar xzf husk-arm64.tar.gz
cd husk
sh install-husk.sh \
  --rootfs /path/to/ubuntu-rootfs.tar \
  --dest /path/to/app-private/rootfs \
  --loader ./libld.so
```

See [`docs/RUNNING.md`](docs/RUNNING.md) for the full startup contract, upgrade flow, and recovery.

## Build

```sh
NDK=$ANDROID_HOME/ndk/<ver>/toolchains/llvm/prebuilt/<host>/bin \
  sh tools/loader/build-embedded-loader.sh

cargo build --release --manifest-path runtime/Cargo.toml
make check
cargo test -p gpu-env
make test-device
NDK=<ndk>/bin make dist
```

## Capabilities and limits

- A working aarch64 glibc userland: bash, coreutils, Python, GCC, make, apt and dpkg.
- Nested exec, PTYs, signals and process views are covered by the device gates.
- GPU direct access on two separate driver chains: Mali (kbase) through `/dev/mali0` with PanVK + Zink,
  and Adreno (KGSL) through `/dev/kgsl-3d0` with a source-built Turnip + Zink.
  Adreno 825 renders correctly for wallpaper and GL clients, but client window content is still not
  composited by the host X server (no DRM render node for DRI3) — an external blocker.
- Camera, audio, video, sensors and location are mediated interfaces, not direct device passthrough.
- The X11 desktop, input injection and Surface presentation belong to the LinuxHub host application.
- Static ELF binaries and direct raw syscalls are not path-rewritten; Husk is not a security sandbox.

The latest validated device results and known failures are in
[`docs/RESULTS.md`](docs/RESULTS.md) and [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
