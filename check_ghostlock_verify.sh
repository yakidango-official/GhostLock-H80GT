#!/usr/bin/env bash
set -euo pipefail

echo "[verify] start"
echo

echo "[1] exploit bin"
ls -la exploit/build/parrot-ALI-AN00_8.0.0.181/bin/

echo

echo "[2] target files"

if [ -f "ksu/tools/kernelsu_h80gt.ko" ]; then
  echo "-- ksu/tools/kernelsu_h80gt.ko"
  ls -l ksu/tools/kernelsu_h80gt.ko
  if command -v file >/dev/null 2>&1; then
    file ksu/tools/kernelsu_h80gt.ko
  else
    printf "magic: "
    od -An -tx1 -N 8 ksu/tools/kernelsu_h80gt.ko
    echo
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum ksu/tools/kernelsu_h80gt.ko
  else
    echo "sha256sum: unavailable"
  fi
else
  echo "-- MISSING: ksu/tools/kernelsu_h80gt.ko"
fi

if [ -f "ksu/tools/load_ko" ]; then
  echo "-- ksu/tools/load_ko"
  ls -l ksu/tools/load_ko
  if command -v file >/dev/null 2>&1; then
    file ksu/tools/load_ko
  else
    printf "magic: "
    od -An -tx1 -N 8 ksu/tools/load_ko
    echo
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum ksu/tools/load_ko
  else
    echo "sha256sum: unavailable"
  fi
else
  echo "-- MISSING: ksu/tools/load_ko"
fi

if [ -f "ksu/tools/ksud" ]; then
  echo "-- ksu/tools/ksud"
  ls -l ksu/tools/ksud
  if command -v file >/dev/null 2>&1; then
    file ksu/tools/ksud
  else
    printf "magic: "
    od -An -tx1 -N 8 ksu/tools/ksud
    echo
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum ksu/tools/ksud
  else
    echo "sha256sum: unavailable"
  fi
else
  echo "-- MISSING: ksu/tools/ksud"
fi

echo

echo "[3] env"
uname -a 2>/dev/null || true
echo "[DONE]"
