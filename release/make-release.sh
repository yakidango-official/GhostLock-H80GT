#!/usr/bin/env bash
# Assemble the all-firmware release bundle: one archive, every supported
# exploit, a kernel-string manifest, and the shared KSU payload.
# Usage: make-release.sh            (all targets)
#        make-release.sh <target>.. (subset, for tests)
set -eu
cd "$(dirname "$0")/.."

# Device-verified firmwares; everything else ships as untested.
VERIFIED=" 8.0.0.128 8.0.0.160 9.0.0.157 9.0.0.200SP1 9.0.0.220SP2 9.0.0.230 "

if [ $# -gt 0 ]; then
  TARGETS="$*"
else
  TARGETS=$(ls -d exploit/src/targets/annap-AGT-AN00_*/ | sed 's#.*annap-AGT-AN00_##;s#/$##' | sort)
fi

OUT_ROOT="build/release/ghostlock"
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT/exploits"

: > "$OUT_ROOT/manifest"
for VER in $TARGETS; do
  T="annap-AGT-AN00_${VER}"
  DIR="exploit/src/targets/$T"
  [ -f "$DIR/target.h" ] || { echo "unknown target $T"; exit 1; }
  ./exploit/docker-build.sh "PROJECT=$T" >/dev/null
  BIN="exploit/build/$T/bin/exploit_static"
  [ -f "$BIN" ] || { echo "build failed for $T"; exit 1; }
  mkdir -p "$OUT_ROOT/exploits/$VER"
  cp "$BIN" "$OUT_ROOT/exploits/$VER/exploit"
  chmod 755 "$OUT_ROOT/exploits/$VER/exploit"

  KERNEL="$(grep -m1 -o '5\.10\.[0-9a-z-]*android12-9-[a-z0-9]*' "$DIR/target.h" || true)"
  [ -n "$KERNEL" ] || { echo "cannot read kernel string from $T/target.h"; exit 1; }
  case "$VERIFIED" in
    *" $VER "*) STATUS=verified ;;
    *) STATUS=untested ;;
  esac
  echo "$KERNEL|$VER|$STATUS" >> "$OUT_ROOT/manifest"
done

cp release/setup.sh ksu/tools/ksu_loader.tmpl ksu/tools/ksu_rules \
   ksu/tools/load_ko ksu/tools/magiskpolicy \
   ksu/tools/ksud ksu/tools/kmsg_dumper "$OUT_ROOT/"
cp ksu/tools/kernelsu.ko "$OUT_ROOT/kernelsu.ko"
chmod 755 "$OUT_ROOT/setup.sh"

# Pairing guard: every module param the loader passes must exist in the .ko.
# A stale module (params renamed on one side only) loads fine and the boot_id
# restore silently no-ops — the only symptom is on the device. Fail here.
# Extraction: param names appear as name=VALUE inside KSU_PARAMS assignments
# anywhere on the line (no ^ anchor: one line starts with `if ...; then`).
PARAMS=$(grep 'KSU_PARAMS=' ksu/tools/ksu_loader.tmpl | grep -oE '[a-z_0-9]+=' | tr -d '=' | sort -u)
[ -n "$PARAMS" ] || { echo "module-param extraction yielded NOTHING (regex drifted?) — guard would be a no-op"; exit 1; }
for p in $PARAMS; do
  grep -aq "$p" ksu/tools/kernelsu.ko \
    || { echo "loader passes module param -$p- but kernelsu.ko does not define it"; exit 1; }
done

tar -C build/release -czf "build/release/ghostlock.tar.gz" ghostlock
( cd build/release && shasum -a 256 ghostlock.tar.gz > ghostlock.tar.gz.sha256 )
echo "built: build/release/ghostlock.tar.gz ($(grep -c . "$OUT_ROOT/manifest") targets)"
