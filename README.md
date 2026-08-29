English | [中文](README.zh-CN.md)

# Honor 80 GT Privilege Escalation PoC: GhostLock (CVE-2026-43499)

A local privilege escalation exploit for the **Honor 80 GT (AGT-AN00)**,
CVE-2026-43499 — a use-after-free in the kernel `rtmutex` `remove_waiter`
path — plus a companion KernelSU kernel-module loading solution.

In principle the bug and the techniques here apply to every MagicOS build
up to 9.0.0.230. Adapted versions:

| MagicOS | Kernel | Status |
|---|---|---|
| 8.0.0.128 | 5.10.168 | ✅ verified |
| 8.0.0.160 | 5.10.209 | ✅ verified |
| 9.0.0.157 | 5.10.209 | ✅ verified |
| 9.0.0.200SP1 | 5.10.236 | ✅ verified |
| 9.0.0.220SP2 / SP4 | 5.10.236 | ✅ verified (SP4 ships the same boot image as SP2) |
| 9.0.0.230 | 5.10.236 | ✅ verified |
| 8.0.0.131 | 5.10.198 | ⚠️ not verified on a real device |
| 8.0.0.135 / 143 / 150 | 5.10.198 | ⚠️ not verified on a real device |
| 8.0.0.161 | 5.10.209 | ⚠️ not verified on a real device |
| 9.0.0.102 / 103 / 120 / 130 / 165 | 5.10.209 | ⚠️ not verified on a real device (103 ships the same boot image as 102) |
| 9.0.0.175SP1 / 187 | 5.10.226 | ⚠️ not verified on a real device |
| 9.0.0.210 | 5.10.236 | ⚠️ not verified on a real device |

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
> per run — run it again.
> - **Root is full control of the device — use it carefully.** This project
> only gets you root; flashing images, writing partitions, disabling
> protections, or installing untested modules afterwards can permanently
> brick the device, and that is your responsibility.

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

One prebuilt bundle covers every supported firmware: download it from
[Releases](../../releases), unpack it on the host, and run

```sh
./setup.sh            # PC, with adb: identifies the kernel, picks the
                      # matching exploit, runs the chain, retries when an
                      # attempt fails
```

Without a PC, unpack the bundle on the phone and run the same script
from a Shizuku shell (rish) — it detects where it is and does the rest
locally:

```sh
sh /sdcard/ghostlock/setup.sh
```

The script matches the running kernel against the bundled manifest:
verified firmwares run directly, known-but-untested ones ask for
confirmation, anything else is refused.

Build from source instead:

```sh
# 1. Build the exploit binary
cd exploit && ./docker-build.sh bin             # exploit_static (8.0.0.128)
#    8.0.0.160: ./docker-build.sh PROJECT=annap-AGT-AN00_8.0.0.160 bin
#    (the static binary bakes in the default env config; any knob can still
#     be overridden by environment variables at launch; first run pulls the NDK, ~1.2GB)

# 2. The KSU-side binaries live in ksu/tools/ (see ksu/tools/README.md):
#    kernelsu.ko — build per ksu/README.md;
#    ksud, magiskpolicy, ksu_rules — shipped in the repo;
#    load_ko, kmsg_dumper — ./docker-build.sh tools

# 3. Enable ADB debugging on the phone, then
bash ../ksu/ksu_load_ko.sh
#    8.0.0.160: PROJECT=annap-AGT-AN00_8.0.0.160 bash ../ksu/ksu_load_ko.sh
```

The script drives the whole chain over adb: GhostLock (root access, SELinux
permissive, `sig_enforce` disabled), SELinux policy injection via magiskpolicy, fake kallsyms
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
KernelSU against the MagicOS kernel source matching the firmware's
sublevel and the device's own kernel config. See `ksu/README.md`.

## Verification status

Full chain (UAF → KASLR → arbitrary R/W → cred → SELinux permissive →
sig_enforce → KernelSU live, enforcing restored, boot_id restored)
verified on a real device for the versions marked ✅ above; versions
marked ⚠️ are adapted but not verified on a real device. A run
can fail and reboot the phone; the setup script retries automatically,
or run it again.

## Credits

- [CyberMeowfia / IonStack](https://github.com/NebuSec/CyberMeowfia)
- [KernelSU](https://github.com/tiann/KernelSU) 
- [Magisk](https://github.com/topjohnwu/Magisk)

## License

- The exploit and tooling in this repository (`exploit/`, top-level docs) are
under the **Apache License 2.0** (see [LICENSE](LICENSE)), same as the
upstream IonStack PoC this port derives from.
- The files under [`ksu/`](ksu/) are **GPL-2.0** (see
[ksu/LICENSE](ksu/LICENSE)): `init-bootid.patch` and the `ksu_rules.annotated` policy
set derive from KernelSU's `kernel/` directory, which is GPL-2.0.

