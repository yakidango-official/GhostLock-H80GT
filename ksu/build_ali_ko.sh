#!/bin/bash
# Build KernelSU .ko for ALI-AN00 in WSL Ubuntu-22.04
set -ex

KERNEL_SRC=/mnt/f/hdc_magic/MagicOS8.0-ROM-Ali_MagicOS8.0_Opensource/Code_Opensource/Code_Opensource/kernel
BUILD_DIR=/home/unpack_img/ksu_build
KERNEL_DST=/home/unpack_img/kernel_ali

# Step 1: Copy kernel source (skip if already done)
if [ ! -f "$KERNEL_DST/Makefile" ]; then
  echo "=== Copying kernel source ==="
  rm -rf "$KERNEL_DST"
  cp -r "$KERNEL_SRC" "$KERNEL_DST"
  echo "Kernel source copied"
else
  echo "=== Kernel source exists, skipping copy ==="
fi

# Step 2: Copy device config
cp "$BUILD_DIR/.config" "$KERNEL_DST/.config"
echo "Config copied"

# Step 3: Stub the kallsyms whitelist (path from device config)
WHITELIST_PATH=/ci/workspace/magic_chipset_pipeline_release/china_performance_compile/src/increment/sourcecode/kernel_platform/out/msm-waipio-parrot-perf/gki_kernel/common
mkdir -p "$WHITELIST_PATH"
touch "$WHITELIST_PATH/abi_symbollist.raw"
echo "Whitelist stub created"

# Step 4: Fix config for clang-14 + 5.10 compatibility
cd "$KERNEL_DST"
TOOLS="CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTCC=clang HOSTCXX=clang++ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1"

# clang-14 sets mstack-protector-guard-offset='' on 5.10, breaking every TU.
# Disable per-task stack protector; the .ko doesn't need it.
sed -i 's/CONFIG_STACKPROTECTOR_PER_TASK=y/# CONFIG_STACKPROTECTOR_PER_TASK is not set/' .config
echo "STACKPROTECTOR_PER_TASK disabled"

make $TOOLS olddefconfig 2>&1 | tail -3
echo "=== Config check ==="
grep -E "CONFIG_LTO_CLANG=|CONFIG_CFI_CLANG=|CONFIG_MODULES=|CONFIG_KALLSYMS=" .config

# Step 5: modules_prepare
echo "=== modules_prepare ==="
make $TOOLS modules_prepare -j$(nproc) 2>&1 | tail -5
echo "modules_prepare done"

# Step 6: Build selinux headers
echo "=== selinux headers ==="
make $TOOLS security/selinux/ -j$(nproc) 2>&1 | tail -3 || true

# Step 7: Empty Module.symvers
: > "$KERNEL_DST/Module.symvers"
echo "Module.symvers emptied (0 bytes)"

# Step 8: Build KernelSU
echo "=== Building KernelSU ==="
KSU_DIR="$BUILD_DIR/ksu"
make -C "$KERNEL_DST" M="$KSU_DIR/kernel" $TOOLS CONFIG_KSU=m KCFLAGS=-Wno-error modules -j$(nproc) 2>&1 | tail -10

echo "=== Result ==="
ls -la "$KSU_DIR/kernel/kernelsu.ko"
echo "BUILD DONE"