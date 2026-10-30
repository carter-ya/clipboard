#include "desktop_clipboard.h"
#include "desktop_wayland.h"
#include <stdlib.h>
#include <string.h>

void cb_free(void *data) { free(data); }

void cb_bundle_free(cb_bundle *bundle) {
  if (!bundle)
    return;
  for (size_t i = 0; i < bundle->count; ++i)
    free(bundle->payloads[i].data);
  free(bundle->payloads);
  free(bundle->source_app);
  free(bundle);
}
int cb_bundle_append(cb_bundle *bundle, int format, const unsigned char *bytes,
                     size_t length, size_t max) {
  size_t total = 0;
  for (size_t i = 0; i < bundle->count; ++i)
    total += bundle->payloads[i].length;
  if (total > max || length > max - total)
    return CB_TOO_LARGE;
  cb_payload *next =
      realloc(bundle->payloads, (bundle->count + 1) * sizeof(cb_payload));
  if (!next)
    return CB_UNAVAILABLE;
  bundle->payloads = next;
  unsigned char *copy = malloc(length + 1);
  if (!copy)
    return CB_UNAVAILABLE;
  if (length)
    memcpy(copy, bytes, length);
  copy[length] = 0;
  bundle->payloads[bundle->count++] = (cb_payload){format, copy, length};
  return CB_OK;
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <limits.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wchar.h>

struct cb_session {
  int unused;
};
cb_session *cb_open(void) { return calloc(1, sizeof(cb_session)); }
void cb_close(cb_session *s) { free(s); }
int cb_connection_fd(cb_session *s) {
  (void)s;
  return -1;
}
void cb_pump(cb_session *s) { (void)s; }
uint64_t cb_revision(cb_session *s) {
  (void)s;
  return GetClipboardSequenceNumber();
}

int cb_read_utf8(cb_session *s, size_t max, char **out, size_t *length,
                 int *sensitive, uint64_t *revision) {
  (void)s;
  *out = NULL;
  *length = 0;
  *sensitive = 0;
  if (!OpenClipboard(NULL))
    return CB_UNAVAILABLE;
  int result = CB_EMPTY;
  *revision = GetClipboardSequenceNumber();
  UINT exclude =
      RegisterClipboardFormatA("ExcludeClipboardContentFromMonitorProcessing");
  UINT history = RegisterClipboardFormatA("CanIncludeInClipboardHistory");
  if (exclude && IsClipboardFormatAvailable(exclude))
    *sensitive = 1;
  if (history && IsClipboardFormatAvailable(history)) {
    HANDLE h = GetClipboardData(history);
    int history_sensitive = 1;
    if (h && GlobalSize(h) >= sizeof(DWORD)) {
      const DWORD *flag = GlobalLock(h);
      if (flag) {
        history_sensitive = *flag == 0;
        GlobalUnlock(h);
      }
    }
    if (history_sensitive)
      *sensitive = 1;
  }
  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    SIZE_T bytes = h ? GlobalSize(h) : 0;
    if (bytes > max * 4 + sizeof(WCHAR)) {
      *length = bytes;
      result = CB_TOO_LARGE;
    } else {
      const WCHAR *text = h ? GlobalLock(h) : NULL;
      if (!text)
        result = CB_UNAVAILABLE;
      else {
        size_t count = 0, capacity = bytes / sizeof(WCHAR);
        while (count < capacity && text[count])
          count++;
        if (count == capacity || count > INT_MAX)
          result = CB_INVALID;
        else {
          int needed =
              count ? WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                                          (int)count, NULL, 0, NULL, NULL)
                    : 0;
          *length = (size_t)needed;
          if (count && !needed)
            result = CB_INVALID;
          else if ((size_t)needed > max)
            result = CB_TOO_LARGE;
          else {
            *out = malloc((size_t)needed + 1);
            if (!*out)
              result = CB_UNAVAILABLE;
            else {
              if (needed)
                WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                                    (int)count, *out, needed, NULL, NULL);
              (*out)[needed] = 0;
              result = CB_OK;
            }
          }
        }
        GlobalUnlock(h);
      }
    }
  }
  CloseClipboard();
  return result;
}

int cb_write_utf8(cb_session *s, const char *text, size_t length,
                  int sensitive) {
  (void)s;
  if (length > INT_MAX || memchr(text, 0, length))
    return CB_INVALID;
  int count = length ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text,
                                           (int)length, NULL, 0)
                     : 0;
  if (length && !count)
    return CB_INVALID;
  HGLOBAL data =
      GlobalAlloc(GMEM_MOVEABLE, ((size_t)count + 1) * sizeof(WCHAR));
  if (!data)
    return CB_UNAVAILABLE;
  WCHAR *wide = GlobalLock(data);
  if (!wide) {
    GlobalFree(data);
    return CB_UNAVAILABLE;
  }
  if (count)
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)length, wide,
                        count);
  wide[count] = 0;
  GlobalUnlock(data);
  // A valid owner window is required after EmptyClipboard. It is created and
  // destroyed on this calling thread; all text is rendered immediately.
  HWND window =
      CreateWindowExW(0, L"STATIC", L"Clipboard text adapter", 0, 0, 0, 0, 0,
                      HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);
  if (!window) {
    GlobalFree(data);
    return CB_UNAVAILABLE;
  }
  if (!OpenClipboard(window)) {
    DestroyWindow(window);
    GlobalFree(data);
    return CB_UNAVAILABLE;
  }
  int result = CB_UNAVAILABLE;
  if (EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, data)) {
    data = NULL;
    result = CB_OK;
    if (sensitive) {
      UINT format = RegisterClipboardFormatA(
          "ExcludeClipboardContentFromMonitorProcessing");
      HGLOBAL flag = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DWORD));
      if (!format || !flag || !SetClipboardData(format, flag)) {
        if (flag)
          GlobalFree(flag);
        EmptyClipboard();
        result = CB_UNAVAILABLE;
      }
    }
  }
  CloseClipboard();
  DestroyWindow(window);
  if (data)
    GlobalFree(data);
  return result;
}

