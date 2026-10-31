#define _GNU_SOURCE
#include "desktop_wayland.h"
#if defined(__linux__)
#include "wayland-protocols/wlr-data-control-unstable-v1-client-protocol.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

static const char *mime_names[] = {"text/plain;charset=utf-8",
                                   "UTF8_STRING",
                                   "text/plain",
                                   "text/html",
                                   "text/rtf",
                                   "application/rtf",
                                   "image/png",
                                   "image/jpeg",
                                   "image/bmp",
                                   "text/uri-list",
                                   "image/tiff",
                                   "x-kde-passwordManagerHint",
                                   "org.nspasteboard.ConcealedType"};
static const int mime_formats[] = {CB_TEXT, CB_TEXT, CB_TEXT, CB_HTML, CB_RTF,
                                   CB_RTF,  CB_PNG,  CB_JPEG, CB_BMP,  CB_FILES,
                                   CB_TIFF, 0,       0};
#define MIME_COUNT (sizeof(mime_names) / sizeof(mime_names[0]))
typedef struct cw_offer {
  struct cw_session *session;
  struct zwlr_data_control_offer_v1 *proxy;
  uint32_t mimes;
  int retired, readers;
  struct cw_offer *next;
} cw_offer;
typedef struct cw_source {
  struct cw_session *session;
  struct zwlr_data_control_source_v1 *proxy;
  cb_bundle *bundle;
} cw_source;
struct cw_session {
  struct wl_display *display;
  struct wl_registry *registry;
  struct zwlr_data_control_manager_v1 *manager;
  struct wl_seat *seat;
  struct zwlr_data_control_device_v1 *device;
  uint32_t manager_name, seat_name;
  cw_offer *offers, *selection;
  cw_source *source;
  uint64_t revision;
  int finished;
};
static double now_seconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value.tv_sec + value.tv_nsec / 1000000000.0;
}
static void fail_session(cw_session *s) {
  if (!s->finished) {
    s->finished = 1;
    s->revision++;
  }
}
static int dispatch(cw_session *s, int timeout) {
  if (s->finished)
    return 0;
  while (wl_display_prepare_read(s->display) != 0) {
    if (wl_display_dispatch_pending(s->display) < 0) {
      fail_session(s);
      return 0;
    }
  }
  int flushed = wl_display_flush(s->display);
  if (flushed < 0 && errno != EAGAIN) {
    wl_display_cancel_read(s->display);
    fail_session(s);
    return 0;
  }
  struct pollfd ready = {wl_display_get_fd(s->display),
                         POLLIN | (flushed < 0 ? POLLOUT : 0), 0};
  int status;
  do {
    status = poll(&ready, 1, timeout);
  } while (status < 0 && errno == EINTR);
  if (status > 0 && (ready.revents & POLLIN)) {
    if (wl_display_read_events(s->display) < 0) {
      fail_session(s);
      return 0;
    }
  } else
    wl_display_cancel_read(s->display);
  if (status < 0 || (ready.revents & (POLLERR | POLLHUP | POLLNVAL))) {
    fail_session(s);
    return 0;
  }
  if (ready.revents & POLLOUT)
    wl_display_flush(s->display);
  if (wl_display_dispatch_pending(s->display) < 0) {
    fail_session(s);
    return 0;
  }
  return 1;
}
static void synchronized(void *data, struct wl_callback *callback,
                         uint32_t serial) {
  (void)serial;
  *(int *)data = 1;
  wl_callback_destroy(callback);
}
static int roundtrip(cw_session *s) {
  int done = 0;
  struct wl_callback *callback = wl_display_sync(s->display);
  if (!callback)
    return 0;
  const struct wl_callback_listener listener = {.done = synchronized};
  wl_callback_add_listener(callback, &listener, &done);
  double deadline = now_seconds() + 2;
  while (!done && now_seconds() < deadline && dispatch(s, 20)) {
  }
  if (!done)
    wl_callback_destroy(callback);
  return done && !s->finished;
}
static void clean_offers(cw_session *s) {
  cw_offer **entry = &s->offers;
  while (*entry) {
    cw_offer *offer = *entry;
    if (offer->retired && !offer->readers) {
      *entry = offer->next;
      zwlr_data_control_offer_v1_destroy(offer->proxy);
      free(offer);
    } else
      entry = &offer->next;
  }
}
static cw_offer *find_offer(cw_session *s,
                            struct zwlr_data_control_offer_v1 *proxy) {
  for (cw_offer *offer = s->offers; offer; offer = offer->next)
    if (offer->proxy == proxy)
      return offer;
  return NULL;
}
static void offered_mime(void *data, struct zwlr_data_control_offer_v1 *proxy,
                         const char *mime) {
  (void)proxy;
  cw_offer *offer = data;
  for (unsigned i = 0; i < MIME_COUNT; ++i)
    if (!strcmp(mime, mime_names[i]))
      offer->mimes |= 1U << i;
}
static const struct zwlr_data_control_offer_v1_listener offer_listener = {
    .offer = offered_mime};
