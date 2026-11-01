// Exercise the actual receive-pipe helper without accessing any desktop clipboard.
#include "../../Core/Sources/CDesktopClipboard/desktop_wayland.c"
#include <stdio.h>
#include <sys/wait.h>

int main(void) {
  int descriptors[2];
  if (open_transfer_pipe(descriptors) != 0)
    return 1;
  if (!(fcntl(descriptors[0], F_GETFL) & O_NONBLOCK) ||
      (fcntl(descriptors[1], F_GETFL) & O_NONBLOCK)) {
    fputs("receive pipe must leave the external producer blocking\n", stderr);
    close(descriptors[0]);
    close(descriptors[1]);
    return 2;
  }
  if (!(fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC) ||
      !(fcntl(descriptors[1], F_GETFD) & FD_CLOEXEC))
    return 3;
  pid_t producer = fork();
  if (producer < 0)
    return 4;
  if (!producer) {
    close(descriptors[0]);
    unsigned char chunk[8192];
    memset(chunk, 0x42, sizeof(chunk));
    for (unsigned block = 0; block < 128; ++block) {
      size_t written = 0;
      while (written < sizeof(chunk)) {
        ssize_t count = write(descriptors[1], chunk + written, sizeof(chunk) - written);
        if (count < 0 && errno == EINTR)
          continue;
        // Ordinary blocking producers do not retry EAGAIN.
        if (count <= 0)
          _exit(5);
        written += (size_t)count;
      }
    }
    close(descriptors[1]);
    _exit(0);
  }
  close(descriptors[1]);
  size_t received = 0;
  int eof = 0, valid = 1;
  double deadline = now_seconds() + 5;
  while (now_seconds() < deadline) {
    unsigned char bytes[16384];
    ssize_t count = read(descriptors[0], bytes, sizeof(bytes));
    if (count > 0) {
      received += (size_t)count;
      for (ssize_t i = 0; i < count; ++i)
        if (bytes[i] != 0x42)
          valid = 0;
    } else if (!count) {
      eof = 1;
      break;
    } else if (errno != EAGAIN && errno != EINTR) {
      break;
    } else {
      struct pollfd ready = {descriptors[0], POLLIN, 0};
      if (poll(&ready, 1, 100) < 0 && errno != EINTR)
        break;
    }
  }
  close(descriptors[0]);
  if (!eof)
    kill(producer, SIGTERM);
  int status;
  if (waitpid(producer, &status, 0) != producer || !WIFEXITED(status) ||
      WEXITSTATUS(status) || !eof || !valid || received != 1024 * 1024)
    return 6;
  puts("Wayland pipe flags and complete blocking-producer transfer passed");
  return 0;
}
