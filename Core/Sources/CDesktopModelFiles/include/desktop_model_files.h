#ifndef CLIPBOARD_DESKTOP_MODEL_FILES_H
#define CLIPBOARD_DESKTOP_MODEL_FILES_H

/* Nonblocking, no-follow exclusive lease. NULL means unavailable or busy.
 * Creation never replaces an existing file; close does not unlink it. */
void *clipboard_model_stage_lock(const char *path, int create);
void clipboard_model_stage_unlock(void *lease);

#endif