static void offered(void *data, struct zwlr_data_control_device_v1 *device,
                    struct zwlr_data_control_offer_v1 *proxy) {
  (void)device;
  cw_session *s = data;
  cw_offer *offer = calloc(1, sizeof(*offer));
  if (!offer) {
    zwlr_data_control_offer_v1_destroy(proxy);
    return;
  }
  offer->proxy = proxy;
  offer->session = s;
  offer->next = s->offers;
  s->offers = offer;
  zwlr_data_control_offer_v1_add_listener(proxy, &offer_listener, offer);
}
static void selected(void *data, struct zwlr_data_control_device_v1 *device,
                     struct zwlr_data_control_offer_v1 *proxy) {
  (void)device;
  cw_session *s = data;
  s->selection = find_offer(s, proxy);
  s->revision++;
  for (cw_offer *offer = s->offers; offer; offer = offer->next)
    if (offer != s->selection)
      offer->retired = 1;
  clean_offers(s);
}
static void finished(void *data, struct zwlr_data_control_device_v1 *device) {
  (void)device;
  fail_session(data);
}
static void primary_selected(void *data,
                             struct zwlr_data_control_device_v1 *device,
                             struct zwlr_data_control_offer_v1 *proxy) {
  (void)device;
  cw_session *s = data;
  cw_offer *offer = find_offer(s, proxy);
  if (offer && offer != s->selection) {
    offer->retired = 1;
    clean_offers(s);
  }
}
static const struct zwlr_data_control_device_v1_listener device_listener = {
    .data_offer = offered,
    .selection = selected,
    .finished = finished,
    .primary_selection = primary_selected};
