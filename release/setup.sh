#!/bin/sh
# GhostLock jailbreak driver for the HONOR 80 GT (AGT-AN00).
#
# One bundle covers every supported firmware: setup.sh reads the running
# kernel, looks it up in the manifest, and runs that firmware's exploit.
#   - verified firmwares run directly
#   - known-but-untested firmwares ask for confirmation first
#   - anything else is refused
#
# Runs either on the phone (Shizuku/rish shell) or on the PC (adb attached).
# The flow is the same either way: stage a fresh run directory, launch the
# chain detached (never piped), watch for the KernelSU module, retry on the
# known early-miss reboot (up to 3 attempts, new run directory each time).
#
# Bundle layout (same directory as this script):
#   exploits/<ver>/exploit   per-firmware exploit binaries
#   manifest                 kernel string -> firmware -> status
#   ksu_loader.tmpl, ksu_rules, kernelsu.ko, load_ko, magiskpolicy,
#   ksud, kmsg_dumper

# NOTE: keep this file POSIX/mksh-clean — on the device it runs under
# Android's sh, not bash.

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

ATTEMPTS=3
RD_ROOT=/data/local/tmp

# ---- environment detection -------------------------------------------------
MODE=unknown
if command -v getprop >/dev/null 2>&1 && [ -e /system/bin/sh ]; then
  MODE=device
elif command -v adb >/dev/null 2>&1; then
  MODE=pc
  SERIAL="${1:-}"
  if [ -n "$SERIAL" ]; then ADB="adb -s $SERIAL"; else ADB="adb"; fi
else
  echo "no getprop (not on the device) and no adb (not on a PC) — cannot run"
  exit 1
fi

dev() {  # run a command on the device
  # Join the args into one command string: adb re-splits it remotely and
  # sh -c needs a single string ('sh -c uname -r' would run bare 'uname').
  if [ "$MODE" = pc ]; then $ADB shell "$*"; else sh -c "$*"; fi
}

put() {  # copy one bundle file into $1 on the device
  if [ "$MODE" = pc ]; then $ADB push "$HERE/$1" "$2" >/dev/null; else cp "$HERE/$1" "$2"; fi
}

wait_booted() {
  if [ "$MODE" = pc ]; then
    i=0
    while [ $i -lt 60 ]; do
      [ "$($ADB get-state 2>/dev/null)" = device ] && return 0
      sleep 5; i=$((i + 1))
    done
    return 1
  else
    i=0
    while [ $i -lt 60 ]; do
      [ "$(dev 'getprop sys.boot_completed')" = "1" ] && return 0
      sleep 5; i=$((i + 1))
    done
    return 1
  fi
}

# ---- preflight --------------------------------------------------------------
echo "== GhostLock for HONOR 80 GT (AGT-AN00)"
echo "== mode: $MODE"

wait_booted || { echo "device not ready"; exit 1; }

# -f, not -x: on the phone the bundle sits on /sdcard (FUSE, noexec) — the
# binary is staged to /data/local/tmp and chmod'ed before it runs.
[ -f "$HERE/manifest" ] || { echo "missing $HERE/manifest (incomplete unpack?)"; exit 1; }

K="$(dev uname -r | tr -d '\r')"
MATCH="$(grep -F "$K|" "$HERE/manifest" | head -1)"
if [ -z "$MATCH" ]; then
  echo "未知设备/系统。"
  exit 1
fi
VER="$(printf '%s' "$MATCH" | cut -d'|' -f2)"
STATUS="$(printf '%s' "$MATCH" | cut -d'|' -f3)"

if [ "$STATUS" = verified ]; then
  echo "== firmware: MagicOS $VER (verified)"
else
  echo "== firmware: MagicOS $VER"
  echo "该系统版本未经验证，确认继续？[y/N]"
  read -r ANSWER
  case "$ANSWER" in
    y|Y) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi
[ -f "$HERE/exploits/$VER/exploit" ] || { echo "missing $HERE/exploits/$VER/exploit (incomplete unpack?)"; exit 1; }

