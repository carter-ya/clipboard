#include "desktop_services.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static int cds_file_read_platform(const char *path, size_t limit,
                                  unsigned char **bytes, size_t *length) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (count < 4 || count > 32760) return -2;
  WCHAR *wide = calloc((size_t)count + 4, sizeof(WCHAR));
  if (!wide) return -1;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide + 4, count)) {
    free(wide); return -2;
  }
  WCHAR *local = wide + 4;
  if (!((local[0] >= L'A' && local[0] <= L'Z') || (local[0] >= L'a' && local[0] <= L'z')) ||
      local[1] != L':' || (local[2] != L'/' && local[2] != L'\\')) {
    free(wide); return -2;
  }
  WCHAR drive[] = {local[0], L':', L'\\', 0};
  if (GetDriveTypeW(drive) == DRIVE_REMOTE) { free(wide); return -2; }
  for (int index = 0; index < count; ++index) if (local[index] == L'/') local[index] = L'\\';
  wide[0] = L'\\'; wide[1] = L'\\'; wide[2] = L'?'; wide[3] = L'\\';
  HANDLE file = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
  free(wide);
  if (file == INVALID_HANDLE_VALUE) return -1;
  BY_HANDLE_FILE_INFORMATION info;
  LARGE_INTEGER size;
  int result = -1;
  unsigned char *buffer = NULL;
  if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
    result = -2; goto done;
  }
  if (!GetFileSizeEx(file, &size)) goto done;
  if (size.QuadPart < 0 || (unsigned long long)size.QuadPart > limit) { result = -4; goto done; }
  buffer = malloc(limit + 1);
  if (!buffer) goto done;
  size_t total = 0;
  for (;;) {
    DWORD amount = 0;
    DWORD requested = (DWORD)((limit - total + 1) > 65536 ? 65536 : (limit - total + 1));
    if (!ReadFile(file, buffer + total, requested, &amount, NULL)) goto done;
    if (!amount) break;
    if ((size_t)amount > limit - total) { result = -4; goto done; }
    total += amount;
  }
  *bytes = buffer; *length = total; buffer = NULL; result = 1;
done:
  free(buffer); CloseHandle(file); return result;
}
#elif defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
static int cds_file_read_platform(const char *path, size_t limit,
                                  unsigned char **bytes, size_t *length) {
  if (path[0] != '/') return -2;
  int file = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
  if (file < 0) return errno == ELOOP ? -2 : -1;
  struct stat info;
  int result = -1;
  unsigned char *buffer = NULL;
  if (fstat(file, &info) != 0) goto done;
  if (!S_ISREG(info.st_mode)) { result = -2; goto done; }
  if (info.st_size < 0 || (unsigned long long)info.st_size > limit) { result = -4; goto done; }
  buffer = malloc(limit + 1);
  if (!buffer) goto done;
  size_t total = 0;
  for (;;) {
    size_t requested = limit - total + 1;
    if (requested > 65536) requested = 65536;
    ssize_t amount = read(file, buffer + total, requested);
    if (amount < 0 && errno == EINTR) continue;
    if (amount < 0) goto done;
    if (!amount) break;
    if ((size_t)amount > limit - total) { result = -4; goto done; }
    total += (size_t)amount;
  }
  *bytes = buffer; *length = total; buffer = NULL; result = 1;
done:
  free(buffer); close(file); return result;
}
#else
static int cds_file_read_platform(const char *path, size_t limit,
                                  unsigned char **bytes, size_t *length) {
  (void)path; (void)limit; (void)bytes; (void)length; return -1;
}
#endif

/* Return only an owned bounded byte buffer, never diagnostics or file paths. */
int cds_file_read(const char *path, size_t limit, unsigned char **bytes,
                  size_t *length) {
  if (!bytes || !length) return -2;
  *bytes = NULL;
  *length = 0;
  if (!path || !*path || !limit || limit > 16 * 1024 * 1024 || strlen(path) > 65535)
    return -2;
  return cds_file_read_platform(path, limit, bytes, length);
}
