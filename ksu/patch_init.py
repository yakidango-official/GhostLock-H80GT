#!/usr/bin/env python3
"""Patch KernelSU init.c for ALI-AN00 GhostLock late-load flow."""
import sys

INIT_C = '/home/unpack_img/ksu_build/ksu/kernel/core/init.c'

with open(INIT_C, 'r') as f:
    content = f.read()

# 1. Insert boot_id restore code after module_param(allow_shell, ...)
bootid_code = """
// ALI-AN00: GhostLock sysctl route hijacks boot_id ctl_table.data.
// Kernel-side fix: restore ctl_table.data to the real sysctl_bootid buffer.
// Both are statics stripped from kallsyms, passed as module params.
static unsigned long h80gt_bootid_ctl;
module_param(h80gt_bootid_ctl, ulong, 0);
static unsigned long h80gt_bootid_buf;
module_param(h80gt_bootid_buf, ulong, 0);

static void __init h80gt_restore_bootid(void)
{
    if (!h80gt_bootid_ctl || !h80gt_bootid_buf)
        return;
    // struct ctl_table: data @ offset +8 (device-verified layout)
    *(void **)(h80gt_bootid_ctl + 8) = (void *)h80gt_bootid_buf;
    pr_info("ALI-AN00: boot_id ctl.data restored (ctl=0x%lx buf=0x%lx)\\n",
            h80gt_bootid_ctl, h80gt_bootid_buf);
}

"""

insert_after = 'module_param(allow_shell, bool, 0);'
idx = content.index(insert_after) + len(insert_after)
content = content[:idx] + bootid_code + content[idx:]

# 2. Replace apply_kernelsu_rules() call with h80gt_restore_bootid()
old = '        apply_kernelsu_rules();'
new = """        // ALI-AN00: skip apply_kernelsu_rules() on late load.
        // It swaps live policydb without security_load_policy(), so
        // sidtab_convert() never runs. Rules pre-injected via magiskpolicy.
        h80gt_restore_bootid();"""
content = content.replace(old, new)

# 3. Replace setenforce(true) block
old_enforce = """        if (!getenforce()) {
            pr_info("Permissive SELinux, enforcing\\n");
            setenforce(true);
        }"""
new_enforce = """        // ALI-AN00: do NOT setenforce here. Enforcing is flipped
        // manually as the LAST step of the load flow, after userspace setup.
        if (!getenforce()) {
            pr_info("ALI-AN00: keeping permissive until flow enforces manually\\n");
        }"""
content = content.replace(old_enforce, new_enforce)

with open(INIT_C, 'w') as f:
    f.write(content)

print("OK: init.c patched successfully")
print("Checks:")
for line_no, line in enumerate(content.splitlines(), 1):
    if 'h80gt_bootid' in line or 'ALI-AN00' in line:
        print(f"  L{line_no}: {line.strip()}")