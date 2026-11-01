#ifndef CLIPBOARD_DESKTOP_SHELL_H
#define CLIPBOARD_DESKTOP_SHELL_H
#include <stdint.h>
typedef struct clipboard_shell clipboard_shell;
typedef void (*clipboard_shell_callback)(void *context, int32_t action);
/* Key is an ASCII letter/digit, F1...F24, SPACE, or empty to disable binding.
   Modifiers: control=1, alt=2, shift=4, super=8. Errors: unavailable=1,
   conflict=2. */
clipboard_shell *clipboard_shell_create(const char *key, uint32_t modifiers,
                                        int recording,
                                        clipboard_shell_callback callback,
                                        void *context, int *error);
uint32_t clipboard_shell_capabilities(clipboard_shell *shell);
uint32_t clipboard_shell_activation_time(clipboard_shell *shell);
void clipboard_shell_set_recording(clipboard_shell *shell, int recording);
void clipboard_shell_destroy(clipboard_shell *shell);
#endif

#ifndef CLIPBOARD_DESKTOP_INSTANCE_H
#define CLIPBOARD_DESKTOP_INSTANCE_H
typedef struct clipboard_instance clipboard_instance;
/* identity is a lowercase SHA-256 hex string. status: primary=1, secondary=0,
 * error=-1. */
clipboard_instance *clipboard_instance_create(const char *identity,
                                              clipboard_shell_callback callback,
                                              void *context, int *status);
void clipboard_instance_destroy(clipboard_instance *instance);
#endif
