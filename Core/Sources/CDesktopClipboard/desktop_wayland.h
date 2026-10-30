#ifndef CLIPBOARD_DESKTOP_WAYLAND_H
#define CLIPBOARD_DESKTOP_WAYLAND_H
#include "desktop_clipboard.h"
typedef struct cw_session cw_session;
cw_session *cw_open(const char *display_name, int *error);
void cw_close(cw_session *session);
int cw_fd(cw_session *session);
void cw_pump(cw_session *session);
uint64_t cw_revision(cw_session *session);
int cw_read(cw_session *session, size_t max, cb_bundle **out);
int cw_write(cw_session *session, const cb_payload *payloads, size_t count,
             int sensitive);
int cb_bundle_append(cb_bundle *bundle, int format, const unsigned char *data,
                     size_t length, size_t max);
#endif
