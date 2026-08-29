#!/bin/sh
# Build a custom kernelsu.ko against the Honor 80 GT's actual kernel:
#   the matching MagicOS source tree + the target firmware's /proc/config.gz,
#   in a native arm64
#   Debian container (clang-14). This fixes the stock GKI .ko's struct-offset
#   drift (task_struct.cred 0x780->0x7b8, inode.i_fsnotify_marks 0x290->0x288).
#
# Everything except KERNEL_SRC is auto-staged into ksu/.build/:
#   .config                  <- repo's kernel.config (device config.gz)
#   ksu/                     <- auto-cloned KernelSU v3.3.0 (with .git, patch applied)
#   kallsyms_names           <- repo's device symbol-name list (validation)
#
# Output: ksu/.build/kernelsu.ko
set -eu

container_name="gl-ksu-build"
# one-time migration from the pre-rename container (keeps the build cache)
if ! docker container inspect gl-ksu-build >/dev/null 2>&1; then
    docker container inspect honor80gt-ksu-build >/dev/null 2>&1 \
        && docker rename honor80gt-ksu-build gl-ksu-build
fi
repo_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
stage_dir="${KSU_BUILD_DIR:-$repo_dir/.build}"
mkdir -p "$stage_dir"

# KERNEL_SRC: an Honor MagicOS opensource kernel tree whose sublevel matches
# the target firmware (the Code_Opensource/kernel directory of the AGT-AN00
# package): the MagicOS 8.0 tree for 8.0.0.128 (5.10.168), the MagicOS 9.0
# tree for 8.0.0.160 (5.10.209).
if [ -z "${KERNEL_SRC:-}" ]; then
    echo "ERROR: set KERNEL_SRC to the MagicOS opensource kernel tree" >&2
    echo "  (the Code_Opensource/kernel directory of the AGT-AN00 package)." >&2
    exit 1
fi
kernel_src="$(CDPATH= cd -- "$KERNEL_SRC" && pwd)"

# KSU_DEVICE_CONFIG: the target firmware's kernel config (its /proc/config.gz,
# or extract-ikconfig output from its boot.img). Defaults to the 9.0.0.230
# (5.10.236) device config shipped in this repo (identical across the 5.10.236
# builds); the released kernelsu.ko
# (8.0/9.0) is always built with it, so a rebuild from the repo reproduces
# the exact same file. The 8.0/9.0 firmwares' configs compile to identical
# struct layouts, so that .ko covers all of them.
cp "${KSU_DEVICE_CONFIG:-$repo_dir/kernel.config}" "$stage_dir/.config"
cp "${KSU_KALLSYMS_NAMES:-$repo_dir/kallsyms_names}" "$stage_dir/kallsyms_names.txt" 2>/dev/null || true
cp "$repo_dir/build_inner.sh" "$repo_dir/empty_versions.py" "$stage_dir/"

# KernelSU v3.3.0 checkout. .git must be present and at the tag so
# KSU_VERSION = 30000 + git rev-list --count HEAD = 32525 (manager version check).
if [ ! -d "$stage_dir/ksu/.git" ]; then
    rm -rf "$stage_dir/ksu"
    git clone https://github.com/tiann/KernelSU "$stage_dir/ksu"
    git -C "$stage_dir/ksu" checkout -q v3.3.0
fi
# The staged clone persists across builds and may carry an OLDER patch set
# (stale apply state would fail --check and silently build old source).
# Reset every file the patches touch to pristine, then apply in order —
# later patches' context assumes the earlier ones are in. Fail loudly on any
# mismatch.
# supercall/dispatch.c + uapi/supercall.h are reset even though no patch
# touches them now: legacy staged clones may still carry hand-applied pid
# cursor edits (the superseded feature) — reset guarantees they never leak
# back into a build.
for f in kernel/core/init.c kernel/selinux/sepolicy.c kernel/selinux/rules.c \
         kernel/supercall/dispatch.c uapi/supercall.h; do
    git -C "$stage_dir/ksu" checkout -- "$f"
done
for p in init-bootid.patch sepolicy-dyn-len.patch selinux-hide-backup.patch; do
    if ! git -C "$stage_dir/ksu" apply --check "$repo_dir/$p" 2>/dev/null; then
        echo "ERROR: $p does not apply to the KernelSU checkout" >&2
        exit 1
    fi
    git -C "$stage_dir/ksu" apply "$repo_dir/$p"
done

docker rm -f "$container_name" >/dev/null 2>&1 || true

docker run --rm \
    --name "$container_name" \
    --hostname "$container_name" \
    --label "com.cybermeowfia.purpose=ksu-ko-build" \
    --stop-timeout 10 \
    --mount "type=bind,src=$kernel_src,dst=/kernel-src,readonly" \
    --mount "type=bind,src=$stage_dir,dst=/build" \
    debian:bookworm \
    sh /build/build_inner.sh