static UINT native_format(int format) {
  switch (format) {
  case CB_TEXT:
    return CF_UNICODETEXT;
  case CB_HTML:
    return RegisterClipboardFormatW(L"HTML Format");
  case CB_RTF:
    return RegisterClipboardFormatW(L"Rich Text Format");
  case CB_PNG:
    return RegisterClipboardFormatW(L"PNG");
  case CB_JPEG:
    return RegisterClipboardFormatW(L"JFIF");
  case CB_BMP:
    return CF_DIB;
  case CB_FILES:
    return CF_HDROP;
  case CB_TIFF:
    return CF_TIFF;
  default:
    return 0;
  }
}
static char *clipboard_source(void) {
  HWND owner = GetClipboardOwner();
  DWORD pid = 0;
  if (!owner || !GetWindowThreadProcessId(owner, &pid) || !pid)
    return NULL;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process)
    return NULL;
  WCHAR path[32768];
  DWORD count = 32768;
  int ok = QueryFullProcessImageNameW(process, 0, path, &count);
  CloseHandle(process);
  if (!ok)
    return NULL;
  const WCHAR *name = wcsrchr(path, L'\\');
  name = name ? name + 1 : path;
  int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1,
                                   NULL, 0, NULL, NULL);
  if (needed <= 1)
    return NULL;
  char *result = malloc((size_t)needed + 8);
  if (!result)
    return NULL;
  memcpy(result, "windows:", 8);
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1, result + 8,
                      needed, NULL, NULL);
  return result;
}
static int read_files(HANDLE data, size_t max, cb_bundle *bundle) {
  UINT count = DragQueryFileW((HDROP)data, 0xffffffff, NULL, 0);
  if (!count || count > 4096)
    return CB_INVALID;
  unsigned char *paths = NULL;
  size_t used = 0;
  for (UINT i = 0; i < count; ++i) {
    UINT length = DragQueryFileW((HDROP)data, i, NULL, 0);
    if (!length || length > 32767) {
      free(paths);
      return CB_INVALID;
    }
    WCHAR *path = calloc((size_t)length + 1, sizeof(WCHAR));
    if (!path) {
      free(paths);
      return CB_UNAVAILABLE;
    }
    if (DragQueryFileW((HDROP)data, i, path, length + 1) != length) {
      free(path);
      free(paths);
      return CB_INVALID;
    }
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1,
                                    NULL, 0, NULL, NULL);
    if (bytes <= 0 || (size_t)bytes > max - used) {
      free(path);
      free(paths);
      return CB_TOO_LARGE;
    }
    unsigned char *next = realloc(paths, used + (size_t)bytes);
    if (!next) {
      free(path);
      free(paths);
      return CB_UNAVAILABLE;
    }
    paths = next;
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1,
                        (char *)paths + used, bytes, NULL, NULL);
    used += (size_t)bytes;
    free(path);
  }
  int status = cb_bundle_append(bundle, CB_FILES, paths, used, max);
  free(paths);
  return status;
}
static size_t dib_pixel_offset(const unsigned char *data, size_t size) {
  if (size < sizeof(BITMAPINFOHEADER))
    return 0;
  BITMAPINFOHEADER header;
  memcpy(&header, data, sizeof(header));
  if (header.biSize < sizeof(header) || header.biSize > size ||
      header.biPlanes != 1)
    return 0;
  size_t offset = header.biSize;
  if (header.biSize == sizeof(header) &&
      (header.biCompression == BI_BITFIELDS || header.biCompression == 6))
    offset += header.biCompression == 6 ? 16 : 12;
  DWORD colors = header.biClrUsed;
  if (!colors && header.biBitCount <= 8)
    colors = 1U << header.biBitCount;
  if (colors > 256)
    return 0;
  offset += (size_t)colors * 4;
  return offset <= size ? offset : 0;
}
int cb_read_bundle(cb_session *s, size_t max, cb_bundle **out) {
  *out = NULL;
  if (!max || max > 16 * 1024 * 1024)
    return CB_INVALID;
  cb_bundle *bundle = calloc(1, sizeof(*bundle));
  if (!bundle)
    return CB_UNAVAILABLE;
  char *text = NULL;
  size_t length = 0;
  int status = cb_read_utf8(s, max, &text, &length, &bundle->sensitive,
                            &bundle->revision);
  if (status < 0) {
    cb_bundle_free(bundle);
    return status;
  }
  if (status == CB_OK)
    status =
        cb_bundle_append(bundle, CB_TEXT, (unsigned char *)text, length, max);
  free(text);
  if (status < 0 || !OpenClipboard(NULL)) {
    cb_bundle_free(bundle);
    return status < 0 ? status : CB_UNAVAILABLE;
  }
  bundle->source_app = clipboard_source();
  for (int format = CB_HTML; format <= CB_TIFF; ++format) {
    UINT native = native_format(format);
    if (!native || !IsClipboardFormatAvailable(native))
      continue;
    if (format == CB_BMP && IsClipboardFormatAvailable(native_format(CB_PNG)))
      continue;
    HANDLE value = GetClipboardData(native);
    if (!value) {
      status = CB_UNAVAILABLE;
      break;
    }
    if (format == CB_FILES)
      status = read_files(value, max, bundle);
    else {
      SIZE_T size = GlobalSize(value);
      if (size > max) {
        status = CB_TOO_LARGE;
        break;
      }
      const unsigned char *bytes = GlobalLock(value);
      if (!bytes) {
        status = CB_UNAVAILABLE;
        break;
      }
      if (format == CB_HTML || format == CB_RTF) {
        /* Native registered strings include a terminal NUL, not part of Core
         * data. */
        while (size && bytes[size - 1] == 0)
          --size;
      }
      if (format == CB_BMP) {
        size_t offset = dib_pixel_offset(bytes, size);
        if (!offset || size > max - 14)
          status = offset ? CB_TOO_LARGE : CB_INVALID;
        else {
          unsigned char *bmp = calloc(1, size + 14);
          if (!bmp)
            status = CB_UNAVAILABLE;
          else {
            uint32_t file_size = (uint32_t)size + 14,
                     file_offset = (uint32_t)offset + 14;
            bmp[0] = 'B';
            bmp[1] = 'M';
            memcpy(bmp + 2, &file_size, 4);
            memcpy(bmp + 10, &file_offset, 4);
            memcpy(bmp + 14, bytes, size);
            status = cb_bundle_append(bundle, format, bmp, size + 14, max);
            free(bmp);
          }
        }
      } else
        status = cb_bundle_append(bundle, format, bytes, size, max);
      GlobalUnlock(value);
    }
    if (status < 0)
      break;
  }
  if (bundle->revision != GetClipboardSequenceNumber())
    status = CB_UNAVAILABLE;
  CloseClipboard();
  if (status < 0 || !bundle->count) {
    cb_bundle_free(bundle);
    return status < 0 ? status : CB_EMPTY;
  }
  *out = bundle;
  return CB_OK;
}
static HGLOBAL make_native_data(const cb_payload *payload) {
  const unsigned char *bytes = payload->data;
  size_t size = payload->length;
  if (size > 16 * 1024 * 1024)
    return NULL;
  if (payload->format == CB_TEXT || payload->format == CB_FILES) {
    if (size > INT_MAX)
      return NULL;
    if (payload->format == CB_TEXT && memchr(bytes, 0, size))
      return NULL;
    int count =
        size ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   (const char *)bytes, (int)size, NULL, 0)
             : 0;
    if (size && !count)
      return NULL;
    size_t offset = payload->format == CB_FILES ? sizeof(DROPFILES) : 0;
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                               offset + ((size_t)count + 2) * sizeof(WCHAR));
    if (!data)
      return NULL;
    unsigned char *destination = GlobalLock(data);
    if (!destination) {
      GlobalFree(data);
      return NULL;
    }
    if (offset) {
      DROPFILES header = {0};
      header.pFiles = sizeof(DROPFILES);
      header.fWide = TRUE;
      memcpy(destination, &header, sizeof(header));
    }
    if (count)
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)bytes,
                          (int)size, (WCHAR *)(destination + offset), count);
    GlobalUnlock(data);
    return data;
  }
  if (payload->format == CB_BMP) {
    if (size < 54 || bytes[0] != 'B' || bytes[1] != 'M' ||
        !dib_pixel_offset(bytes + 14, size - 14))
      return NULL;
    bytes += 14;
    size -= 14;
  }
  HGLOBAL data = GlobalAlloc(
      GMEM_MOVEABLE | GMEM_ZEROINIT,
      size + (payload->format == CB_HTML || payload->format == CB_RTF ? 1 : 0));
  if (!data)
    return NULL;
  void *destination = GlobalLock(data);
  if (!destination) {
    GlobalFree(data);
    return NULL;
  }
  memcpy(destination, bytes, size);
  GlobalUnlock(data);
  return data;
}
int cb_write_bundle(cb_session *s, const cb_payload *payloads, size_t count,
                    int sensitive) {
  (void)s;
  if (!count || count > 8)
    return CB_INVALID;
  HGLOBAL handles[9] = {0};
  UINT formats[9] = {0};
  size_t total = 0;
  int status = CB_INVALID;
  for (size_t i = 0; i < count; ++i) {
    if (payloads[i].length > 16 * 1024 * 1024 - total) {
      status = CB_TOO_LARGE;
      goto cleanup;
    }
    total += payloads[i].length;
    formats[i] = native_format(payloads[i].format);
    for (size_t j = 0; j < i; ++j)
      if (formats[j] == formats[i])
        goto cleanup;
    if (!formats[i] || !(handles[i] = make_native_data(&payloads[i])))
      goto cleanup;
  }
  if (sensitive) {
    formats[count] = RegisterClipboardFormatW(
        L"ExcludeClipboardContentFromMonitorProcessing");
    handles[count] = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DWORD));
    if (!formats[count] || !handles[count]) {
      status = CB_UNAVAILABLE;
      goto cleanup;
    }
    ++count;
  }
  HWND owner =
      CreateWindowExW(0, L"STATIC", L"Clipboard rich adapter", 0, 0, 0, 0, 0,
                      HWND_MESSAGE, NULL, GetModuleHandleW(NULL), NULL);
  if (!owner) {
    status = CB_UNAVAILABLE;
    goto cleanup;
  }
  if (!OpenClipboard(owner)) {
    DestroyWindow(owner);
    status = CB_UNAVAILABLE;
    goto cleanup;
  }
  status = EmptyClipboard() ? CB_OK : CB_UNAVAILABLE;
  for (size_t i = 0; status == CB_OK && i < count; ++i) {
    if (SetClipboardData(formats[i], handles[i]))
      handles[i] = NULL;
    else {
      EmptyClipboard();
      status = CB_UNAVAILABLE;
    }
  }
  CloseClipboard();
  DestroyWindow(owner);
