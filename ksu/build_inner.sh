#!/bin/sh
# Runs INSIDE the debian:bookworm (native arm64) container.
# Builds KernelSU as an external module against the MagicOS kernel
# source + the device's exact /proc/config.gz, so every struct offset
# matches the shipping Honor kernel (task_struct.cred, inode.i_fsnotify_marks,
# fsnotify, selinux, ...).
set -eux

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    clang lld llvm \
    gcc gcc-aarch64-linux-gnu \
    make bc bison flex libelf-dev libssl-dev \
    python3 rsync git kmod xz-utils ca-certificates

# Fresh writable copies (kernel-src is a read-only bind mount).
rm -rf /kernel /ksu
mkdir -p /kernel /ksu
rsync -a /kernel-src/ /kernel/
rsync -a /build/ksu/ /ksu/          # keep .git -> KSU_VERSION=30000+2525=32525
cp /build/.config /kernel/.config   # device /proc/config.gz, verbatim

cd /kernel
# LLVM=1 is REQUIRED: arch/Kconfig HAS_LTO_CLANG depends on $(success,test $(LLVM) -eq 1).
# Without it olddefconfig silently drops LTO_CLANG/CFI_CLANG/CFI_CLANG_SHADOW.
TOOLS="CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTCC=clang HOSTCXX=clang++ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1"

make $TOOLS olddefconfig

# CONFIG_TRIM_UNUSED_KSYMS=y reads CONFIG_UNUSED_KSYMS_WHITELIST, an absolute
# path on Honor's CI build host. It only affects unused-export trimming of
# vmlinux (irrelevant to an external module) — stub the file.
mkdir -p /ci/workspace/magic_chipset_pipeline_release/china_performance_compile/src/increment/sourcecode/kernel_platform/out/msm-waipio-waipio-perf/gki_kernel/common
: > /ci/workspace/magic_chipset_pipeline_release/china_performance_compile/src/increment/sourcecode/kernel_platform/out/msm-waipio-waipio-perf/gki_kernel/common/abi_symbollist.raw

make $TOOLS modules_prepare -j"$(nproc)"

# SELinux generated headers (flask.h / av_permissions.h) are produced only when
# the selinux dir is built; KSU includes headers under security/selinux.
make $TOOLS security/selinux/ -j"$(nproc)" || true

# No real Module.symvers (that would need a full vmlinux link). modpost then
# emits crc=0 entries into __versions; we empty the section post-build, which
# this kernel's check_version() treats as warn-once + PASS for every symbol
# (and same_magic() skips the release string when __versions exists).
: > /kernel/Module.symvers

# CONFIG_WERROR=y would make clang-14's new warnings fatal on 5.10 sources.
# Patched init.c: do NOT swap the live sepolicy (a late load on a running
# system would orphan every running domain's SID) and do NOT re-enable
# enforcing (the flow enforces manually as the last step). App profiles stay
# ENABLED (default KSU behavior) — CONFIG_KSU_DISABLE_POLICY=y would make
# GET/SET_APP_PROFILE return -EOPNOTSUPP ("更新 App Profile 失败" in manager).
make -C /kernel M=/ksu/kernel $TOOLS CONFIG_KSU=m KCFLAGS=-Wno-error modules -j"$(nproc)"

ls -la /ksu/kernel/kernelsu.ko

python3 /build/empty_versions.py /ksu/kernel/kernelsu.ko /build/kernelsu.ko
llvm-nm -u /build/kernelsu.ko 2>/dev/null | awk '{print $NF}' | sort -u > /build/ko_undefsyms.txt || true

echo "=== undefined symbols not present in device kallsyms (need injection) ==="
if [ -f /build/kallsyms_names.txt ]; then
    LC_ALL=C sort -u /build/kallsyms_names.txt > /build/ks_names.txt || true
    comm -23 /build/ko_undefsyms.txt /build/ks_names.txt > /build/ko_missing_syms.txt || true
    cat /build/ko_missing_syms.txt || true
else
    echo "(no device symbol-name list — skipped; documented answer: commit_creds)"
fi

echo "=== BUILD DONE: /build/kernelsu.ko ==="
