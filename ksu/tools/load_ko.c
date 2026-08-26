// load_ko.c — minimal kernelsu.ko loader for the Honor 80 GT.
//
// Replicates KernelSU's ksuinit::load_module: the .ko has SHN_UNDEF symbols
// the kernel's module loader can't resolve because Honor (a) strips
// commit_creds/__cfi_slowpath/etc from /proc/kallsyms AND (b) doesn't EXPORT
// the SELinux internals (avc_has_perm, avtab_*, sidtab_*, security_*) the .ko
// hooks. Resolve every SHN_UNDEF symbol against /proc/kallsyms (which lists
// ALL kernel symbols, not just exported ones) and rewrite each entry to
// SHN_ABS with the runtime address; the loader then treats them as absolute
// (no __ksymtab lookup) and applies relocations directly.
//
// We read /proc/kallsyms through a bind-mounted FAKE (real kallsyms captured
// with kptr_restrict relaxed + the stripped symbols PREPENDED at their true
// runtime addrs). sig_enforce must already be 0 (the GhostLock arb-write).
//
// Build (NDK):  aarch64-linux-android31-clang -static -O2 -o load_ko load_ko.c
// Usage (device, as root via the GhostLock rooted anchor):
//   mount --bind /data/local/tmp/fake_kallsyms /proc/kallsyms
//   ./load_ko /data/local/tmp/ksu.ko
//
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <elf.h>

#ifndef SHN_UNDEF
#define SHN_UNDEF 0
#endif
#ifndef SHN_ABS
#define SHN_ABS 0xfff1
#endif

// arm64 syscall numbers + module-load flags (NDK asm-generic/unistd.h, linux/module.h)
#ifndef SYS_finit_module
#define SYS_finit_module 273
#endif
#ifndef MODULE_INIT_IGNORE_MODVERSIONS
#define MODULE_INIT_IGNORE_MODVERSIONS 1
#endif
#ifndef MODULE_INIT_IGNORE_VERMAGIC
#define MODULE_INIT_IGNORE_VERMAGIC 2
#endif

// printf + fflush + fsync so every line hits disk BEFORE a possible
// kernel-triggered reboot (/data/local/tmp survives it).
#define LOG(...) do { printf(__VA_ARGS__); fflush(stdout); fsync(STDOUT_FILENO); } while(0)

// open-addressing hash set of undefined symbol names to resolve;
// value = index into the sym array, -1 = empty.
#define HSIZE 4096
static long htab[HSIZE];
static char **hname;   // parallel: symbol name per slot
static long  haddr[HSIZE]; // resolved addr (0 = unresolved)

static unsigned hhash(const char *s){ unsigned long h=5381; int c; while((c=*s++)) h=h*33+c; return h & (HSIZE-1); }

