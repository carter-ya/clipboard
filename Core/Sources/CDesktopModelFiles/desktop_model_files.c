#include "desktop_model_files.h"
#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>
typedef struct { HANDLE file; } model_stage_lease;

void *clipboard_model_stage_lock(const char *path, int create) {
  if (!path) return NULL;
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (length <= 0 || length > 32768) return NULL;
  wchar_t *wide = calloc((size_t)length, sizeof(wchar_t));
  if (!wide) return NULL;
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length) != length) {
    free(wide);
    return NULL;
  }
  HANDLE file = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                            create ? CREATE_NEW : OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(wide);
  if (file == INVALID_HANDLE_VALUE) return NULL;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(file, &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      info.nNumberOfLinks != 1 || info.nFileSizeHigh != 0 || info.nFileSizeLow != 0) {
    CloseHandle(file);
    return NULL;
  }
  model_stage_lease *lease = malloc(sizeof(*lease));
  if (!lease) { CloseHandle(file); return NULL; }
  lease->file = file;
  return lease;
}
void clipboard_model_stage_unlock(void *value) {
  model_stage_lease *lease = value;
  if (!lease) return;
  CloseHandle(lease->file);
  free(lease);
}
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
typedef struct { int file; } model_stage_lease;

void *clipboard_model_stage_lock(const char *path, int create) {
  if (!path) return NULL;
  int flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW;
  if (create) flags |= O_CREAT | O_EXCL;
  int file = open(path, flags, 0600);
  if (file < 0) return NULL;
  struct stat info;
  if (fstat(file, &info) != 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1 ||
      info.st_size != 0 || flock(file, LOCK_EX | LOCK_NB) != 0) {
    close(file);
    return NULL;
  }
  model_stage_lease *lease = malloc(sizeof(*lease));
  if (!lease) { close(file); return NULL; }
  lease->file = file;
  return lease;
}
void clipboard_model_stage_unlock(void *value) {
  model_stage_lease *lease = value;
  if (!lease) return;
  /* close releases the OS lock, including on process termination. */
  close(lease->file);
  free(lease);
}
#endif
