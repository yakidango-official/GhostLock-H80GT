#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

int main(int argc, char *argv[]) {
    /* setresuid to all three ids; required for some shells that check all three */
    if (setresuid(0, 0, 0) != 0) {
        perror("setresuid");
        return 1;
    }
    if (setresgid(0, 0, 0) != 0) {
        perror("setresgid");
        return 1;
    }
    if (setuid(0) != 0) {
        perror("setuid");
        return 1;
    }

    /* set HOME and PATH so shell behaves normally as root */
    setenv("HOME", "/data/local/tmp", 1);
    setenv("PATH", "/system/bin:/vendor/bin:/sbin", 1);
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
