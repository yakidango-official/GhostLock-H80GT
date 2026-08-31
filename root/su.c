#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/*
 * Minimal static ARM64 "su" for Honor X50 (ALI-AN00) after GhostLock exploit.
 *
 * v2: switches SELinux context to "u:r:kernel:s0" before exec sh,
 *     so it has full kernel-domain access (bypasses Honor's seclabel
 *     on /data and other locked dirs even when SELinux is Permissive).
 *
 * Requires:
 *   - SELinux Permissive (exploit sets it)
 *   - sig_enforce=N (exploit flips it)
 *   - /data mounted without nosuid
 *   - file owned by root:root with mode 6755
 *
 * Usage:
 *   /data/local/tmp/su              # interactive root shell
 *   /data/local/tmp/su -c 'cmd'     # single root command
 */

int main(int argc, char *argv[]) {
    if (setresuid(0, 0, 0) != 0) { perror("setresuid"); return 1; }
    if (setresgid(0, 0, 0) != 0) { perror("setresgid"); return 1; }
    if (setuid(0) != 0)           { perror("setuid");    return 1; }

    /* Switch SELinux context to kernel domain (Magisk/KernelSU trick).
     * libselinux is in libc on Android; declare extern to avoid -lselinux. */
    extern int setcon(const char *ctx);
    if (setcon("u:r:kernel:s0") != 0) {
        /* setcon may fail if /sys/fs/selinux/enforce is 1 — but we are
         * already in Permissive so this is just a fallback path */
        perror("setcon(kernel)");
    }

    setenv("HOME", "/data/local/tmp", 1);
    setenv("USER", "root", 1);

    const char *shell = "/system/bin/sh";
    if (argc > 1 && strcmp(argv[1], "-c") == 0 && argc > 2) {
        char *sh_argv[] = { (char *)shell, "-c", argv[2], NULL };
        execv(shell, sh_argv);
    } else {
        char *sh_argv[] = { (char *)shell, NULL };
        execv(shell, sh_argv);
    }
    perror("execv");
    return 1;
}