cleanup:
  for (size_t i = 0; i < 9; ++i)
    if (handles[i])
      GlobalFree(handles[i]);
  return status;
}

#elif defined(__linux__)
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xfixes.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/select.h>
#include <time.h>

static _Atomic(Display *) clipboard_displays[32];
static pthread_mutex_t clipboard_display_lock = PTHREAD_MUTEX_INITIALIZER;
static XErrorHandler previous_clipboard_error;
static int clipboard_error_installed;
static int clipboard_error(Display *display, XErrorEvent *event) {
  if (event->error_code == BadWindow) {
    for (unsigned i = 0; i < 32; ++i)
      if (atomic_load(&clipboard_displays[i]) == display)
        return 0;
  }
  return previous_clipboard_error ? previous_clipboard_error(display, event)
                                  : 0;
}
static int register_display(Display *display) {
  int registered = 0;
  pthread_mutex_lock(&clipboard_display_lock);
  for (unsigned i = 0; i < 32; ++i)
    if (!atomic_load(&clipboard_displays[i])) {
      if (!clipboard_error_installed) {
        previous_clipboard_error = XSetErrorHandler(clipboard_error);
        clipboard_error_installed = 1;
      }
      atomic_store(&clipboard_displays[i], display);
      registered = 1;
      break;
    }
  pthread_mutex_unlock(&clipboard_display_lock);
  return registered;
}
static void unregister_display(Display *display) {
  for (unsigned i = 0; i < 32; ++i)
    if (atomic_load(&clipboard_displays[i]) == display)
      atomic_store(&clipboard_displays[i], NULL);
}
typedef struct cb_transfer {
  Window requestor;
  Atom property, target;
  unsigned char *data;
  size_t length, offset;
  double deadline;
  struct cb_transfer *next;
} cb_transfer;
struct cb_session {
  cw_session *wayland;
  Display *display;
  Window window;
  Atom clipboard, utf8, targets, property, hint, incr;
  int fixes_event;
  uint64_t revision;
  char *owned;
  size_t owned_length;
  int owned_sensitive;
  cb_bundle *rich;
  cb_transfer *transfers;
};
static Atom format_atom(cb_session *s, int format);
static pthread_once_t xlib_once = PTHREAD_ONCE_INIT;
static void init_xlib(void) { XInitThreads(); }
static double monotonic_seconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static void transfer_remove(cb_session *s, cb_transfer **entry) {
  cb_transfer *value = *entry;
  *entry = value->next;
  free(value->data);
  free(value);
}
static int transfer_event(cb_session *s, XEvent *event) {
  cb_transfer **entry = &s->transfers;
  while (*entry) {
    cb_transfer *transfer = *entry;
    if (transfer->deadline < monotonic_seconds() ||
        (event->type == DestroyNotify &&
         event->xdestroywindow.window == transfer->requestor)) {
      transfer_remove(s, entry);
      continue;
    }
    if (event->type == PropertyNotify &&
        event->xproperty.window == transfer->requestor &&
        event->xproperty.atom == transfer->property &&
        event->xproperty.state == PropertyDelete) {
      size_t length = transfer->length - transfer->offset;
      size_t limit = (size_t)XMaxRequestSize(s->display) * 4 - 1024;
      if (length > limit)
        length = limit;
      XChangeProperty(s->display, transfer->requestor, transfer->property,
                      transfer->target, 8, PropModeReplace,
                      transfer->data + transfer->offset, (int)length);
      transfer->offset += length;
      if (!length)
        transfer_remove(s, entry);
      else
        transfer->deadline = monotonic_seconds() + 5.0;
      XFlush(s->display);
      return 1;
    }
    entry = &transfer->next;
  }
  return 0;
}
static int send_selection(cb_session *s, Window requestor, Atom property,
                          Atom target, const unsigned char *data,
                          size_t length) {
  size_t limit = (size_t)XMaxRequestSize(s->display) * 4 - 1024;
  if (length <= limit) {
    XChangeProperty(s->display, requestor, property, target, 8, PropModeReplace,
                    data, (int)length);
    return 1;
  }
  size_t pending = 0;
  unsigned count = 0;
  for (cb_transfer *value = s->transfers; value; value = value->next) {
    pending += value->length;
    ++count;
  }
  if (count >= 8 || length > 16 * 1024 * 1024 - pending)
    return 0;
  cb_transfer *transfer = calloc(1, sizeof(*transfer));
  if (!transfer)
    return 0;
  transfer->data = malloc(length);
  if (!transfer->data) {
    free(transfer);
    return 0;
  }
  memcpy(transfer->data, data, length);
  transfer->length = length;
  transfer->requestor = requestor;
  transfer->property = property;
  transfer->target = target;
  transfer->deadline = monotonic_seconds() + 5.0;
  transfer->next = s->transfers;
  s->transfers = transfer;
  XSelectInput(s->display, requestor, PropertyChangeMask | StructureNotifyMask);
  unsigned long advertised = length;
  XChangeProperty(s->display, requestor, property, s->incr, 32, PropModeReplace,
                  (unsigned char *)&advertised, 1);
  return 1;
}

