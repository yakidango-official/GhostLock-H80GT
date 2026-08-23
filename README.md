English | [中文](README.zh-CN.md)

# Honor 80 GT Privilege Escalation PoC: GhostLock (CVE-2026-43499)

A local privilege escalation exploit for the **Honor 80 GT (AGT-AN00, MagicOS
8.0.0.128, kernel 5.10.168)** (CVE-2026-43499, a use-after-free in the kernel
`rtmutex` `remove_waiter` path), plus a companion KernelSU kernel-module
loading solution.

> ⚠️ **Warning**
>
> - For security research on **your own device** only.
> - **USE AT YOUR OWN RISK.** This software comes with NO warranty of any
> kind (see [LICENSE](LICENSE)). Simply running it should not brick your
> device or lose data in theory, but back up first anyway; whatever
> happens — from running this code or from anything you do with the root
> access it grants — is your responsibility, not the authors'.
> - The exploit modifies kernel memory through a UAF. A failed attempt
> reboots the device; a reboot restores everything. Success is not 100%
> per run — just run it again.
> - **Root is full control of the device — use it carefully.** This project
> only gets you root; flashing images, writing partitions, disabling
> protections, or installing untested modules afterwards can permanently
> brick the device, and that is on you.

## Repository layout

```
exploit/     GhostLock PoC source (Android arm64) + build system
  src/         exploit core: futex UAF, KASLR slide, sysctl boot_id hijack,
               arbitrary R/W, cred/SELinux/sig_enforce writes, KSU load
  src/targets/ per-firmware offset tables (target.h)
ksu/         custom kernelsu.ko build (MagicOS kernel + device config) and the
             PC-side adb load driver
  tools/       on-device load helpers: load_ko.c / kmsg_dumper.c (built from
               source), policy rules, loader template (+ where to get the
               binaries)
```

## Usage

Requirements: Docker, Android Platform Tools.

Prebuilt package (tested only on MagicOS 8.0.0.128): [h80gt_setup.sh](https://github.com/yakidango-official/GhostLock-H80GT/releases/download/v0.1/h80gt_setup.sh)

```sh
adb push h80gt_setup.sh /sdcard/
adb shell sh /sdcard/h80gt_setup.sh     # or from a Shizuku (rish) shell
```

Build from source instead:

```sh
# 1. Build the device exploit binary
cd exploit && ./docker-build.sh bin             # exploit_static
#    (./docker-build.sh ondevice builds the static binary with the default
#     env config baked in; first run pulls the NDK, ~1.2GB)

# 2. Obtain/build the KSU bundle binaries into ksu/tools/ —
#    see ksu/tools/README.md (kernelsu_h80gt.ko: ksu/README.md;
#    ksud: shipped in the repo; magiskpolicy: shipped in the repo; load_ko/kmsg_dumper:
#    ./docker-build.sh tools)

# 3. Enable ADB debugging on the phone, then
bash ../ksu/ksu_load_ko.sh
```

The script drives the whole chain over adb: GhostLock (root + permissive +
`sig_enforce` flip), SELinux policy injection via magiskpolicy, fake kallsyms
bind-mount, `load_ko` (`init_module`), then the ksud bring-up stages,
restoring SELinux enforcing as the absolute last step. Wait for `kernelsu`
in `/proc/modules`, then open the KernelSU manager (shows "Working &lt;LKM&gt; [Jailbreak mode]").

## Why a custom .ko and loader

- `CONFIG_MODULE_SIG_FORCE=y` — the runtime `sig_enforce` flag blocks
unsigned module loads; the exploit temporarily flips it to 0 (the loader
script restores it to 1 once the module is in).
- kallsyms name-stripping: Honor removes `commit_creds` and friends from
`/proc/kallsyms`, so the kernel loader can't resolve the .ko's undefined
symbols. The flow bind-mounts a fake kallsyms with the stripped symbols
prepended at their true runtime addresses (link addr + KASLR slide).
- GKI struct layouts also differ from Honor's, so the stock GKI
`android12-5.10_kernelsu.ko` cannot be used directly. `ksu/` rebuilds
KernelSU v3.2.5 against the MagicOS 5.10.168 kernel source and the
device's own `/proc/config.gz`. See `ksu/README.md`.

## Verification status

- Full chain (UAF → KASLR → arbitrary R/W → cred → SELinux permissive →
sig_enforce → KernelSU live, enforcing restored) verified on the real
device.

## Credits

- [CyberMeowfia / IonStack](https://github.com/NebuSec/CyberMeowfia)
- [KernelSU](https://github.com/tiann/KernelSU) 
- [Magisk](https://github.com/topjohnwu/Magisk)

## License

- The exploit and tooling in this repository (`exploit/`, top-level docs) are
under the **Apache License 2.0** (see [LICENSE](LICENSE)), same as the
upstream IonStack PoC this port derives from.
- The files under [`ksu/`](ksu/) are **GPL-2.0** (see
[ksu/LICENSE](ksu/LICENSE)): `init-h80gt.patch` and the `ksu_rules.annotated` policy
set derive from KernelSU's `kernel/` directory, which is GPL-2.0.

