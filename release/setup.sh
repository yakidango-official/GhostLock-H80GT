#!/usr/bin/env bash
# GhostLock one-shot jailbreak for the HONOR 80 GT (AGT-AN00).
#
# Runs on the HOST. Everything the device needs is in this bundle:
#   exploit         per-firmware exploit binary
#   ksu_loader.tmpl KSU late-load script template
#   ksu/            KernelSU module + loader tools
#
# Usage:  ./setup.sh [adb-serial]
# The script is restartable: if the device reboots mid-run (a known
# low-probability miss), it waits for the device and retries, up to
# 3 attempts, in a fresh run directory each time.
set -u

SERIAL="${1:-}"
RD_ROOT=/data/local/tmp
ATTEMPTS=3
command -v adb >/dev/null || { echo "adb not found in PATH"; exit 1; }

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
[ -x "$HERE/exploit" ] || { echo "missing $HERE/exploit (wrong bundle?)"; exit 1; }

# ---- bundle identity ------------------------------------------------------
. "$HERE/release.info" || exit 1
: "${MAGICOS:?}" "${KERNEL:?}"

adb() {
  if [ -n "$SERIAL" ]; then command adb -s "$SERIAL" "$@"; else command adb "$@"; fi
}

wait_device() {
  local i
  for i in $(seq 1 60); do
    [ "$(adb get-state 2>/dev/null)" = "device" ] && return 0
    sleep 5
  done
  return 1
}

try_once() {
  local n="$1" RD STAMP
  STAMP="$(date +%Y%m%d_%H%M%S)"
  RD="$RD_ROOT/ksu_run_$STAMP"

  echo "== attempt $n: rundir $RD"
  adb shell "mkdir -p $RD" || return 1

  echo "== pushing payload"
  adb push "$HERE/exploit" "$RD/xpl" >/dev/null || return 1
  for f in ksu_loader.tmpl ksu_rules kernelsu.ko load_ko magiskpolicy ksud kmsg_dumper; do
    adb push "$HERE/$f" "$RD/$f" >/dev/null || return 1
  done
  adb shell "chmod 755 $RD/xpl $RD/load_ko $RD/magiskpolicy $RD/ksud $RD/kmsg_dumper" || return 1

  # Render the late-load script (no hisecd freeze; full bring-up; re-enforce
  # as the last step).
  sed -e "s|@RUNDIR@|$RD|g" -e "s|@STAMP@|$STAMP|g" \
      -e "s|@FREEZE_HISECD@|0|g" -e "s|@ALLOW_SHELL@|0|g" \
      -e "s|@STAGES@|1|g" -e "s|@ENFORCE@|1|g" \
      "$HERE/ksu_loader.tmpl" > "$HERE/ksu_loader.sh"
  adb push "$HERE/ksu_loader.sh" "$RD/ksu_loader.sh" >/dev/null || return 1
  adb shell "chmod 755 $RD/ksu_loader.sh"
  rm -f "$HERE/ksu_loader.sh"

  echo "== launching (never pipe the exploit; it logs to $RD/gl.log)"
  adb shell "nohup env KSU_RUNDIR=$RD $RD/xpl > $RD/gl.log 2>&1 &" || return 1

  # ---- watch: success / early reboot --------------------------------------
  local i
  for i in $(seq 1 60); do
    sleep 5
    if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
      echo "== device rebooted mid-run (known miss); waiting for it to come back"
      wait_device || return 1
      return 2   # retryable
    fi
    if adb shell "grep -qi kernelsu /proc/modules" 2>/dev/null; then
      echo "== KernelSU module LIVE"
      sleep 10   # let the loader finish restore + re-enforce
      adb shell "cat $RD/ksu_load.log" 2>/dev/null | tail -5
      return 0
    fi
  done
  echo "== timed out waiting for the module; device log: $RD/gl.log"
  return 2
}

# ---- preflight -------------------------------------------------------------
echo "== GhostLock for MagicOS $MAGICOS (kernel $KERNEL)"
wait_device || { echo "no device"; exit 1; }
K="$(adb shell uname -r | tr -d '\r')"
if [ "$K" != "$KERNEL" ]; then
  echo "FIRMWARE MISMATCH: device runs '$K', this bundle is for '$KERNEL'."
  echo "Flashing the wrong build can crash the kernel — get the bundle for your version."
  exit 1
fi
echo "== firmware matches"

# ---- attempts ---------------------------------------------------------------
n=1
while [ "$n" -le "$ATTEMPTS" ]; do
  try_once "$n"
  rc=$?
  [ $rc -eq 0 ] && break
  [ $rc -eq 1 ] && { echo "setup error (see above)"; exit 1; }
  n=$((n + 1))
done
[ $rc -eq 0 ] || { echo "gave up after $ATTEMPTS attempts; reboot the device and retry"; exit 1; }

echo
echo "== done. Test:"
echo "   adb shell su 0 id        # expect uid=0(root) context=u:r:ksu:s0"
echo "On first use, approve the shell in the KernelSU manager app."