cb_session *cb_open(void) {
  pthread_once(&xlib_once, init_xlib);
  cb_session *s = calloc(1, sizeof(*s));
  if (!s)
    return NULL;
  s->display = XOpenDisplay(NULL);
  if (!s->display) {
    free(s);
    return NULL;
  }
  if (!register_display(s->display)) {
    XCloseDisplay(s->display);
    free(s);
    return NULL;
  }
  int error;
  if (!XFixesQueryExtension(s->display, &s->fixes_event, &error)) {
    unregister_display(s->display);
    XCloseDisplay(s->display);
    free(s);
    return NULL;
  }
  s->window = XCreateSimpleWindow(s->display, DefaultRootWindow(s->display), 0,
                                  0, 1, 1, 0, 0, 0);
  XClassHint class_hint = {"clipboard-desktop", "ClipboardDesktop"};
  XSetClassHint(s->display, s->window, &class_hint);
  s->clipboard = XInternAtom(s->display, "CLIPBOARD", False);
  s->utf8 = XInternAtom(s->display, "UTF8_STRING", False);
  s->targets = XInternAtom(s->display, "TARGETS", False);
  s->property = XInternAtom(s->display, "CLIPBOARD_TEXT_RESULT", False);
  s->hint = XInternAtom(s->display, "x-kde-passwordManagerHint", False);
  s->incr = XInternAtom(s->display, "INCR", False);
  s->revision = 1;
  XFixesSelectSelectionInput(s->display, s->window, s->clipboard,
                             XFixesSetSelectionOwnerNotifyMask |
                                 XFixesSelectionWindowDestroyNotifyMask |
                                 XFixesSelectionClientCloseNotifyMask);
  XFlush(s->display);
  return s;
}
void cb_close(cb_session *s) {
  if (!s)
    return;
  if (s->wayland) {
    cw_close(s->wayland);
    free(s);
    return;
  }
  while (s->transfers)
    transfer_remove(s, &s->transfers);
  XDestroyWindow(s->display, s->window);
  XSync(s->display, False);
  unregister_display(s->display);
  XCloseDisplay(s->display);
  free(s->owned);
  cb_bundle_free(s->rich);
  free(s);
}
int cb_connection_fd(cb_session *s) {
  return s->wayland ? cw_fd(s->wayland) : ConnectionNumber(s->display);
}