# ---- one attempt ------------------------------------------------------------
try_once() {
  n="$1"
  STAMP="$(date +%Y%m%d_%H%M%S)"
  RD="$RD_ROOT/ksu_run_$STAMP"

  echo "== attempt $n: rundir $RD"
  dev "mkdir -p $RD" || return 1

  echo "== staging payload"
  for f in ksu_loader.tmpl ksu_rules kernelsu.ko load_ko magiskpolicy ksud kmsg_dumper; do
    put "$f" "$RD/$f" || return 1
  done
  if [ "$MODE" = pc ]; then
    $ADB push "$HERE/exploits/$VER/exploit" "$RD/exploit" >/dev/null || return 1
  else
    cp "$HERE/exploits/$VER/exploit" "$RD/exploit" || return 1
  fi
  dev "chmod 755 $RD/exploit $RD/load_ko $RD/magiskpolicy $RD/ksud $RD/kmsg_dumper" || return 1

  # Render the late-load script. hisecd is SIGSTOPped for the load window
  # (its periodic root-procs scan reports the exploit binaries to the TEE,
  # which orders a hard reset) and thawed on every exit path; full ksud
  # bring-up, SELinux re-enforce as the absolute last step.
  sed -e "s|@RUNDIR@|$RD|g" -e "s|@STAMP@|$STAMP|g" \
      -e "s|@FREEZE_HISECD@|1|g" -e "s|@ALLOW_SHELL@|0|g" \
      -e "s|@STAGES@|1|g" -e "s|@ENFORCE@|1|g" \
      "$HERE/ksu_loader.tmpl" > "$HERE/ksu_loader.sh"
  put ksu_loader.sh "$RD/ksu_loader.sh" || { rm -f "$HERE/ksu_loader.sh"; return 1; }
  rm -f "$HERE/ksu_loader.sh"
  dev "chmod 755 $RD/ksu_loader.sh"

  echo "== launching (the exploit logs to $RD/gl.log)"
  dev "nohup env KSU_RUNDIR=$RD $RD/exploit > $RD/gl.log 2>&1 &" || return 1

  # Watch: success / early reboot.
  i=0
  while [ $i -lt 60 ]; do
    sleep 5
    if [ "$MODE" = pc ]; then
      [ "$($ADB get-state 2>/dev/null)" = device ] || {
        echo "== device rebooted mid-run (known miss); waiting for it to come back"
        wait_booted || return 1
        return 2
      }
    fi
    if dev "grep -qi kernelsu /proc/modules"; then
      echo "== KernelSU module LIVE"
      sleep 10   # let the loader finish restore + re-enforce
      dev "tail -5 $RD/ksu_load.log"
      return 0
    fi
    i=$((i + 1))
  done
  echo "== timed out waiting for the module; device log: $RD/gl.log"
  return 2
}

# ---- attempts ----------------------------------------------------------------
n=1
rc=2
while [ $n -le $ATTEMPTS ]; do
  try_once "$n"
  rc=$?
  [ $rc -eq 0 ] && break
  [ $rc -eq 1 ] && { echo "setup error (see above)"; exit 1; }
  n=$((n + 1))
done
[ $rc -eq 0 ] || { echo "gave up after $ATTEMPTS attempts; reboot the device and run again"; exit 1; }

# Old rundirs were only kept for forensics, and this run's loader already
# salvaged any crash evidence out of them at startup (prev_* files).  Keep
# the current one (it holds this run's logs) and drop the rest.
dev "ls -d $RD_ROOT/ksu_run_* 2>/dev/null | grep -v '^$RD\$' | xargs rm -rf 2>/dev/null; rm -f $RD_ROOT/result.done $RD_ROOT/gl_anchor.log $RD_ROOT/gl_root_proof $RD_ROOT/.ksu_patched.ko; true"

echo
echo "== done. Test:"
echo "   adb shell su 0 id        # expect uid=0(root) context=u:r:ksu:s0"
echo "On first use, approve the shell in the KernelSU manager app."
