English | [中文](README.zh-CN.md)

# Custom KernelSU.ko for Honor 80 GT

The stock GKI `android12-5.10_kernelsu.ko` is built against GKI headers whose
struct layouts don't match Honor's, so it can't load properly. It must be
rebuilt from Honor's own kernel source (the MagicOS opensource package) with
the device's exact `/proc/config.gz` so that every offset is correct at
compile time. Three patches are applied to KernelSU v3.2.5's
`kernel/core/init.c`:

1. **SELinux policy injection.** The rules are instead injected with
   magiskpolicy --live before the module loads (`tools/ksu_rules`).
2. **No automatic re-enforce.** The loader script restores SELinux enforcing
   manually as its last step — doing it earlier would leave the kernel-domain
   anchor unable to write files or exec programs.
3. **boot_id pointer fix.** The exploit hijacks boot_id's memory pointer and
   never restores it, which would crash apps on startup; the module points it
   back at the real buffer on load.

## Build

The prerequisite is an Honor MagicOS opensource kernel tree whose sublevel
matches the target firmware (the `Code_Opensource/kernel` directory of the
AGT-AN00 package): the MagicOS 8.0 tree for 8.0.0.128 (kernel 5.10.168), the
MagicOS 9.0 tree for 8.0.0.160 (kernel 5.10.209):

```
KERNEL_SRC=/path/to/Code_Opensource/kernel bash ksu_ko_build.sh
```

`kernel.config` in this directory is the 220SP2 (5.10.236) device config
(from its `/proc/config.gz`), used as the build default; the released
kernelsu.ko is always built with this config, so rebuilding from the repo
reproduces the exact same file. The supported firmwares' configs compile
to identical struct layouts, so the resulting .ko loads on every supported
firmware; to build against another firmware's config anyway, pass it via
`KSU_DEVICE_CONFIG` (its `/proc/config.gz`, or `extract-ikconfig` output
from its boot.img):

```
KERNEL_SRC=/path/to/Code_Opensource/kernel KSU_DEVICE_CONFIG=/path/to/your_config bash ksu_ko_build.sh
```

The KernelSU v3.2.5 source (auto-cloned and patched on first run) and the
device symbol-name list are staged automatically into `ksu/.build/`. The
output is `ksu/.build/kernelsu.ko` — copy it to
`tools/kernelsu.ko` for use.

## Load

```
bash ksu_load_ko.sh
```

The script does everything: exploit root → policy injection → module load →
ksud bring-up → SELinux enforcing restored last.
