# Honor X50 Root — GhostLock-based su Setup

**Date:** 2026-08-27
**Device:** Honor X50 (ALI-AN00), MagicOS 8.0, Android 14, kernel 5.10.209
**Goal:** Persistent setuid-root `su` binary for interactive root shell access

---

## Background

- Stock device has no `su` and no Magisk/KernelSU module loaded
- GhostLock exploit (CVE-2026-43499 port) achieves `cred` write → kernel-context
  anchor, can flip **SELinux Permissive** and **sig_enforce=N**
- `/data` is mounted with `nosuid,nodev` — setuid bit is ignored until remounted
- Android's mksh/dash checks `ruid==0` before honoring setuid → plain `setuid(0)`
  is not enough; need `setresuid(0,0,0)` so all three UIDs are zero

---

## Solution

Compile a tiny static ARM64 binary (`su.c`) that does:
1. `setresuid(0,0,0)` + `setresgid(0,0,0)` + `setuid(0)`
2. `execv("/system/bin/sh", ...)` (with `-c cmd` if invoked accordingly)

Push it to the device, run the exploit to get permissive + sig_enforce flip,
remount `/data` without `nosuid`, then chown root:root and chmod 6755.

---

## Files

| File | Purpose |
|---|---|
| `su.c` | Source: minimal static su |
| `build_su.bat` | Build via Android NDK clang (Windows) |
| `su_arm64` | Pre-built static ARM64 ELF (2.2 MB) |
| `su.sh` | On-device wrapper (`sh /data/local/tmp/su.sh id`) |
| `../root_setup.ps1` | End-to-end setup script (push → exploit → chown) |

---

## Build

```bat
cd root
build_su.bat
:: -> su_arm64 (2.2 MB static ARM64 ELF)
```

NDK path: `D:\android-ndk-r27-windows\android-ndk-r27`
Toolchain: `aarch64-linux-android35-clang.cmd`
Flags: `-static -o su_arm64 su.c`

---

## End-to-end Setup (one shot)

```powershell
# From F:\hdc_magic\GhostLock-H80GT\
powershell -ExecutionPolicy Bypass -File root_setup.ps1
```

What it does:
1. `mkdir /data/local/tmp/root_<stamp>` (fresh RUNDIR — old `ksu_run_*` dirs
   have poisoned inodes from prior runs)
2. Push `exploit_ondevice_static` → `$RUNDIR/h80gt_exploit` (chmod 755)
3. Push `su_arm64` → `/data/local/tmp/su` (chmod 755)
4. Run exploit detached: `SE_LINUX=1 FLIP_SIG=1 KSU_RUNDIR=$RUNDIR`
5. Poll `exploit.log` for `chain complete` (≤90 iterations × 2 s)
6. Via cmd watcher: `chown root:root && chmod 6755 && mount -o remount,rw,suid /data`
7. Verify `ls -la /data/local/tmp/su` shows `root root` + `-rwsr-sr-x`
8. Test: `/data/local/tmp/su -c 'id'` → `uid=0(root)`

Typical runtime: **~35 s** (exploit) + ~5 s (setup) = ~40 s total.

---

## Daily Use

After setup, interactively:
```bash
# Single root command
adb shell /data/local/tmp/su -c 'cat /proc/kallsyms | head'

# Interactive root shell
adb shell /data/local/tmp/su
# -> prompt opens as uid=0(root)

# Wrapper
adb shell sh /data/local/tmp/su.sh insmod /data/local/tmp/foo.ko
```

Tested working: `id`, `mount`, `lsmod`, `insmod`, `cat /proc/kallsyms`,
`dmesg` (read-only), arbitrary shell builtins.

---

## Re-running After Reboot

SELinux + sig_enforce reset to Enforcing on every boot. Re-run:
```powershell
powershell -ExecutionPolicy Bypass -File F:\hdc_magic\GhostLock-H80GT\root_setup.ps1
```

**Pre-flight:** device must be at `uptime >= 240 s` (early-boot antiroot window).
The script does NOT enforce this — re-run if exploit route-misses on first try.

---

## Known Limitations

1. **boot_id hijacked**: exploit swaps `sysctl_bootid.ctl.data` pointer; never
   restored (RESTORE walk hard-reset the device in earlier tests). A clean
   reboot clears this. If the device panics mid-exploit, `random` UUID is
   broken — reboot to recover.
2. **rscan_skip_flag**: Honor's TEE antiroot check is bypassed each run via
   arb-write; resets on boot.
3. **Antiroot daemon**: the `rscan_skip` trick makes kernel see it as set; the
   Honor `HwRscan` daemon *may* still flag the device over a long session.
4. **sig_enforce=N persists** across exploit runs but not across reboots.
5. **Parked waiters accumulate**: each exploit run leaves `h80gt_parked`
   kernel threads. Reboot after a few runs to clear them.
6. **No interactive `su -`**: this is a `su` shim, not Magisk/KSU. No UID
   mapping, no app management, no Zygisk. For module loading only.

---

## Memory References

- [[ghostlock-h80gt-ali-an00-port]] — exploit build, target offsets, env
- [[ksgl-path-honor-success]] — the ksgl path that proved the exploit chain
  works on this kernel (5.10.209)
- [[cve-2026-43499-5-10-209-deadend]] — earlier "deadend" verdict that
  ksgl then overturned

---

## Next Steps (when KSU is requested)

1. Build `kernelsu.ko` with `patch_init.py` (boot_id restore + skip
   apply_kernelsu_rules + skip setenforce)
2. Push ko + ksud + magiskpolicy to device
3. Via this same root shell:
   `insmod /data/local/tmp/kernelsu.ko h80gt_bootid_ctl=0x... h80gt_bootid_buf=0x...`
4. `echo 1 > /sys/fs/selinux/enforce` LAST
5. Verify: `ksud --post-fs-data --stage 1`