static void dispatch_event(cb_session *s, XEvent *event) {
  if (transfer_event(s, event))
    return;
  if (event->type == s->fixes_event + XFixesSelectionNotify) {
    s->revision++;
    return;
  }
  if (event->type == SelectionClear) {
    free(s->owned);
    s->owned = NULL;
    s->owned_length = 0;
    cb_bundle_free(s->rich);
    s->rich = NULL;
    return;
  }
  if (event->type != SelectionRequest)
    return;
  XSelectionRequestEvent *request = &event->xselectionrequest;
  XEvent reply;
  memset(&reply, 0, sizeof(reply));
  reply.xselection.type = SelectionNotify;
  reply.xselection.display = request->display;
  reply.xselection.requestor = request->requestor;
  reply.xselection.selection = request->selection;
  reply.xselection.target = request->target;
  reply.xselection.time = request->time;
  reply.xselection.property = None;
  Atom property =
      request->property == None ? request->target : request->property;
  if ((s->owned || s->rich) && request->selection == s->clipboard) {
    if (request->target == s->targets) {
      Atom types[10] = {s->targets};
      int count = 1;
      if (s->owned)
        types[count++] = s->utf8;
      if (s->rich)
        for (size_t i = 0; i < s->rich->count; ++i)
          types[count++] = format_atom(s, s->rich->payloads[i].format);
      if (s->owned_sensitive)
        types[count++] = s->hint;
      XChangeProperty(s->display, request->requestor, property, XA_ATOM, 32,
                      PropModeReplace, (unsigned char *)types, count);
      reply.xselection.property = property;
    } else if (request->target == s->utf8 && s->owned) {
      if (send_selection(s, request->requestor, property, s->utf8,
                         (unsigned char *)s->owned, s->owned_length))
        reply.xselection.property = property;
    } else if (s->rich && request->target != s->hint) {
      for (size_t i = 0; i < s->rich->count; ++i) {
        cb_payload *payload = &s->rich->payloads[i];
        if (request->target != format_atom(s, payload->format))
          continue;
        if (send_selection(s, request->requestor, property, request->target,
                           payload->data, payload->length))
          reply.xselection.property = property;
        break;
      }
    } else if (request->target == s->hint && s->owned_sensitive) {
      XChangeProperty(s->display, request->requestor, property, s->hint, 8,
                      PropModeReplace, (unsigned char *)"secret", 6);
      reply.xselection.property = property;
    }
  }
  XSendEvent(s->display, request->requestor, False, 0, &reply);
  XFlush(s->display);
}
void cb_pump(cb_session *s) {
  if (s->wayland) {
    cw_pump(s->wayland);
    return;
  }
  XEvent expiry = {0};
  transfer_event(s, &expiry);
  while (XPending(s->display)) {
    XEvent e;
    XNextEvent(s->display, &e);
    dispatch_event(s, &e);
  }
}
uint64_t cb_revision(cb_session *s) {
  if (s->wayland)
    return cw_revision(s->wayland);
  cb_pump(s);
  return s->revision;
}

