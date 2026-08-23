// kmsg_dumper.c — stream /dev/kmsg to a file with O_SYNC so each record hits
// disk immediately. Survives a fast kernel panic (no ramoops/netconsole here).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
int main(int argc, char**argv){
  const char *out = argc>1? argv[1] : "/data/local/tmp/kmsg.txt";
  int k = open("/dev/kmsg", O_RDONLY);
  if (k<0){ perror("open kmsg"); return 2; }
  int f = open(out, O_WRONLY|O_CREAT|O_TRUNC|O_SYNC, 0666);
  if (f<0){ perror("open out"); return 2; }
  // fsync the directory so the file's existence is durable before any panic
  int d = open("/data/local/tmp", O_RDONLY|O_DIRECTORY); if(d>=0){ fsync(d); close(d);}
  char buf[8192];
  for(;;){
    ssize_t n = read(k, buf, sizeof buf);
    if (n<=0){ if(n<0) perror("read kmsg"); break; }
    ssize_t off=0; while(off<n){ ssize_t w=write(f, buf+off, n-off); if(w<=0) break; off+=w; }
    // O_SYNC already pushes each write; no extra fsync needed
  }
  return 0;
}
