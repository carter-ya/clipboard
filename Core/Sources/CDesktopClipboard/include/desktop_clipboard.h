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
void cb_close(cb_session *session);
int cb_connection_fd(cb_session *session);
void cb_pump(cb_session *session);
uint64_t cb_revision(cb_session *session);
int cb_read_utf8(cb_session *session, size_t max_bytes, char **data,
                 size_t *length, int *sensitive, uint64_t *revision);
int cb_write_utf8(cb_session *session, const char *data, size_t length,
                  int sensitive);
void cb_free(void *data);
#endif