static int convert(cb_session *s, Atom target, size_t max, unsigned char **out,
                   unsigned long *items, int *format) {
  *out = NULL;
  *items = 0;
  *format = 0;
  Window requestor = XCreateSimpleWindow(
      s->display, DefaultRootWindow(s->display), 0, 0, 1, 1, 0, 0, 0);
  XSelectInput(s->display, requestor, PropertyChangeMask);
  XConvertSelection(s->display, s->clipboard, target, s->property, requestor,
                    CurrentTime);
  XFlush(s->display);
  double deadline = monotonic_seconds() + 2.0;
  int incremental = 0, result = CB_TIMEOUT;
  unsigned char *collected = NULL;
  size_t used = 0;
  while (monotonic_seconds() < deadline) {
    while (XPending(s->display)) {
      XEvent event;
      XNextEvent(s->display, &event);
      int selection = event.type == SelectionNotify &&
                      event.xselection.requestor == requestor &&
                      event.xselection.selection == s->clipboard &&
                      event.xselection.target == target;
      int chunk = incremental && event.type == PropertyNotify &&
                  event.xproperty.window == requestor &&
                  event.xproperty.atom == s->property &&
                  event.xproperty.state == PropertyNewValue;
      if (!selection && !chunk) {
        dispatch_event(s, &event);
        continue;
      }
      if (selection && event.xselection.property == None) {
        result = CB_EMPTY;
        goto done;
      }
      Atom type;
      unsigned long count = 0, remaining = 0;
      unsigned char *value = NULL;
      int bits = 0;
      if (XGetWindowProperty(s->display, requestor, s->property, 0,
                             (long)((max - used + 3) / 4), True,
                             AnyPropertyType, &type, &bits, &count, &remaining,
                             &value) != Success) {
        result = CB_UNAVAILABLE;
        goto done;
      }
      if (selection && type == s->incr) {
        unsigned long advertised =
            bits == 32 && count ? *(unsigned long *)value : 0;
        if (value)
          XFree(value);
        if (advertised > max) {
          result = CB_TOO_LARGE;
          goto done;
        }
        incremental = 1;
        XDeleteProperty(s->display, requestor, s->property);
        XFlush(s->display);
        continue;
      }
      size_t bytes = bits == 8 ? count : bits == 16 ? count * 2 : count * 4;
      if (remaining || bytes > max - used) {
        if (value)
          XFree(value);
        result = CB_TOO_LARGE;
        goto done;
      }
      if (!incremental) {
        *out = value;
        *items = count;
        *format = bits;
        result = CB_OK;
        goto done;
      }
      if (bits != 8) {
        if (value)
          XFree(value);
        result = CB_INVALID;
        goto done;
      }
      if (!count) {
        if (value)
          XFree(value);
        if (!collected)
          collected = calloc(1, 1);
        if (!collected) {
          result = CB_UNAVAILABLE;
          goto done;
        }
        *out = collected;
        collected = NULL;
        *items = used;
        *format = 8;
        result = CB_OK;
        goto done;
      }
      unsigned char *next = realloc(collected, used + bytes + 1);
      if (!next) {
        if (value)
          XFree(value);
        result = CB_UNAVAILABLE;
        goto done;
      }
      collected = next;
      memcpy(collected + used, value, bytes);
      used += bytes;
      collected[used] = 0;
      XFree(value);
      XFlush(s->display);
    }
    int fd = ConnectionNumber(s->display);
    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(fd, &ready);
    struct timeval wait = {0, 20000};
    if (select(fd + 1, &ready, NULL, NULL, &wait) < 0 && errno != EINTR) {
      result = CB_UNAVAILABLE;
      break;
    }
  }
done:
  free(collected);
  /* Destroying a private requestor also cancels a refused/timed-out INCR. */
  XDestroyWindow(s->display, requestor);
  XFlush(s->display);
  return result;
}

