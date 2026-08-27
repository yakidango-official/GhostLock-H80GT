# ksu/tools — KSU bundle members

The on-device package carries a set of helper binaries. Provenance per file:

| file | source | how to obtain |
|---|---|---|
| `load_ko` | `load_ko.c` (this repo) | `cd exploit && ./docker-build.sh tools` |
| `kmsg_dumper` | `kmsg_dumper.c` (this repo) | `cd exploit && ./docker-build.sh tools` |
| `kernelsu.ko` | custom KernelSU v3.2.5 build | build via `..` (see `../README.md`), copy the result here |
| `ksud` | shipped in this repo | extracted from the KernelSU v3.2.5 release APK (`lib/arm64-v8a/libksud.so`) |
| `magiskpolicy` | shipped in this repo | unmodified from a Magisk release (arm64), GPL-3.0 — source: [Magisk](https://github.com/topjohnwu/Magisk) |
| `ksu_rules` | this repo | — (magiskpolicy policy injection) |
| `ksu_loader.tmpl` | this repo | — (anchor-exec'd autonomous load script) |

## What the binaries do

- **load_ko** — minimal `kernelsu.ko` loader replicating KernelSU's
  `ksuinit::load_module`: resolves the .ko's `SHN_UNDEF` symbols against
  (a bind-mounted fake) `/proc/kallsyms`, rewrites them to `SHN_ABS`, and
  calls plain `init_module(flags=0)`. Exists because ksud's own insmod was
  failing silently on this device.
- **kmsg_dumper** — streams `/dev/kmsg` to a file with `O_SYNC` so kernel
  logs survive a fast panic (no ramoops/netconsole on this device).
- **ksu_rules** — the KernelSU policy for `magiskpolicy --apply --live`,
  injected *before* module load (the kernel's own
  `security_load_policy`/`sidtab_convert` path keeps running domains valid —
  the module's own in-kernel `apply_kernelsu_rules()` swap is skipped via
  `../init-bootid.patch`, it breaks running domains on this device).
  `../ksu_rules.annotated` is the same rule set with per-rule commentary.
- **ksu_loader.tmpl** — the autonomous on-device loader executed by the
  exploit's root anchor: freezes hisecd (thawed at the end AND on every abort
  path — a frozen hisecd wedges Honor's periodic root scan into daily
  system_server watchdog reboots), flips kptr_restrict, builds + binds the
  fake kallsyms, injects the policy, loads the .ko, runs the ksud
  stages, and re-enforces SELinux last. `@PLACEHOLDER@`s are rendered by the
  launcher (`../ksu_load_ko.sh`).
  On any abort the exploit-side boot_id hijack is never restored (the .ko's
  bootid_ctl/bootid_buf params do that on success), so an aborted run REQUIRES a
  reboot — the script says so loudly in its log.
