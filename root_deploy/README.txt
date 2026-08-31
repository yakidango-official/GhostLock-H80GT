# Honor X50 Root + KSU — Deploy Package

## Files (8.7MB total)

| File | Size | Purpose |
|---|---|---|
| `root_setup.bat` | 3.3 KB | Step 1: exploit → Permissive + su setuid |
| `ksu_setup.bat` | 3.0 KB | Step 2: load kernelsu_h80gt.ko + ksud |
| `exploit_ondevice_static` | 2.3 MB | ARM64 GhostLock exploit (env-baked ALI-AN00) |
| `su_arm64` | 2.2 MB | Static ARM64 su (setresuid + exec sh) |
| `kernelsu_h80gt.ko` | 6.4 MB | Custom KSU ko with boot_id restore + skip apply_kernelsu_rules |
| `ksud` | 4.6 MB | KernelSU userspace daemon |
| `load_ko` | 2.2 MB | Helper: SHN_ABS resolution via fake kallsyms + init_module |
| `magiskpolicy` | 357 KB | KSU SELinux policy injector |
| `ksu_rules` | 942 B | KSU rules file |
| `i2c-dev.ko` | 364 KB | Sample kernel module for testing |

## Two-step Usage

### Step 1: Get root (temporary, ~40s)
```cmd
cd F:\hdc_magic\GhostLock-H80GT\root_deploy
root_setup.bat
```
Auto does:
1. Push exploit + su binary
2. Run GhostLock → SELinux Permissive + sig_enforce=N
3. Via kernel-context cmd watcher: chown root + chmod 6755 + remount /data
4. Unlock /data (chmod 0777) for su traversal

### Step 2: Load KSU ko (persistent, ~30s)
```cmd
ksu_setup.bat
```
Auto does:
1. Push ko + ksud + load_ko + magiskpolicy + ksu_rules
2. Build fake kallsyms (prepend commit_creds)
3. Bind-mount to /proc/kallsyms
4. Run ksud --post-fs-data (loads ko)
5. Run ksud --boot-completed (completes setup)
6. Final: `echo 1 > /sys/fs/selinux/enforce`

## After Both Steps

```cmd
adb shell su -c id                  REM via KernelSU manager
adb shell /data/local/tmp/su -c id  REM our static su (still works)

adb push test.ko /data/local/tmp/
adb shell su -c 'insmod /data/local/tmp/test.ko'

REM Verify KSU module
adb shell cat /proc/modules | findstr kernelsu
```

## Re-run After Reboot

```cmd
root_setup.bat
ksu_setup.bat
```

SELinux + sig_enforce reset on boot. Total ~70s for full setup.

## Verified State

```
State: enforce=Enforcing sig_enforce=Y
Module: kernelsu 200704 3 - Live 0x0000000000000000 (OE)
/data/adb/ksu/:
├── bin/ksud, busybox, bootctl, resetprop
├── .feature_config
└── modules/<your ko files>
```

## Key Technical Notes

1. **Git Bash /data path mangling**: All adb commands must be run from `cmd` (not bash)
2. **ksucmdwatch is kernel context**: Only path to bypass Honor f2fs seclabel + check_root hook
3. **commit_creds is stripped from kallsyms**: load_ko needs fake kallsyms bind-mount
4. **/data chmod 0777**: Required for su traversal (Honor seclabel trap)
5. **enforce is LAST step**: Loading ko + ksud while permissive, then enforce

## Memory References

- `ghostlock-h80gt-ali-an00-port` — exploit build, target.h
- `ksgl-path-honor-success` — ksgl path that proved exploit on 5.10.209
- `root/README.md` — detailed root setup notes