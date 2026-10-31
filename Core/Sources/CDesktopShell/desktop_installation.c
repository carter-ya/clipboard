#include "desktop_shell.h"
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
struct clipboard_installation_lock {
  HANDLE handle;
};
clipboard_installation_lock *
clipboard_installation_lock_create(const char *directory) {
  (void)directory;
  clipboard_installation_lock *value = calloc(1, sizeof(*value));
  if (!value)
    return NULL;
  value->handle = CreateMutexW(NULL, FALSE, L"Local\\ClipboardDesktop.Running");
  if (!value->handle) {
    free(value);
    return NULL;
  }
  return value;
}
void clipboard_installation_lock_destroy(clipboard_installation_lock *value) {
  if (value) {
    CloseHandle(value->handle);
    free(value);
  }
}
#elif defined(__linux__)
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
struct clipboard_installation_lock {
  int fd;
};
clipboard_installation_lock *
clipboard_installation_lock_create(const char *directory) {
  if (!directory)
    return NULL;
  int fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0)
    return NULL;
  if (flock(fd, LOCK_SH | LOCK_NB) != 0) {
    close(fd);
    return NULL;
  }
  clipboard_installation_lock *value = calloc(1, sizeof(*value));
  if (!value) {
    close(fd);
    return NULL;
  }
  value->fd = fd;
  return value;
}
void clipboard_installation_lock_destroy(clipboard_installation_lock *value) {
  if (value) {
    close(value->fd);
    free(value);
  }
}
#else
clipboard_installation_lock *
clipboard_installation_lock_create(const char *directory) {
  (void)directory;
  return NULL;
}
void clipboard_installation_lock_destroy(clipboard_installation_lock *value) {
  (void)value;
}
#endif
