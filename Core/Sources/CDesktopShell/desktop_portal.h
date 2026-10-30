#ifndef CLIPBOARD_DESKTOP_PORTAL_H
#define CLIPBOARD_DESKTOP_PORTAL_H
#include "desktop_shell.h"
typedef struct clipboard_portal clipboard_portal;
/* 0 inactive, 1 pending, 2 permission required, 3 active, 4 denied, 5
 * unavailable. */
clipboard_portal *cp_create(const char *key, uint32_t modifiers,
                            clipboard_shell_callback callback, void *context);
unsigned cp_status(clipboard_portal *portal);
void cp_request(clipboard_portal *portal);
int cp_take_token(clipboard_portal *portal, char *buffer, unsigned capacity);
void cp_destroy(clipboard_portal *portal);
#endif