int cb_read_utf8(cb_session *s, size_t max, char **out, size_t *length,
                 int *sensitive, uint64_t *revision) {
  if (s->wayland)
    return CB_UNSUPPORTED;
  *out = NULL;
  *length = 0;
  *sensitive = 0;
  cb_pump(s);
  *revision = s->revision;
  Window owner = XGetSelectionOwner(s->display, s->clipboard);
  if (owner == None)
    return CB_EMPTY;
  unsigned char *value = NULL;
  unsigned long count = 0;
  int format = 0;
  int status = convert(s, s->targets, 4096, &value, &count, &format);
  if (status < 0)
    return status;
  int has_hint = 0;
  if (status == CB_OK && format == 32) {
    Atom *types = (Atom *)value;
    for (unsigned long i = 0; i < count; i++)
      if (types[i] == s->hint)
        has_hint = 1;
  }
  if (value)
    XFree(value);
  if (has_hint) {
    status = convert(s, s->hint, 64, &value, &count, &format);
    // A declared secret format that cannot be read is treated conservatively.
    *sensitive = status != CB_OK ||
                 (format == 8 && count == 6 && !memcmp(value, "secret", 6));
    if (value)
      XFree(value);
  }
  status = convert(s, s->utf8, max, &value, &count, &format);
  if (status != CB_OK) {
    if (status == CB_TOO_LARGE)
      *length = max + 1;
    return status;
  }
  if (format != 8 || count > max) {
    if (value)
      XFree(value);
    *length = count;
    return count > max ? CB_TOO_LARGE : CB_INVALID;
  }
  cb_pump(s);
  if (s->revision != *revision ||
      XGetSelectionOwner(s->display, s->clipboard) != owner) {
    if (value)
      XFree(value);
    return CB_UNAVAILABLE;
  }
  *out = malloc(count + 1);
  if (!*out) {
    if (value)
      XFree(value);
    return CB_UNAVAILABLE;
  }
  if (count)
    memcpy(*out, value, count);
  (*out)[count] = 0;
  *length = count;
  if (value)
    XFree(value);
  return CB_OK;
}
int cb_write_utf8(cb_session *s, const char *text, size_t length,
                  int sensitive) {
  if (s->wayland)
    return CB_UNSUPPORTED;
  if (length > 16 * 1024 * 1024)
    return CB_TOO_LARGE;
  if (memchr(text, 0, length))
    return CB_INVALID;
  char *copy = malloc(length + 1);
  if (!copy)
    return CB_UNAVAILABLE;
  memcpy(copy, text, length);
  copy[length] = 0;
  cb_pump(s);
  free(s->owned);
  cb_bundle_free(s->rich);
  s->rich = NULL;
  s->owned = copy;
  s->owned_length = length;
  s->owned_sensitive = sensitive;
  XSetSelectionOwner(s->display, s->clipboard, s->window, CurrentTime);
  XFlush(s->display);
  return XGetSelectionOwner(s->display, s->clipboard) == s->window
             ? CB_OK
             : CB_UNAVAILABLE;
}
static const char *format_name(int format) {
  switch (format) {
  case CB_TEXT:
    return "UTF8_STRING";
  case CB_HTML:
    return "text/html";
  case CB_RTF:
    return "text/rtf";
  case CB_PNG:
    return "image/png";
  case CB_JPEG:
    return "image/jpeg";
  case CB_BMP:
    return "image/bmp";
  case CB_FILES:
    return "text/uri-list";
  case CB_TIFF:
    return "image/tiff";
  default:
    return NULL;
  }
}
static Atom format_atom(cb_session *s, int format) {
  const char *name = format_name(format);
  return name ? XInternAtom(s->display, name, False) : None;
}
static char *clipboard_source(cb_session *s, Window owner) {
  XClassHint hint = {0};
  if (!XGetClassHint(s->display, owner, &hint)) {
    Atom property = XInternAtom(s->display, "WM_CLIENT_LEADER", False), type;
    int format;
    unsigned long count, remaining;
    unsigned char *value = NULL;
    if (XGetWindowProperty(s->display, owner, property, 0, 1, False, XA_WINDOW,
                           &type, &format, &count, &remaining,
                           &value) == Success &&
        value && format == 32 && count == 1) {
      Window leader = *(Window *)value;
      if (leader)
        XGetClassHint(s->display, leader, &hint);
    }
    if (value)
      XFree(value);
  }
  char *result = NULL;
  if (hint.res_class) {
    size_t length = strlen(hint.res_class);
    if (length && length < 1024) {
      result = malloc(length + 7);
      if (result) {
        memcpy(result, "linux:", 6);
        memcpy(result + 6, hint.res_class, length + 1);
      }
    }
  }
  if (hint.res_name)
    XFree(hint.res_name);
  if (hint.res_class)
    XFree(hint.res_class);
  return result;
}
int cb_read_bundle(cb_session *s, size_t max, cb_bundle **out) {
  if (s->wayland)
    return cw_read(s->wayland, max, out);
  *out = NULL;
  if (!max || max > 16 * 1024 * 1024)
    return CB_INVALID;
  cb_pump(s);
  Window owner = XGetSelectionOwner(s->display, s->clipboard);
  if (owner == None)
    return CB_EMPTY;
  cb_bundle *bundle = calloc(1, sizeof(*bundle));
  if (!bundle)
    return CB_UNAVAILABLE;
  bundle->revision = s->revision;
  unsigned char *value = NULL;
  unsigned long count = 0;
  int format = 0;
  int status = convert(s, s->targets, 4096, &value, &count, &format);
  if (status != CB_OK || format != 32 || count > 1024) {
    if (value)
      XFree(value);
    cb_bundle_free(bundle);
    return status < 0 ? status : CB_INVALID;
  }
  Atom available[1024];
  memcpy(available, value, count * sizeof(Atom));
  XFree(value);
  unsigned long available_count = count;
  int secret_declared = 0;
  for (unsigned long i = 0; i < available_count; ++i)
    if (available[i] == s->hint)
      secret_declared = 1;
  if (secret_declared) {
    value = NULL;
    status = convert(s, s->hint, 64, &value, &count, &format);
    bundle->sensitive = status != CB_OK || (format == 8 && count == 6 &&
                                            !memcmp(value, "secret", 6));
    if (value)
      XFree(value);
  }
  status = CB_OK;
  for (int f = CB_TEXT; f <= CB_TIFF; ++f) {
    Atom target = format_atom(s, f);
    int found = 0;
    for (unsigned long i = 0; i < available_count; ++i)
      if (available[i] == target)
        found = 1;
    if (!found && (f == CB_TEXT || f == CB_RTF)) {
      const char *aliases[] = {f == CB_TEXT ? "text/plain;charset=utf-8"
                                            : "application/rtf",
                               "text/plain"};
      unsigned aliases_count = f == CB_TEXT ? 2 : 1;
      for (unsigned a = 0; a < aliases_count && !found; ++a) {
        Atom alias = XInternAtom(s->display, aliases[a], False);
        for (unsigned long i = 0; i < available_count; ++i)
          if (available[i] == alias) {
            target = alias;
            found = 1;
          }
      }
    }
    if (!found)
      continue;
    value = NULL;
    status = convert(s, target, max, &value, &count, &format);
    if (status == CB_OK && format == 8)
      status = cb_bundle_append(bundle, f, value, count, max);
    else if (status == CB_OK)
      status = CB_INVALID;
    if (value)
      XFree(value);
    if (status < 0)
      break;
  }
  cb_pump(s);
  if (s->revision != bundle->revision ||
      XGetSelectionOwner(s->display, s->clipboard) != owner)
    status = CB_UNAVAILABLE;
  if (status < 0 || !bundle->count) {
    cb_bundle_free(bundle);
    return status < 0 ? status : CB_EMPTY;
  }
  bundle->source_app = clipboard_source(s, owner);
  *out = bundle;
  return CB_OK;
}
int cb_write_bundle(cb_session *s, const cb_payload *payloads, size_t count,
                    int sensitive) {
  if (s->wayland)
    return cw_write(s->wayland, payloads, count, sensitive);
  if (!count || count > 8)
    return CB_INVALID;
  cb_bundle *next = calloc(1, sizeof(*next));
  if (!next)
    return CB_UNAVAILABLE;
  next->sensitive = sensitive;
  for (size_t i = 0; i < count; ++i) {
    if (!format_name(payloads[i].format)) {
      cb_bundle_free(next);
      return CB_INVALID;
    }
    for (size_t j = 0; j < i; ++j)
      if (payloads[j].format == payloads[i].format) {
        cb_bundle_free(next);
        return CB_INVALID;
      }
    int result = cb_bundle_append(next, payloads[i].format, payloads[i].data,
                                  payloads[i].length, 16 * 1024 * 1024);
    if (result < 0) {
      cb_bundle_free(next);
      return result;
    }
  }
  cb_pump(s);
  free(s->owned);
  s->owned = NULL;
  s->owned_length = 0;
  cb_bundle_free(s->rich);
  s->rich = next;
  s->owned_sensitive = sensitive;
  XSetSelectionOwner(s->display, s->clipboard, s->window, CurrentTime);
  XFlush(s->display);
  return XGetSelectionOwner(s->display, s->clipboard) == s->window
             ? CB_OK
             : CB_UNAVAILABLE;
}

