#include "common.h"

// Standalone launcher for the exploit (device adb testing).
int main(int argc, char **argv) {
  util_set_argv0(argv[0]);
  return run_exploit(argc, argv);
}
