// kmsg_dumper.c — stream /dev/kmsg to a file with O_SYNC so each record hits
// disk immediately. Survives a fast kernel panic (no ramoops/netconsole here).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <poll.h>
int main(int argc, char**argv){
  const char *out = argc>1? argv[1] : "/data/local/tmp/kmsg.txt";
  // O_NONBLOCK: when caught up to the live tail, read returns EAGAIN and we
  // poll instead of exiting. A blocking fd made the old loop die on the first
  // stray signal (EINTR) — captures silently ended ~10s after start.
  int k = open("/dev/kmsg", O_RDONLY|O_NONBLOCK);
  if (k<0){ perror("open kmsg"); return 2; }
  int f = open(out, O_WRONLY|O_CREAT|O_TRUNC|O_SYNC, 0666);
  if (f<0){ perror("open out"); return 2; }
  // fsync the directory so the file's existence is durable before any panic
  int d = open("/data/local/tmp", O_RDONLY|O_DIRECTORY); if(d>=0){ fsync(d); close(d);}
  char buf[8192];
  struct pollfd pfd = { .fd = k, .events = POLLIN };
  for(;;){
    ssize_t n = read(k, buf, sizeof buf);
    if (n == 0){ usleep(100000); continue; }
    if (n < 0){
      if (errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK){
        poll(&pfd, 1, 1000);   // wait for the next record; ignore spurious wakeups
        continue;
      }
      if (errno == EPIPE){
        // the ring overtook us while draining history (printk bursts at
        // module load do this reliably): documented recovery is to skip to
        // the newest record and keep streaming.
        if (lseek(k, 0, SEEK_END) < 0){ perror("lseek kmsg"); break; }
        continue;
      }
      perror("read kmsg"); break;
    }
    ssize_t off=0; while(off<n){ ssize_t w=write(f, buf+off, n-off); if(w<=0) break; off+=w; }
    // O_SYNC already pushes each write; no extra fsync needed
  }
  return 0;
}
