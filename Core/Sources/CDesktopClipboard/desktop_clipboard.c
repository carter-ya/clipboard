#include "desktop_clipboard.h"
#include <stdlib.h>
#include <string.h>

void cb_free(void *data) { free(data); }

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <limits.h>
#include <windows.h>

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

#elif defined(__linux__)
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/select.h>
#include <time.h>

// X11 requestors can disappear before asynchronous replies are processed.
// Only recover BadWindow on our own connections; preserve the host handler.
static _Atomic(Display *) clipboard_displays[32];
static pthread_mutex_t clipboard_display_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(XErrorHandler) previous_clipboard_error;
static int clipboard_error_installed;
static int clipboard_error(Display *display, XErrorEvent *event) {
  if (event->error_code == BadWindow) {
    for (unsigned i = 0; i < 32; ++i)
      if (atomic_load(&clipboard_displays[i]) == display)
        return 0;
  }
  XErrorHandler previous = atomic_load(&previous_clipboard_error);
  return previous ? previous(display, event) : 0;
}
static int register_display(Display *display) {
  int registered = 0;
  pthread_mutex_lock(&clipboard_display_lock);
  for (unsigned i = 0; i < 32; ++i)
    if (!atomic_load(&clipboard_displays[i])) {
      if (!clipboard_error_installed) {
        atomic_store(&previous_clipboard_error, XSetErrorHandler(clipboard_error));
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
struct cb_session {
  Display *display;
  Window window;
  Atom clipboard, utf8, targets, property, hint, incr;
  int fixes_event;
  uint64_t revision;
  char *owned;
  size_t owned_length;
  int owned_sensitive;
};
static pthread_once_t xlib_once = PTHREAD_ONCE_INIT;
static void init_xlib(void) { XInitThreads(); }
static double monotonic_seconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value.tv_sec + value.tv_nsec / 1000000000.0;
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
  XDestroyWindow(s->display, s->window);
  XSync(s->display, False);
  unregister_display(s->display);
  XCloseDisplay(s->display);
  free(s->owned);
  free(s);
}
int cb_connection_fd(cb_session *s) { return ConnectionNumber(s->display); }

static void dispatch_event(cb_session *s, XEvent *event) {
  if (event->type == s->fixes_event + XFixesSelectionNotify) {
    s->revision++;
    return;
  }
  if (event->type == SelectionClear) {
    free(s->owned);
    s->owned = NULL;
    s->owned_length = 0;
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
  if (s->owned && request->selection == s->clipboard) {
    if (request->target == s->targets) {
      Atom types[] = {s->targets, s->utf8, s->hint};
      XChangeProperty(s->display, request->requestor, property, XA_ATOM, 32,
                      PropModeReplace, (unsigned char *)types,
                      s->owned_sensitive ? 3 : 2);
      reply.xselection.property = property;
    } else if (request->target == s->utf8) {
      XChangeProperty(s->display, request->requestor, property, s->utf8, 8,
                      PropModeReplace, (unsigned char *)s->owned,
                      (int)s->owned_length);
      reply.xselection.property = property;
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
  while (XPending(s->display)) {
    XEvent e;
    XNextEvent(s->display, &e);
    dispatch_event(s, &e);
  }
}
uint64_t cb_revision(cb_session *s) {
  cb_pump(s);
  return s->revision;
}

static int convert(cb_session *s, Atom target, size_t max, unsigned char **out,
                   unsigned long *items, int *format) {
  *out = NULL;
  *items = 0;
  XDeleteProperty(s->display, s->window, s->property);
  XConvertSelection(s->display, s->clipboard, target, s->property, s->window,
                    CurrentTime);
  XFlush(s->display);
  double deadline = monotonic_seconds() + 1.0;
  while (monotonic_seconds() < deadline) {
    while (XPending(s->display)) {
      XEvent e;
      XNextEvent(s->display, &e);
      if (e.type == SelectionNotify && e.xselection.requestor == s->window &&
          e.xselection.selection == s->clipboard &&
          e.xselection.target == target) {
        if (e.xselection.property == None)
          return CB_EMPTY;
        Atom type;
        unsigned long remaining;
        if (XGetWindowProperty(s->display, s->window, s->property, 0,
                               (long)((max + 3) / 4), True, AnyPropertyType,
                               &type, format, items, &remaining,
                               out) != Success)
          return CB_UNAVAILABLE;
        if (type == s->incr || remaining) {
          if (*out)
            XFree(*out);
          *out = NULL;
          return CB_TOO_LARGE;
        }
        return CB_OK;
      }
      dispatch_event(s, &e);
    }
    int fd = ConnectionNumber(s->display);
    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(fd, &ready);
    struct timeval wait = {0, 20000};
    if (select(fd + 1, &ready, NULL, NULL, &wait) < 0 && errno != EINTR)
      return CB_UNAVAILABLE;
  }
  return CB_TIMEOUT;
}

int cb_read_utf8(cb_session *s, size_t max, char **out, size_t *length,
                 int *sensitive, uint64_t *revision) {
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
  // INCR transfer is deliberately excluded from this bounded text experiment.
  long request_limit = XMaxRequestSize(s->display) * 4 - 1024;
  if (length > (size_t)request_limit)
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
  s->owned = copy;
  s->owned_length = length;
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
#endif