static void seat_capabilities(void *data, struct wl_seat *seat,
                              uint32_t capabilities) {
  (void)data;
  (void)seat;
  (void)capabilities;
}
static const struct wl_seat_listener seat_listener = {.capabilities =
                                                          seat_capabilities};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  cw_session *s = data;
  if (!s->manager && !strcmp(interface, "zwlr_data_control_manager_v1")) {
    s->manager = wl_registry_bind(registry, name,
                                  &zwlr_data_control_manager_v1_interface,
                                  version < 2 ? version : 2);
    s->manager_name = name;
  } else if (!s->seat && !strcmp(interface, "wl_seat")) {
    s->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    s->seat_name = name;
    wl_seat_add_listener(s->seat, &seat_listener, s);
  }
}
static void global_removed(void *data, struct wl_registry *registry,
                           uint32_t name) {
  (void)registry;
  cw_session *s = data;
  if (name == s->manager_name || name == s->seat_name)
    fail_session(s);
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_removed};
static void destroy_source(cw_source *source) {
  if (!source)
    return;
  zwlr_data_control_source_v1_destroy(source->proxy);
  cb_bundle_free(source->bundle);
  free(source);
}
void cw_close(cw_session *s) {
  if (!s)
    return;
  destroy_source(s->source);
  for (cw_offer *offer = s->offers; offer;) {
    cw_offer *next = offer->next;
    zwlr_data_control_offer_v1_destroy(offer->proxy);
    free(offer);
    offer = next;
  }
  if (s->device)
    zwlr_data_control_device_v1_destroy(s->device);
  if (s->manager)
    zwlr_data_control_manager_v1_destroy(s->manager);
  if (s->seat)
    wl_seat_destroy(s->seat);
  if (s->registry)
    wl_registry_destroy(s->registry);
  if (s->display) {
    wl_display_flush(s->display);
    wl_display_disconnect(s->display);
  }
  free(s);
}
cw_session *cw_open(const char *display_name, int *error) {
  *error = CB_UNAVAILABLE;
  cw_session *s = calloc(1, sizeof(*s));
  if (!s)
    return NULL;
  s->revision = 1;
  s->display = wl_display_connect(display_name);
  if (!s->display) {
    free(s);
    return NULL;
  }
  s->registry = wl_display_get_registry(s->display);
  wl_registry_add_listener(s->registry, &registry_listener, s);
  if (!roundtrip(s)) {
    cw_close(s);
    return NULL;
  }
  if (!s->manager || !s->seat) {
    *error = CB_UNSUPPORTED;
    cw_close(s);
    return NULL;
  }
  s->device = zwlr_data_control_manager_v1_get_data_device(s->manager, s->seat);
  zwlr_data_control_device_v1_add_listener(s->device, &device_listener, s);
  if (!roundtrip(s)) {
    cw_close(s);
    return NULL;
  }
  *error = CB_OK;
  return s;
}
int cw_fd(cw_session *s) {
  return s && !s->finished ? wl_display_get_fd(s->display) : -1;
}
void cw_pump(cw_session *s) {
  if (s)
    dispatch(s, 0);
}
uint64_t cw_revision(cw_session *s) {
  cw_pump(s);
  return s->revision;
}
static int open_transfer_pipe(int descriptors[2]) {
  if (pipe2(descriptors, O_CLOEXEC) != 0)
    return -1;
  // The descriptor passed to another client must retain blocking-write semantics.
  int flags = fcntl(descriptors[0], F_GETFL);
  if (flags < 0 || fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) < 0) {
    int saved = errno;
    close(descriptors[0]);
    close(descriptors[1]);
    errno = saved;
    return -1;
  }
  return 0;
}
static int read_mime(cw_session *s, cw_offer *offer, unsigned mime, size_t max,
                     unsigned char **out, size_t *length) {
  *out = NULL;
  *length = 0;
  if (s->finished)
    return CB_UNSUPPORTED;
  int descriptors[2];
  if (open_transfer_pipe(descriptors) != 0)
    return CB_UNAVAILABLE;
  zwlr_data_control_offer_v1_receive(offer->proxy, mime_names[mime],
                                     descriptors[1]);
  close(descriptors[1]);
  wl_display_flush(s->display);
  double deadline = now_seconds() + 2;
  int result = CB_TIMEOUT;
  unsigned char *bytes = NULL;
  size_t used = 0;
  while (now_seconds() < deadline) {
    if (!dispatch(s, 0) || s->selection != offer) {
      result = s->finished ? CB_UNSUPPORTED : CB_UNAVAILABLE;
      break;
    }
    unsigned char chunk[16384];
    ssize_t count = read(descriptors[0], chunk, sizeof(chunk));
    if (count > 0) {
      if ((size_t)count > max - used) {
        result = CB_TOO_LARGE;
        break;
      }
      unsigned char *next = realloc(bytes, used + (size_t)count + 1);
      if (!next) {
        result = CB_UNAVAILABLE;
        break;
      }
      bytes = next;
      memcpy(bytes + used, chunk, (size_t)count);
      used += (size_t)count;
      bytes[used] = 0;
    } else if (!count) {
      result = CB_OK;
      break;
    } else if (errno != EAGAIN && errno != EINTR) {
      result = CB_UNAVAILABLE;
      break;
    } else {
      struct pollfd ready[2] = {{descriptors[0], POLLIN, 0},
                                {wl_display_get_fd(s->display), POLLIN, 0}};
      if (poll(ready, 2, 20) < 0 && errno != EINTR) {
        result = CB_UNAVAILABLE;
        break;
      }
    }
  }
  close(descriptors[0]);
  if (result == CB_OK) {
    if (!bytes)
      bytes = calloc(1, 1);
    if (!bytes)
      return CB_UNAVAILABLE;
    *out = bytes;
    *length = used;
  } else
    free(bytes);
  return result;
}
int cw_read(cw_session *s, size_t max, cb_bundle **out) {
  *out = NULL;
  if (!max || max > 16 * 1024 * 1024)
    return CB_INVALID;
  cw_pump(s);
  if (s->finished)
    return CB_UNSUPPORTED;
  cb_bundle *bundle = calloc(1, sizeof(*bundle));
  if (!bundle)
    return CB_UNAVAILABLE;
  bundle->revision = s->revision;
  if (s->source) {
    bundle->sensitive = s->source->bundle->sensitive;
    for (size_t i = 0; i < s->source->bundle->count; ++i) {
      cb_payload *payload = &s->source->bundle->payloads[i];
      int status = cb_bundle_append(bundle, payload->format, payload->data,
                                    payload->length, max);
      if (status < 0) {
        cb_bundle_free(bundle);
        return status;
      }
    }
    *out = bundle;
    return CB_OK;
  }
  cw_offer *offer = s->selection;
  if (!offer) {
    cb_bundle_free(bundle);
    return CB_EMPTY;
  }
  ++offer->readers;
  int result = CB_OK;
  size_t total = 0;
  if (offer->mimes & (1U << 12))
    bundle->sensitive = 1;
  if (offer->mimes & (1U << 11)) {
    unsigned char *hint = NULL;
    size_t length = 0;
    int status = read_mime(s, offer, 11, 64, &hint, &length);
    bundle->sensitive = bundle->sensitive || status != CB_OK ||
                        (length == 6 && !memcmp(hint, "secret", 6));
    free(hint);
  }
  for (int format = CB_TEXT; format <= CB_TIFF; ++format) {
    for (unsigned mime = 0; mime < MIME_COUNT; ++mime) {
      if (mime_formats[mime] != format || !(offer->mimes & (1U << mime)))
        continue;
      unsigned char *bytes = NULL;
      size_t length = 0;
      result = read_mime(s, offer, mime, max - total, &bytes, &length);
      if (result == CB_OK) {
        result = cb_bundle_append(bundle, format, bytes, length, max);
        total += length;
      }
      free(bytes);
      break;
    }
    if (result < 0)
      break;
  }
  if (bundle->revision != s->revision || s->selection != offer)
    result = CB_UNAVAILABLE;
  --offer->readers;
  clean_offers(s);
  if (result < 0 || !bundle->count) {
    cb_bundle_free(bundle);
    return result < 0 ? result : CB_EMPTY;
  }
  *out = bundle;
  return CB_OK;
}
static void send_bytes(int fd, const unsigned char *data, size_t length) {
  sigset_t blocked, previous, pending;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  sigpending(&pending);
  int already_pending = sigismember(&pending, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, &previous);
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0)
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  size_t offset = 0;
  double deadline = now_seconds() + 2;
  int broken = 0;
  while (offset < length && now_seconds() < deadline) {
    ssize_t written = write(fd, data + offset, length - offset);
    if (written > 0)
      offset += (size_t)written;
    else if (written < 0 && (errno == EAGAIN || errno == EINTR)) {
      struct pollfd ready = {fd, POLLOUT, 0};
      poll(&ready, 1, 20);
    } else {
      broken = errno == EPIPE;
      break;
    }
  }
  if (broken && !already_pending) {
    struct timespec none = {0, 0};
    sigtimedwait(&blocked, NULL, &none);
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  close(fd);
}
static void source_send(void *data, struct zwlr_data_control_source_v1 *proxy,
                        const char *mime, int32_t fd) {
  (void)proxy;
  cw_source *source = data;
  if (!strcmp(mime, "x-kde-passwordManagerHint") && source->bundle->sensitive) {
    send_bytes(fd, (const unsigned char *)"secret", 6);
    return;
  }
  for (unsigned m = 0; m < MIME_COUNT; ++m)
    if (mime_formats[m] && !strcmp(mime, mime_names[m])) {
      for (size_t i = 0; i < source->bundle->count; ++i)
        if (source->bundle->payloads[i].format == mime_formats[m]) {
          cb_payload *payload = &source->bundle->payloads[i];
          send_bytes(fd, payload->data, payload->length);
          return;
        }
    }
  close(fd);
}
static void source_cancelled(void *data,
                             struct zwlr_data_control_source_v1 *proxy) {
  (void)proxy;
  cw_source *source = data;
  if (source->session->source == source)
    source->session->source = NULL;
  destroy_source(source);
}
static const struct zwlr_data_control_source_v1_listener source_listener = {
    .send = source_send, .cancelled = source_cancelled};