#else
struct cb_session {
  int unused;
};
cb_session *cb_open(void) { return NULL; }
void cb_close(cb_session *s) { (void)s; }
int cb_connection_fd(cb_session *s) {
  (void)s;
  return -1;
}
void cb_pump(cb_session *s) { (void)s; }
uint64_t cb_revision(cb_session *s) {
  (void)s;
  return 0;
}
int cb_read_utf8(cb_session *s, size_t max, char **out, size_t *length,
                 int *sensitive, uint64_t *revision) {
  (void)s;
  (void)max;
  (void)out;
  (void)length;
  (void)sensitive;
  (void)revision;
  return CB_UNSUPPORTED;
}
int cb_write_utf8(cb_session *s, const char *text, size_t length,
                  int sensitive) {
  (void)s;
  (void)text;
  (void)length;
  (void)sensitive;
  return CB_UNSUPPORTED;
}
int cb_read_bundle(cb_session *s, size_t max, cb_bundle **out) {
  (void)s;
  (void)max;
  *out = NULL;
  return CB_UNSUPPORTED;
}
int cb_write_bundle(cb_session *s, const cb_payload *payloads, size_t count,
                    int sensitive) {
  (void)s;
  (void)payloads;
  (void)count;
  (void)sensitive;
  return CB_UNSUPPORTED;
}

#endif

int cb_pending_transfers(cb_session *s) {
#if defined(__linux__)
  return s && s->transfers != NULL;
#else
  (void)s;
  return 0;
#endif
}

cb_session *cb_open_rich(const char *wayland_display, int *error) {
  if (error)
    *error = CB_UNAVAILABLE;
#if defined(__linux__)
  if (wayland_display) {
    int status = CB_UNAVAILABLE;
    cw_session *wayland = cw_open(wayland_display, &status);
    if (!wayland) {
      if (error)
        *error = status;
      return NULL;
    }
    cb_session *session = calloc(1, sizeof(*session));
    if (!session) {
      cw_close(wayland);
      return NULL;
    }
    session->wayland = wayland;
    if (error)
      *error = CB_OK;
    return session;
  }
#else
  (void)wayland_display;
#endif
  cb_session *session = cb_open();
  if (session && error)
    *error = CB_OK;
  return session;
}