int main(int argc, char **argv){
  setvbuf(stdout, NULL, _IONBF, 0);   // unbuffered: survive a kernel-triggered reboot
  setvbuf(stderr, NULL, _IONBF, 0);
  if (argc < 2){ LOG("usage: %s <module.ko> [params]\n", argv[0]); return 2; }
  const char *path = argv[1];
  const char *params = argc > 2 ? argv[2] : "";

  // ---- read the .ko into memory ----
  int fd = open(path, O_RDONLY);
  if (fd < 0){ LOG("open %s: %m\n", path); return 2; }
  struct stat st; if (fstat(fd,&st)){ LOG("fstat: %m\n"); return 2; }
  size_t len = st.st_size;
  uint8_t *buf = malloc(len);
  if (!buf){ LOG("malloc %zu: %m\n", len); return 2; }
  ssize_t off=0; while(off<(ssize_t)len){ ssize_t r=read(fd,buf+off,len-off); if(r<=0){LOG("read: %m\n");return 2;} off+=r; }
  close(fd);
  LOG("[*] read %s (%zu bytes)\n", path, len);

  if (len < sizeof(Elf64_Ehdr)){ LOG("too small\n"); return 2; }
  Elf64_Ehdr *eh = (Elf64_Ehdr*)buf;
  if (memcmp(eh->e_ident, ELFMAG, SELFMAG)){ LOG("not ELF\n"); return 2; }
  if (eh->e_machine != EM_AARCH64){ LOG("not an aarch64 module (e_machine=%d)\n", eh->e_machine); return 2; }
  Elf64_Shdr *sh = (Elf64_Shdr*)(buf + eh->e_shoff);

  // ---- find .symtab + its .strtab ----
  Elf64_Shdr *symtab=NULL; char *strtab=NULL;
  for (int i=0;i<eh->e_shnum;i++){
    if (sh[i].sh_type==SHT_SYMTAB){ symtab=&sh[i]; strtab=(char*)(buf+sh[sh[i].sh_link].sh_offset); break; }
  }
  if (!symtab){ LOG("no symtab\n"); return 2; }
  size_t nsyms = symtab->sh_size / sizeof(Elf64_Sym);
  Elf64_Sym *syms = (Elf64_Sym*)(buf + symtab->sh_offset);
  LOG("[*] symtab: %zu symbols\n", nsyms);

  // ---- collect undefined symbol names into the hash set ----
  // kasan_flag_enabled alias: the custom kernelsu.ko does NOT reference
  // it, but a stock inline-KASAN GKI .ko does while this kernel has
  // CONFIG_KASAN=n. Resolving it to CODE (ret stub, first byte != 0) would
  // make KASAN instrumentation touch the unmapped shadow -> panic. Aliasing
  // to empty_zero_page (reads 0) makes it a no-op.
  for (int i=0;i<HSIZE;i++){ htab[i]=-1; haddr[i]=0; }
  hname = calloc(HSIZE, sizeof(char*));
  int nundef=0;
  for (size_t i=0;i<nsyms;i++){
    if (syms[i].st_shndx==SHN_UNDEF && syms[i].st_name){
      const char *nm = strtab + syms[i].st_name;
      if (!*nm) continue;
      const char *rn = nm;
      if (!strcmp(nm,"kasan_flag_enabled")) rn = "empty_zero_page";  // KASAN-off alias
      unsigned h=hhash(rn);
      while(htab[h]!=-1){ if(!strcmp(hname[h],rn)) goto dup; h=(h+1)&(HSIZE-1); }
      htab[h]=(long)i; hname[h]=(char*)rn; haddr[h]=0; nundef++;
      dup:;
    }
  }
  LOG("[*] undefined symbols to resolve: %d\n", nundef);

  // ---- read /proc/kallsyms (the bind-mounted fake) and resolve ----
  FILE *kf = fopen("/proc/kallsyms","r");
  if (!kf){ LOG("open /proc/kallsyms: %m\n"); return 2; }
  char line[512];
  long nresolved=0;
  while (fgets(line, sizeof line, kf)){
    // <addr> <type> <name>  — kernel symbols; module symbols follow, TAB-
    // separated. Kernel symbols come first, so stop at the first TAB line.
    char *p=line;
    uint64_t addr = strtoull(p, &p, 16);
    while(*p==' ') p++;
    p++;                       // symbol type letter (unused)
    while(*p==' ') p++;
    char *name=p;
    char *end=name;
    while(*end && *end!='\n' && *end!='\t' && *end!=' ') end++;
    int is_module = (*end=='\t');
    *end=0;
    if (!*name) continue;
    if (is_module){ /* module symbol region begins */ break; }
    unsigned h=hhash(name);
    while(htab[h]!=-1){
      if(!strcmp(hname[h],name)){ if(haddr[h]==0){ haddr[h]=(long)addr; nresolved++; } break; }
      h=(h+1)&(HSIZE-1);
    }
  }
  fclose(kf);
  LOG("[*] resolved %ld/%d from /proc/kallsyms\n", nresolved, nundef);

  // ---- patch each undefined symbol to SHN_ABS with its resolved address ----
  int missing=0;
  for (int h=0;h<HSIZE;h++){
    if (htab[h]==-1) continue;
    long si = htab[h];
    if (haddr[h]==0){ LOG("[!] UNRESOLVED: %s\n", hname[h]); missing++; continue; }
    syms[si].st_shndx = SHN_ABS;
    syms[si].st_value = (uint64_t)haddr[h];
    syms[si].st_size  = 0;
  }
  LOG("[*] patched %d symbols to SHN_ABS; %d unresolved\n", nundef-missing, missing);
  if (missing){ LOG("[-] %d symbols unresolved — aborting (would fail init_module)\n", missing); return 3; }

  // ---- load: init_module with flags=0 (NO IGNORE_*) ----
  // IGNORE_VERMAGIC routes to try_to_force_load() which, without
  // CONFIG_MODULE_FORCE_LOAD, returns a SILENT -ENOEXEC (source: 5.10
  // kernel/module.c) — IGNORE flags are a trap on this kernel. A plain load
  // passes: same_magic() skips the release part when the module has a
  // __versions section (ours does), comparing only the flags; and
  // check_version() over an EMPTY __versions pr_warn_once + PASSes.
  // flags overridable via argv[3] (decimal) for testing.
  int flags = 0;
  if (argc > 3) flags = atoi(argv[3]);
  errno=0; long rc;
  if (flags == 0) {
    LOG("[*] loading via init_module (flags=0, vermagic flags-only compare)\n");
    rc = syscall(SYS_init_module, buf, len, params);
  } else {
    const char *tmp = "/data/local/tmp/.ksu_patched.ko";
    int wfd = open(tmp, O_WRONLY|O_CREAT|O_TRUNC, 0600);
    if (wfd < 0){ LOG("open tmp %s: %m\n", tmp); return 2; }
    size_t woff=0; while(woff<len){ ssize_t w=write(wfd, buf+woff, len-woff); if(w<=0){LOG("write tmp: %m\n");return 2;} woff+=w; }
    fsync(wfd); close(wfd);
    int mfd = open(tmp, O_RDONLY|O_CLOEXEC);
    if (mfd < 0){ LOG("reopen tmp: %m\n"); return 2; }
    LOG("[*] loading via finit_module flags=%d\n", flags);
    rc = syscall(SYS_finit_module, mfd, params, flags);
  }
  if (rc==0){ LOG("[+] module loaded OK!\n"); return 0; }
  int e=errno;
  LOG("[-] module load failed: errno=%d (%s)\n", e, strerror(e));
  if (e==EKEYREJECTED) LOG("    EKEYREJECTED: signature still enforced (sig_enforce not flipped?)\n");
  if (e==ENOEXEC)      LOG("    ENOEXEC: vermagic/modstruct — check dmesg for 'version magic ... should be ...'\n");
  if (e==ENOENT)       LOG("    ENOENT: unknown symbol (kernel __ksymtab path) — see dmesg\n");
  if (e==EINVAL)       LOG("    EINVAL: bad relocation / malformed after patching\n");
  if (e==EPERM)        LOG("    EPERM: modules disabled / lockdown\n");
  if (e==EEXIST)       LOG("    EEXIST: module already loaded\n");
  return 4;
}
