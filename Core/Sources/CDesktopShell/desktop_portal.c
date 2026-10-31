#include "desktop_portal.h"
#if defined(__linux__)
#include <dbus/dbus.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#define DEST "org.freedesktop.portal.Desktop"
#define ROOT "/org/freedesktop/portal/desktop"
#define SHORTCUTS "org.freedesktop.portal.GlobalShortcuts"
struct clipboard_portal {
  pthread_t thread;
  atomic_int stopping, requested;
  atomic_uint status;
  int wake[2], stage, bound;
  double deadline;
  DBusConnection *bus;
  char *owner, *request, *session;
  char trigger[128];
  clipboard_shell_callback callback;
  void *context;
};
static double monotonic(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return now.tv_sec + now.tv_nsec / 1000000000.0;
}
static void status(clipboard_portal *p, unsigned value) {
  if (atomic_exchange(&p->status, value) != value && !atomic_load(&p->stopping))
    p->callback(p->context, 6, NULL);
}
static void string(DBusMessageIter *iter, const char *value) {
  dbus_message_iter_append_basic(iter, DBUS_TYPE_STRING, &value);
}
static void property(DBusMessageIter *dict, const char *key,
                     const char *value) {
  DBusMessageIter entry, variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
  string(&entry, key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
  string(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}
static void options(DBusMessageIter *iter, const char *token, int create) {
  DBusMessageIter dict;
  dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
  property(&dict, "handle_token", token);
  if (create)
    property(&dict, "session_handle_token", "clipboard_history");
  dbus_message_iter_close_container(iter, &dict);
}
static DBusMessage *method(const char *name) {
  return dbus_message_new_method_call(DEST, ROOT, SHORTCUTS, name);
}
static void close_object(clipboard_portal *p, const char *path,
                         const char *interface) {
  if (!p->bus || !path)
    return;
  DBusMessage *call =
      dbus_message_new_method_call(DEST, path, interface, "Close");
  if (!call)
    return;
  dbus_message_set_no_reply(call, TRUE);
  dbus_connection_send(p->bus, call, NULL);
  dbus_message_unref(call);
}
static int send_request(clipboard_portal *p, DBusMessage *call, int stage) {
  if (!call)
    return 0;
  DBusError error;
  dbus_error_init(&error);
  // Only the immediate request-handle reply is synchronous. User approval is a
  // later signal; this private worker never blocks the GTK main context.
  DBusMessage *reply =
      dbus_connection_send_with_reply_and_block(p->bus, call, 2000, &error);
  dbus_error_free(&error);
  dbus_message_unref(call);
  if (!reply)
    return 0;
  const char *path = NULL;
  int okay = dbus_message_get_args(reply, NULL, DBUS_TYPE_OBJECT_PATH, &path,
                                   DBUS_TYPE_INVALID);
  if (okay) {
    const char *sender = dbus_message_get_sender(reply);
    if (!sender)
      okay = 0;
    else {
      free(p->owner);
      p->owner = strdup(sender);
      free(p->request);
      p->request = strdup(path);
      p->stage = stage;
      p->deadline = monotonic() + (stage == 3 ? 120 : 5);
    }
  }
  dbus_message_unref(reply);
  return okay;
}
static int list(clipboard_portal *p) {
  DBusMessage *call = method("ListShortcuts");
  if (!call)
    return 0;
  DBusMessageIter iter;
  dbus_message_iter_init_append(call, &iter);
  dbus_message_iter_append_basic(&iter, DBUS_TYPE_OBJECT_PATH, &p->session);
  options(&iter, "clipboard_list", 0);
  return send_request(p, call, 2);
}
static int bind(clipboard_portal *p) {
  if (p->bound || !p->session)
    return 0;
  DBusMessage *call = method("BindShortcuts");
  if (!call)
    return 0;
  DBusMessageIter iter, array, item, dict;
  dbus_message_iter_init_append(call, &iter);
  dbus_message_iter_append_basic(&iter, DBUS_TYPE_OBJECT_PATH, &p->session);
  dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(sa{sv})", &array);
  dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, NULL, &item);
  string(&item, "history");
  dbus_message_iter_open_container(&item, DBUS_TYPE_ARRAY, "{sv}", &dict);
  property(&dict, "description", "Show Clipboard history");
  property(&dict, "preferred_trigger", p->trigger);
  dbus_message_iter_close_container(&item, &dict);
  dbus_message_iter_close_container(&array, &item);
  dbus_message_iter_close_container(&iter, &array);
  string(&iter, "");
  options(&iter, "clipboard_bind", 0);
  p->bound = 1;
  status(p, 1);
  return send_request(p, call, 3);
}
static int dictionary(DBusMessageIter *input, const char *key,
                      DBusMessageIter *value) {
  if (dbus_message_iter_get_arg_type(input) != DBUS_TYPE_ARRAY)
    return 0;
  DBusMessageIter entries;
  dbus_message_iter_recurse(input, &entries);
  while (dbus_message_iter_get_arg_type(&entries) == DBUS_TYPE_DICT_ENTRY) {
    DBusMessageIter entry;
    dbus_message_iter_recurse(&entries, &entry);
    const char *name = NULL;
    if (dbus_message_iter_get_arg_type(&entry) != DBUS_TYPE_STRING)
      return 0;
    dbus_message_iter_get_basic(&entry, &name);
    dbus_message_iter_next(&entry);
    if (!strcmp(name, key) &&
        dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT) {
      dbus_message_iter_recurse(&entry, value);
      return 1;
    }
    dbus_message_iter_next(&entries);
  }
  return 0;
}
static int contains_history(DBusMessageIter *value) {
  if (dbus_message_iter_get_arg_type(value) != DBUS_TYPE_ARRAY)
    return 0;
  DBusMessageIter entries;
  dbus_message_iter_recurse(value, &entries);
  while (dbus_message_iter_get_arg_type(&entries) == DBUS_TYPE_STRUCT) {
    DBusMessageIter entry;
    dbus_message_iter_recurse(&entries, &entry);
    const char *name = NULL;
    if (dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_STRING) {
      dbus_message_iter_get_basic(&entry, &name);
      if (!strcmp(name, "history"))
        return 1;
    }
    dbus_message_iter_next(&entries);
  }
  return 0;
}
static DBusHandlerResult signal_received(DBusConnection *bus,
                                         DBusMessage *message, void *data) {
  (void)bus;
  clipboard_portal *p = data;
  if (dbus_message_has_sender(message, DBUS_SERVICE_DBUS) &&
      dbus_message_is_signal(message, DBUS_INTERFACE_DBUS,
                             "NameOwnerChanged")) {
    const char *name, *old_owner, *new_owner;
    if (dbus_message_get_args(message, NULL, DBUS_TYPE_STRING, &name,
                              DBUS_TYPE_STRING, &old_owner, DBUS_TYPE_STRING,
                              &new_owner, DBUS_TYPE_INVALID) &&
        !strcmp(name, DEST) && p->owner && !strcmp(old_owner, p->owner) &&
        strcmp(new_owner, p->owner)) {
      free(p->session);
      p->session = NULL;
      free(p->request);
      p->request = NULL;
      p->stage = 0;
      status(p, 5);
    }
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }

  if (!p->owner || !dbus_message_has_sender(message, p->owner))
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  const char *path = dbus_message_get_path(message);
  if (p->request && path && !strcmp(path, p->request) &&
      dbus_message_is_signal(message, "org.freedesktop.portal.Request",
                             "Response")) {
    DBusMessageIter iter, value;
    dbus_uint32_t response;
    if (!dbus_message_iter_init(message, &iter) ||
        dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_UINT32) {
      status(p, 5);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    dbus_message_iter_get_basic(&iter, &response);
    dbus_message_iter_next(&iter);
    int stage = p->stage;
    p->stage = 0;
    free(p->request);
    p->request = NULL;
    if (response) {
      status(p, response == 1 ? 4 : 5);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (stage == 1) {
      const char *session = NULL;
      if (!dictionary(&iter, "session_handle", &value) ||
          dbus_message_iter_get_arg_type(&value) != DBUS_TYPE_STRING) {
        status(p, 5);
        return DBUS_HANDLER_RESULT_HANDLED;
      }
      dbus_message_iter_get_basic(&value, &session);
      if (!dbus_validate_path(session, NULL)) {
        status(p, 5);
        return DBUS_HANDLER_RESULT_HANDLED;
      }
      free(p->session);
      p->session = strdup(session);
      if (!list(p))
        status(p, 5);
    } else {
      int has_history =
          dictionary(&iter, "shortcuts", &value) && contains_history(&value);
      if (stage == 2) {
        // Restore only a previously approved binding. First setup requires the
        // explicit settings action; merely logging in never asks for new
        // access.
        if (has_history || atomic_exchange(&p->requested, 0)) {
          if (!bind(p))
            status(p, 5);
        } else
          status(p, 2);
      } else if (stage == 3)
        status(p, has_history ? 3 : 4);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (p->session && path && !strcmp(path, p->session) &&
      dbus_message_is_signal(message, "org.freedesktop.portal.Session",
                             "Closed")) {
    free(p->session);
    p->session = NULL;
    status(p, 5);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (p->session && path && !strcmp(path, ROOT) &&
      (dbus_message_is_signal(message, SHORTCUTS, "Activated") ||
       dbus_message_is_signal(message, SHORTCUTS, "ShortcutsChanged"))) {
    DBusMessageIter iter, options_iter, value;
    const char *session = NULL;
    if (!dbus_message_iter_init(message, &iter) ||
        dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_OBJECT_PATH)
      return DBUS_HANDLER_RESULT_HANDLED;
    dbus_message_iter_get_basic(&iter, &session);
    if (strcmp(session, p->session))
      return DBUS_HANDLER_RESULT_HANDLED;
    dbus_message_iter_next(&iter);
    if (dbus_message_is_signal(message, SHORTCUTS, "ShortcutsChanged")) {
      status(p, contains_history(&iter) ? 3 : 4);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    const char *id = NULL;
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING)
      return DBUS_HANDLER_RESULT_HANDLED;
    dbus_message_iter_get_basic(&iter, &id);
    if (strcmp(id, "history") || atomic_load(&p->status) != 3)
      return DBUS_HANDLER_RESULT_HANDLED;
    dbus_message_iter_next(&iter);
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_UINT64)
      return DBUS_HANDLER_RESULT_HANDLED;
    dbus_message_iter_next(&iter);
    options_iter = iter;
    const char *token = NULL;
    if (dictionary(&options_iter, "activation_token", &value) &&
        dbus_message_iter_get_arg_type(&value) == DBUS_TYPE_STRING) {
      dbus_message_iter_get_basic(&value, &token);
      if (!*token || strlen(token) >= 4096)
        token = NULL;
    }
    if (!atomic_load(&p->stopping))
      p->callback(p->context, 2, token);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}
static void *worker(void *data) {
  clipboard_portal *p = data;
  DBusError error;
  dbus_error_init(&error);
  p->bus = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
  dbus_error_free(&error);
  if (!p->bus) {
    status(p, 5);
    return NULL;
  }
  dbus_connection_set_exit_on_disconnect(p->bus, FALSE);
  dbus_connection_add_filter(p->bus, signal_received, p, NULL);
  const char *matches[] = {
      "type='signal',sender='org.freedesktop.portal.Desktop',interface='org."
      "freedesktop.portal.Request'",
      "type='signal',sender='org.freedesktop.portal.Desktop',interface='org."
      "freedesktop.portal.GlobalShortcuts'",
      "type='signal',sender='org.freedesktop.portal.Desktop',interface='org."
      "freedesktop.portal.Session'"};
  for (unsigned i = 0; i < 3; ++i)
    dbus_bus_add_match(p->bus, matches[i], NULL);
  dbus_bus_add_match(
      p->bus,
      "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop."
      "DBus',member='NameOwnerChanged',arg0='org.freedesktop.portal.Desktop'",
      NULL);
  // Unsandboxed applications need a stable desktop-file identity on this
  // connection before their first portal call. Installation supplies this file.
  DBusMessage *registration = dbus_message_new_method_call(
      DEST, ROOT, "org.freedesktop.host.portal.Registry", "Register");
  if (registration) {
    DBusMessageIter iter, dict;
    dbus_message_iter_init_append(registration, &iter);
    string(&iter, "com.clipboard.desktop");
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    dbus_message_iter_close_container(&iter, &dict);
    DBusError registration_error;
    dbus_error_init(&registration_error);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(
        p->bus, registration, 2000, &registration_error);
    // Older portals may identify host processes without the Registry interface.
    // The subsequent CreateSession still must succeed; registration failure
    // never creates an active capability.
    if (reply)
      dbus_message_unref(reply);
    dbus_error_free(&registration_error);
    dbus_message_unref(registration);
  }
  DBusMessage *call = method("CreateSession");
  if (call) {
    DBusMessageIter iter;
    dbus_message_iter_init_append(call, &iter);
    options(&iter, "clipboard_create", 1);
  }
  if (!send_request(p, call, 1))
    status(p, 5);
  while (!atomic_load(&p->stopping) &&
         dbus_connection_get_is_connected(p->bus)) {
    dbus_connection_read_write(p->bus, 0);
    while (dbus_connection_dispatch(p->bus) == DBUS_DISPATCH_DATA_REMAINS) {
    }
    if (atomic_load(&p->requested) && p->session && !p->stage && !p->bound) {
      atomic_store(&p->requested, 0);
      if (!bind(p))
        status(p, 5);
    }
    if (p->stage && monotonic() > p->deadline) {
      close_object(p, p->request, "org.freedesktop.portal.Request");
      free(p->request);
      p->request = NULL;
      p->stage = 0;
      status(p, 5);
    }
    int fd = -1;
    dbus_connection_get_unix_fd(p->bus, &fd);
    struct pollfd ready[] = {{p->wake[0], POLLIN, 0}, {fd, POLLIN, 0}};
    int wait = p->stage ? 250 : -1;
    int result = poll(ready, 2, wait);
    if (result < 0 && errno != EINTR)
      break;
    if (ready[0].revents & POLLIN) {
      char bytes[32];
      while (read(p->wake[0], bytes, sizeof(bytes)) > 0) {
      }
    }
  }
  close_object(p, p->request, "org.freedesktop.portal.Request");
  close_object(p, p->session, "org.freedesktop.portal.Session");
  dbus_connection_flush(p->bus);
  dbus_connection_close(p->bus);
  dbus_connection_unref(p->bus);
  p->bus = NULL;
  status(p, 5);
  return NULL;
}
clipboard_portal *cp_create(const char *key, uint32_t modifiers,
                            clipboard_shell_callback callback, void *context) {
  clipboard_portal *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  p->callback = callback;
  p->context = context;
  atomic_init(&p->status, 1);
  snprintf(p->trigger, sizeof(p->trigger), "%s%s%s%s%s",
           modifiers & 1 ? "CTRL+" : "", modifiers & 2 ? "ALT+" : "",
           modifiers & 4 ? "SHIFT+" : "", modifiers & 8 ? "LOGO+" : "",
           !strcmp(key, "SPACE") ? "space" : key);
  if (pipe(p->wake) != 0) {
    free(p);
    return NULL;
  }
  for (unsigned i = 0; i < 2; ++i) {
    fcntl(p->wake[i], F_SETFL, O_NONBLOCK);
    fcntl(p->wake[i], F_SETFD, FD_CLOEXEC);
  }
  if (pthread_create(&p->thread, NULL, worker, p) != 0) {
    close(p->wake[0]);
    close(p->wake[1]);
    free(p);
    return NULL;
  }
  return p;
}
unsigned cp_status(clipboard_portal *p) {
  return p ? atomic_load(&p->status) : 5;
}
void cp_request(clipboard_portal *p) {
  if (p) {
    atomic_store(&p->requested, 1);
    char byte = 1;
    ssize_t ignored = write(p->wake[1], &byte, 1);
    (void)ignored;
  }
}
void cp_destroy(clipboard_portal *p) {
  if (!p)
    return;
  atomic_store(&p->stopping, 1);
  cp_request(p);
  pthread_join(p->thread, NULL);
  close(p->wake[0]);
  close(p->wake[1]);
  free(p->owner);
  free(p->request);
  free(p->session);
  free(p);
}
#endif
