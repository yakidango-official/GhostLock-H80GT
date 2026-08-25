#!/usr/bin/env bash
# Assemble a per-firmware release bundle from a clean build:
#   bin  setup.sh  ksu_loader.tmpl  ksu_rules  release.info  ksu-libs...
# Usage: make-release.sh <target>   (e.g. annap-AGT-AN00_9.0.0.220SP2)
set -eu
cd "$(dirname "$0")/.."

TARGET="${1:?usage: make-release.sh <target>}"
DIR="exploit/src/targets/$TARGET"
[ -f "$DIR/target.h" ] || { echo "unknown target $TARGET"; exit 1; }

VER="${TARGET#annap-AGT-AN00_}"
KERNEL="$(grep -m1 -o '5\.10\.[0-9a-z-]*android12-9-[a-z0-9]*' "$DIR/target.h" || true)"
[ -n "$KERNEL" ] || { echo "cannot read kernel string from target.h"; exit 1; }

./exploit/docker-build.sh "PROJECT=$TARGET" >/dev/null
BIN="exploit/build/$TARGET/bin/exploit_ondevice_static"
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

OUT="build/release/$VER"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$BIN" "$OUT/exploit"
chmod 755 "$OUT/exploit"
cp release/setup.sh ksu/tools/ksu_loader.tmpl ksu/tools/ksu_rules \
   ksu/tools/load_ko ksu/tools/magiskpolicy \
   ksu/tools/ksud ksu/tools/kmsg_dumper "$OUT/"
cp ksu/tools/kernelsu_h80gt.ko "$OUT/kernelsu.ko"
chmod 755 "$OUT/setup.sh"
cat > "$OUT/release.info" <<EOF
MAGICOS="$VER"
KERNEL="$KERNEL"
EOF

tar -C build/release -czf "build/release/ghostlock-$VER.tar.gz" "$VER"
( cd build/release && shasum -a 256 "ghostlock-$VER.tar.gz" > "ghostlock-$VER.tar.gz.sha256" )
echo "built: build/release/ghostlock-$VER.tar.gz"
