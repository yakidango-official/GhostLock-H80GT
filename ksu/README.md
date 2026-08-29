English | [中文](README.zh-CN.md)

# Custom KernelSU.ko for Honor 80 GT

The stock GKI `android12-5.10_kernelsu.ko` is built against GKI headers whose
struct layouts don't match Honor's, so it cannot load. It must be
rebuilt from Honor's own kernel source (the MagicOS opensource package) with
the device's exact `/proc/config.gz` so that every offset is correct at
compile time. Three patches are applied to the KernelSU source:

1. **SELinux policy injection.** Rules are injected with magiskpolicy
   --live before the module loads, instead of by the module itself
   (`tools/ksu_rules`).
2. **No automatic re-enforce.** The loader script restores SELinux enforcing
   manually as its last step — doing it earlier would leave the exploit's root
   process unable to write files or exec programs.
3. **boot_id pointer fix.** The exploit hijacks boot_id's memory pointer and
   never restores it, which would crash apps on startup; the module points it
   back at the real buffer on load.

## Build

The prerequisite is an Honor MagicOS opensource kernel tree whose sublevel
matches the target firmware (the `Code_Opensource/kernel` directory of the
AGT-AN00 package): the MagicOS 8.0 tree for 8.0.0.128 (kernel 5.10.168), the
MagicOS 9.0 tree for 8.0.0.160 and later (kernel 5.10.209):

```
KERNEL_SRC=/path/to/Code_Opensource/kernel bash ksu_ko_build.sh
```

`kernel.config` in this directory is a 5.10.236 device config (byte-identical
across the 5.10.236 firmwares), used as the build default; the released
kernelsu.ko is always built with this config, so rebuilding from the repo
reproduces the exact same file. The supported firmwares' configs compile
to identical struct layouts, so the resulting .ko loads on every supported
firmware; to build against another firmware's config anyway, pass it via
`KSU_DEVICE_CONFIG` (its `/proc/config.gz`, or `extract-ikconfig` output
from its boot.img):

```
KERNEL_SRC=/path/to/Code_Opensource/kernel KSU_DEVICE_CONFIG=/path/to/your_config bash ksu_ko_build.sh
```

The KernelSU source (auto-cloned and patched on first run; the upstream tag is pinned in ksu_ko_build.sh) and the
device symbol-name list are staged automatically into `ksu/.build/`. The
output is `ksu/.build/kernelsu.ko` — copy it to
`tools/kernelsu.ko` for use. The .ko is a build artifact and is not tracked in git — build or drop it in before assembling a release.

## Load

```
bash ksu_load_ko.sh
```

The script does everything: exploit root → policy injection → module load →
ksud bring-up → SELinux enforcing restored last.

## Known boundary: module sepolicy.rule and runtime policy changes

Module `sepolicy.rule` files are applied by ksud's dynamic injection
(`handle_sepolicy`) during the loader window — device-verified, including
two consecutive applies in one session. Both `handle_sepolicy` and
`apply_kernelsu_rules` use dup + RCU swap + destroy (neither calls
`security_load_policy`); that mechanism has not broken this device. A 2026-08
servicemanager breakage once attributed to it was later root-caused to the
exploit's own permissive write clearing `selinux_state.initialized@+2` (see
the comment in `init-bootid.patch`). Applying rules at runtime outside the
loader window (installing/enabling a module while enforcing) is unverified —
run a hot reboot to pick up such modules.
