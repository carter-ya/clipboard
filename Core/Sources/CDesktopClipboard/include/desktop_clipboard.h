#ifndef DESKTOP_CLIPBOARD_H
#define DESKTOP_CLIPBOARD_H
#include <stddef.h>
#include <stdint.h>

typedef struct cb_session cb_session;
enum {
  CB_OK = 1,
  CB_EMPTY = 0,
  CB_UNAVAILABLE = -1,
  CB_TOO_LARGE = -2,
  CB_TIMEOUT = -3,
  CB_UNSUPPORTED = -4,
  CB_INVALID = -5
};
cb_session *cb_open(void);
cb_session *cb_open_rich(const char *wayland_display, int *error);
void cb_close(cb_session *session);
int cb_connection_fd(cb_session *session);
void cb_pump(cb_session *session);
int cb_pending_transfers(cb_session *session);
uint64_t cb_revision(cb_session *session);
int cb_read_utf8(cb_session *session, size_t max_bytes, char **data,
                 size_t *length, int *sensitive, uint64_t *revision);
int cb_write_utf8(cb_session *session, const char *data, size_t length,
                  int sensitive);
void cb_free(void *data);
enum {
  CB_TEXT = 1,
  CB_HTML = 2,
  CB_RTF = 3,
  CB_PNG = 4,
  CB_JPEG = 5,
  CB_BMP = 6,
  CB_FILES = 7,
  CB_TIFF = 8
};
typedef struct cb_payload {
  int format;
  unsigned char *data;
  size_t length;
} cb_payload;
typedef struct cb_bundle {
  cb_payload *payloads;
  size_t count;
  int sensitive;
  uint64_t revision;
  char *source_app;
} cb_bundle;
int cb_read_bundle(cb_session *session, size_t max_bytes, cb_bundle **bundle);
int cb_write_bundle(cb_session *session, const cb_payload *payloads,
                    size_t count, int sensitive);
void cb_bundle_free(cb_bundle *bundle);
#endif
