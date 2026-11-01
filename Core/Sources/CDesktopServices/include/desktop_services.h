#ifndef CLIPBOARD_DESKTOP_SERVICES_H
#define CLIPBOARD_DESKTOP_SERVICES_H
#include <stddef.h>
/* 1 success, 0 absent, -1 unavailable/locked, -2 invalid input. No content
 * logs. */
int cds_credential_read(const char *account, char **value);
int cds_credential_save(const char *account, const char *value);
int cds_credential_delete(const char *account);
/* Startup operations return -3 for an existing entry owned by another command. */
int cds_startup_read(const char *name, const char *command);
int cds_startup_set(const char *name, const char *command, int enabled);
int cds_ocr(const unsigned char *data, size_t length, const char *language,
            char **text);
void cds_free(void *value);
#endif
