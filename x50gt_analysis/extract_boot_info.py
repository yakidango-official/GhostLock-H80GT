#!/usr/bin/env python3
"""Extract boot.img information and search for kernel version/security features"""

import sys
import os

IMG_DIR = r"C:\Users\chipsemi001\Desktop\beichenxiazai\荣耀卡刷包\X50GT\8-7\ALP-AN00 7.2.0.162(CNC00E155R6P3)_Firmware_Magic OS 7.2_0501ACKK\Software\dload\update_sd_base\image"

def search_strings(filepath, patterns, context=50):
    """Search for patterns in binary file"""
    print(f"\n=== Searching {os.path.basename(filepath)} ===")
    with open(filepath, 'rb') as f:
        data = f.read()

    results = {}
    for pattern in patterns:
        pattern_bytes = pattern.encode('utf-8') if isinstance(pattern, str) else pattern
        positions = []
        start = 0
        while True:
            pos = data.find(pattern_bytes, start)
            if pos == -1:
                break
            # Get context around the match
            ctx_start = max(0, pos - context)
            ctx_end = min(len(data), pos + len(pattern_bytes) + context)
            context_data = data[ctx_start:ctx_end]
            # Try to decode as UTF-8
            try:
                text = context_data.decode('utf-8', errors='ignore')
                # Clean up non-printable chars
                text = ''.join(c if c.isprintable() or c in '\n\r\t' else '.' for c in text)
                positions.append((pos, text))
            except:
                positions.append((pos, repr(context_data[:100])))
            start = pos + 1
        results[pattern] = positions

    return results

def main():
    boot_img = os.path.join(IMG_DIR, "boot.img")
    vendor_boot_img = os.path.join(IMG_DIR, "vendor_boot.img")

    # Patterns to search for
    patterns = [
        # Kernel version
        "Linux version",
        "5.10.",
        "5.15.",
        "6.1.",
        # Security features
        "selinux",
        "CONFIG_SECURITY_SELINUX",
        "CONFIG_HARDENED_USERCOPY",
        "CONFIG_FORTIFY_SOURCE",
        "CONFIG_STRICT_KERNEL_RWX",
        # Kernel features
        "CONFIG_KALLSYMS",
        "CONFIG_MODULE_SIG",
        "CONFIG_LOCKDOWN",
        # Qualcomm
        "qcom",
        "sm6450",  # Snapdragon chip
        # Android
        "androidboot",
        "androidboot.verifiedbootstate",
        "androidboot.selinux",
    ]

    # Search boot.img
    if os.path.exists(boot_img):
        results = search_strings(boot_img, patterns)
        for pattern, positions in results.items():
            if positions:
                print(f"\n[{pattern}] Found {len(positions)} matches:")
                for pos, text in positions[:3]:  # Show first 3
                    print(f"  @ 0x{pos:x}: {text[:150]}")

    # Search vendor_boot.img
    if os.path.exists(vendor_boot_img):
        results = search_strings(vendor_boot_img, patterns)
        for pattern, positions in results.items():
            if positions:
                print(f"\n[{pattern}] Found {len(positions)} matches:")
                for pos, text in positions[:3]:
                    print(f"  @ 0x{pos:x}: {text[:150]}")

if __name__ == "__main__":
    main()
