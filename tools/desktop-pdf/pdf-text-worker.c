/* A separate, bounded PDFium process. Input/output are private pipes only.
 * Public API: https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/8125/public/
 * The pinned non-V8/non-XFA runtime and all dependency notices accompany this worker.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "fpdfview.h"
#include "fpdf_text.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#else
#include <sys/resource.h>
#endif

#define BYTE_LIMIT (1024U * 1024U)
#define PAGE_LIMIT 256

static int limits(void) {
#ifdef _WIN32
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  if (_setmode(_fileno(stdin), _O_BINARY) == -1 ||
      _setmode(_fileno(stdout), _O_BINARY) == -1) return 0;
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return 0;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {0};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_PROCESS_TIME;
  info.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 10LL * 10000000LL;
  info.ProcessMemoryLimit = 512ULL * 1024ULL * 1024ULL;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info)) ||
      !AssignProcessToJobObject(job, GetCurrentProcess())) {
    CloseHandle(job); return 0;
  }
  /* Keep this unnamed handle until process exit so the limits remain in force. */
  return 1;
#else
  struct rlimit memory = {512UL * 1024UL * 1024UL, 512UL * 1024UL * 1024UL};
  struct rlimit cpu = {10, 10}, core = {0, 0};
  return setrlimit(RLIMIT_AS, &memory) == 0 && setrlimit(RLIMIT_CPU, &cpu) == 0 &&
         setrlimit(RLIMIT_CORE, &core) == 0;
#endif
}

static int append_scalar(unsigned char *output, size_t *length, uint32_t scalar) {
  if (!scalar) return 1; /* PDFium uses zero for characters without a Unicode mapping. */
  if (scalar > 0x10ffffU || (scalar >= 0xd800U && scalar <= 0xdfffU)) return 0;
  size_t count = scalar <= 0x7fU ? 1 : scalar <= 0x7ffU ? 2 : scalar <= 0xffffU ? 3 : 4;
  if (count > BYTE_LIMIT - *length) return 0;
  unsigned char *at = output + *length;
  if (count == 1) at[0] = (unsigned char)scalar;
  else {
    for (size_t index = count - 1; index > 0; --index) {
      at[index] = (unsigned char)(0x80U | (scalar & 0x3fU)); scalar >>= 6;
    }
    at[0] = (unsigned char)((count == 2 ? 0xc0U : count == 3 ? 0xe0U : 0xf0U) | scalar);
  }
  *length += count; return 1;
}

int main(void) {
  if (!limits()) return 2;
  unsigned char *input = malloc(BYTE_LIMIT + 1), *output = malloc(BYTE_LIMIT);
  if (!input || !output) { free(input); free(output); return 2; }
  size_t size = fread(input, 1, BYTE_LIMIT + 1, stdin), length = 0;
  if (ferror(stdin) || size > BYTE_LIMIT) { free(input); free(output); return 3; }
  FPDF_LIBRARY_CONFIG configuration = {0}; configuration.version = 2;
  FPDF_InitLibraryWithConfig(&configuration);
  FPDF_DOCUMENT document = FPDF_LoadMemDocument64(input, size, NULL);
  int result = 4;
  if (!document) goto done;
  /* Do not request passwords or bypass document extraction restrictions. */
  if (FPDF_GetSecurityHandlerRevision(document) >= 0) goto done;
  int pages = FPDF_GetPageCount(document);
  if (pages <= 0) goto done;
  if (pages > PAGE_LIMIT) { result = 3; goto done; }
  for (int index = 0; index < pages; ++index) {
    FPDF_PAGE page = FPDF_LoadPage(document, index);
    if (!page) goto done;
    FPDF_TEXTPAGE text = FPDFText_LoadPage(page);
    if (!text) { FPDF_ClosePage(page); goto done; }
    int count = FPDFText_CountChars(text), valid = count >= 0;
    if (count > (int)BYTE_LIMIT) { valid = 0; result = 3; }
    for (int character = 0; valid && character < count; ++character) {
      uint32_t scalar = FPDFText_GetUnicode(text, character);
      /* PDFium exposes supplementary mappings as adjacent UTF-16 units. */
      if (scalar >= 0xd800U && scalar <= 0xdbffU && character + 1 < count) {
        uint32_t low = FPDFText_GetUnicode(text, character + 1);
        if (low >= 0xdc00U && low <= 0xdfffU) {
          scalar = 0x10000U + ((scalar - 0xd800U) << 10) + low - 0xdc00U;
          ++character;
        }
      }
      if (scalar > 0x10ffffU || (scalar >= 0xd800U && scalar <= 0xdfffU)) {
        valid = 0; result = 4; break;
      }
      if (!append_scalar(output, &length, scalar)) {
        valid = 0; result = 3;
      }
    }
    FPDFText_ClosePage(text); FPDF_ClosePage(page);
    if (!valid) goto done;
    if (index + 1 < pages && !append_scalar(output, &length, '\n')) { result = 3; goto done; }
  }
  if (length && fwrite(output, 1, length, stdout) == length && fflush(stdout) == 0) result = 0;
done:
  if (document) FPDF_CloseDocument(document);
  FPDF_DestroyLibrary(); free(input); free(output); return result;
}