int cw_write(cw_session *s, const cb_payload *payloads, size_t count,
             int sensitive) {
  if (s->finished)
    return CB_UNSUPPORTED;
  if (!count || count > 8)
    return CB_INVALID;
  cw_source *source = calloc(1, sizeof(*source));
  if (!source)
    return CB_UNAVAILABLE;
  source->session = s;
  source->bundle = calloc(1, sizeof(*source->bundle));
  if (!source->bundle) {
    free(source);
    return CB_UNAVAILABLE;
  }
  source->bundle->sensitive = sensitive;
  for (size_t i = 0; i < count; ++i) {
    int known = 0;
    for (unsigned mime = 0; mime < MIME_COUNT; ++mime)
      if (mime_formats[mime] == payloads[i].format)
        known = 1;
    for (size_t previous = 0; previous < i; ++previous)
      if (payloads[previous].format == payloads[i].format)
        known = 0;
    int result = known ? cb_bundle_append(source->bundle, payloads[i].format,
                                          payloads[i].data, payloads[i].length,
                                          16 * 1024 * 1024)
                       : CB_INVALID;
    if (result < 0) {
      cb_bundle_free(source->bundle);
      free(source);
      return result;
    }
  }
  source->proxy = zwlr_data_control_manager_v1_create_data_source(s->manager);
  if (!source->proxy) {
    cb_bundle_free(source->bundle);
    free(source);
    return CB_UNAVAILABLE;
  }
  zwlr_data_control_source_v1_add_listener(source->proxy, &source_listener,
                                           source);
  for (unsigned mime = 0; mime < MIME_COUNT; ++mime) {
    for (size_t i = 0; i < source->bundle->count; ++i)
      if (mime_formats[mime] == source->bundle->payloads[i].format)
        zwlr_data_control_source_v1_offer(source->proxy, mime_names[mime]);
  }
  if (sensitive)
    zwlr_data_control_source_v1_offer(source->proxy,
                                      "x-kde-passwordManagerHint");
  cw_source *previous = s->source;
  s->source = source;
  zwlr_data_control_device_v1_set_selection(s->device, source->proxy);
  // Retire the old local proxy before dispatching its queued cancellation.
  destroy_source(previous);
  return roundtrip(s) ? CB_OK : CB_UNAVAILABLE;
}
#endif
