#include "desktop_shell.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <shellapi.h>

#define SHELL_NOTIFY (WM_APP + 320)
#define SHELL_RECORDING (WM_APP + 321)
#define SHELL_STOP (WM_APP + 322)
struct clipboard_shell {
  HANDLE thread, ready;
  HWND window;
  DWORD thread_id;
  volatile LONG capabilities, recording, chinese;
  int error;
  char key[32];
  uint32_t modifiers;
  UINT taskbar_created;
  clipboard_shell_callback callback;
  void *context;
};
static void emit(clipboard_shell *s, int32_t action) {
  if (s->callback)
    s->callback(s->context, action);
}
static UINT virtual_key(const char *key) {
  size_t size = strlen(key);
  if (size == 1 &&
      ((key[0] >= 'A' && key[0] <= 'Z') || (key[0] >= '0' && key[0] <= '9')))
    return (UINT)key[0];
  if (!strcmp(key, "SPACE"))
    return VK_SPACE;
  if (key[0] == 'F') {
    char *end = NULL;
    long number = strtol(key + 1, &end, 10);
    if (end && !*end && number >= 1 && number <= 24)
      return VK_F1 + (UINT)number - 1;
  }
  return 0;
}
static const WCHAR *tray_title(clipboard_shell *s) {
  int recording = InterlockedCompareExchange(&s->recording, 0, 0) != 0;
  if (InterlockedCompareExchange(&s->chinese, 0, 0))
    return recording ? L"Clipboard - 正在录制" : L"Clipboard - 已暂停";
  return recording ? L"Clipboard - recording" : L"Clipboard - paused";
}
static int add_icon(clipboard_shell *s) {
  NOTIFYICONDATAW data = {0};
  data.cbSize = sizeof(data);
  data.hWnd = s->window;
  data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = SHELL_NOTIFY;
  data.hIcon = LoadIconW(NULL, MAKEINTRESOURCEW(32512));
  const WCHAR *tip = tray_title(s);
  lstrcpynW(data.szTip, tip, 128);
  int added = Shell_NotifyIconW(NIM_ADD, &data) != 0;
  if (added) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
  }
  LONG caps = InterlockedCompareExchange(&s->capabilities, 0, 0);
  InterlockedExchange(&s->capabilities, added ? caps | 1 : caps & ~1);
  return added;
}
static void refresh_icon(clipboard_shell *s) {
  NOTIFYICONDATAW data = {0};
  data.cbSize = sizeof(data);
  data.hWnd = s->window;
  data.uID = 1;
  data.uFlags = NIF_TIP;
  lstrcpynW(data.szTip, tray_title(s), 128);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}
static void show_menu(clipboard_shell *s) {
  HMENU menu = CreatePopupMenu();
  if (!menu)
    return;
  int chinese = InterlockedCompareExchange(&s->chinese, 0, 0) != 0;
  AppendMenuW(menu, MF_STRING, 1, chinese ? L"显示历史" : L"Show history");
  AppendMenuW(menu, MF_STRING, 2,
              InterlockedCompareExchange(&s->recording, 0, 0)
                  ? (chinese ? L"暂停录制" : L"Pause recording")
                  : (chinese ? L"开始录制" : L"Start recording"));
  AppendMenuW(menu, MF_STRING, 3, chinese ? L"设置" : L"Settings");
  AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
  AppendMenuW(menu, MF_STRING, 4, chinese ? L"退出" : L"Quit");
  POINT point = {0};
  GetCursorPos(&point);
  SetForegroundWindow(s->window);
  UINT selected =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                     point.x, point.y, 0, s->window, NULL);
  DestroyMenu(menu);
  if (selected == 1)
    emit(s, 2);
  else if (selected == 2)
    emit(s, 4);
  else if (selected == 3)
    emit(s, 3);
  else if (selected == 4)
    emit(s, 5);
  PostMessageW(s->window, WM_NULL, 0, 0);
}
static LRESULT CALLBACK shell_window_proc(HWND window, UINT message, WPARAM w,
                                          LPARAM l) {
  clipboard_shell *s =
      (clipboard_shell *)GetWindowLongPtrW(window, GWLP_USERDATA);
  if (message == WM_NCCREATE) {
    s = (clipboard_shell *)((CREATESTRUCTW *)l)->lpCreateParams;
    SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)s);
  }
  if (!s)
    return DefWindowProcW(window, message, w, l);
  if (s->taskbar_created && message == s->taskbar_created) {
    add_icon(s);
    emit(s, 6);
    return 0;
  }
  if (message == WM_HOTKEY) {
    emit(s, 1);
    return 0;
  }
  if (message == SHELL_NOTIFY) {
    UINT event = LOWORD(l);
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP)
      show_menu(s);
    else if (event == NIN_SELECT || event == NIN_KEYSELECT ||
             event == WM_LBUTTONUP)
      emit(s, 1);
    return 0;
  }
  if (message == SHELL_RECORDING) {
    refresh_icon(s);
    return 0;
  }
  if (message == SHELL_STOP) {
    DestroyWindow(window);
    return 0;
  }
  if (message == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, message, w, l);
}
static DWORD WINAPI shell_thread(void *value) {
  clipboard_shell *s = value;
  HINSTANCE instance = GetModuleHandleW(NULL);
  WNDCLASSW type = {0};
  type.lpfnWndProc = shell_window_proc;
  type.hInstance = instance;
  type.lpszClassName = L"ClipboardDesktopShell";
  RegisterClassW(&type);
  s->taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  s->window = CreateWindowExW(0, type.lpszClassName, L"Clipboard", WS_POPUP, 0,
                              0, 0, 0, NULL, NULL, instance, s);
  if (!s->window) {
    s->error = 1;
    SetEvent(s->ready);
    return 0;
  }
  add_icon(s);
  if (s->key[0]) {
    UINT key = virtual_key(s->key), mods = MOD_NOREPEAT;
    if (s->modifiers & 1)
      mods |= MOD_CONTROL;
    if (s->modifiers & 2)
      mods |= MOD_ALT;
    if (s->modifiers & 4)
      mods |= MOD_SHIFT;
    if (s->modifiers & 8)
      mods |= MOD_WIN;
    if (key && RegisterHotKey(s->window, 1, mods, key))
      InterlockedOr(&s->capabilities, 2);
    else
      s->error = 2;
  }
  SetEvent(s->ready);
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  UnregisterHotKey(s->window, 1);
  NOTIFYICONDATAW data = {0};
  data.cbSize = sizeof(data);
  data.hWnd = s->window;
  data.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &data);
  InterlockedExchange(&s->capabilities, 0);
  UnregisterClassW(type.lpszClassName, instance);
  return 0;
}
clipboard_shell *clipboard_shell_create(const char *key, uint32_t modifiers,
                                        int recording,
                                        clipboard_shell_callback callback,
                                        void *context, int *error) {
  if (error)
    *error = 1;
  clipboard_shell *s = calloc(1, sizeof(*s));
  if (!s || !key || strlen(key) >= sizeof(s->key)) {
    free(s);
    return NULL;
  }
  strcpy(s->key, key);
  s->modifiers = modifiers;
  s->recording = recording;
  s->callback = callback;
  s->context = context;
  s->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!s->ready) {
    free(s);
    return NULL;
  }
  s->thread = CreateThread(NULL, 0, shell_thread, s, 0, &s->thread_id);
  if (!s->thread) {
    CloseHandle(s->ready);
    free(s);
    return NULL;
  }
  WaitForSingleObject(s->ready, INFINITE);
  if (!s->window) {
    WaitForSingleObject(s->thread, INFINITE);
    CloseHandle(s->thread);
    CloseHandle(s->ready);
    free(s);
    return NULL;
  }
  if (error)
    *error = s->error;
  return s;
}
uint32_t clipboard_shell_capabilities(clipboard_shell *s) {
  return s ? (uint32_t)InterlockedCompareExchange(&s->capabilities, 0, 0) : 0;
}
uint32_t clipboard_shell_activation_time(clipboard_shell *s) {
  (void)s;
  return 0;
}
void clipboard_shell_set_language(clipboard_shell *s, int chinese) {
  if (!s)
    return;
  InterlockedExchange(&s->chinese, chinese != 0);
  PostMessageW(s->window, SHELL_RECORDING, 0, 0);
}
void clipboard_shell_set_recording(clipboard_shell *s, int recording) {
  if (!s)
    return;
  InterlockedExchange(&s->recording, recording);
  PostMessageW(s->window, SHELL_RECORDING, 0, 0);
}
void clipboard_shell_destroy(clipboard_shell *s) {
  if (!s)
    return;
  PostMessageW(s->window, WM_CANCELMODE, 0, 0);
  PostMessageW(s->window, SHELL_STOP, 0, 0);
  WaitForSingleObject(s->thread, INFINITE);
  CloseHandle(s->thread);
  CloseHandle(s->ready);
  free(s);
}
#elif defined(__linux__)
/* Linux implementation follows below. */
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/keysym.h>
#include <dbus/dbus.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

struct clipboard_shell {
  pthread_t thread;
  pthread_mutex_t lock;
  pthread_cond_t ready_condition;
  int ready, error, wake[2], needs_registration;
  atomic_int stopping, recording, chinese;
  atomic_uint capabilities, activation_time;
  Display *display;
  Window root;
  unsigned keycode, modifiers, num_lock;
  int pressed, detectable_repeat;
  DBusConnection *bus;
  dbus_uint32_t menu_revision;
  char key[32];
  clipboard_shell_callback callback;
  void *context;
};
static void emit(clipboard_shell *s, int32_t action) {
  if (!atomic_load(&s->stopping) && s->callback)
    s->callback(s->context, action);
}
static pthread_mutex_t grab_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(Display *) trap_display;
static atomic_int grab_failed;
static _Atomic(XErrorHandler) previous_error_handler;
static int grab_error_handler(Display *display, XErrorEvent *event) {
  if (display == atomic_load(&trap_display) &&
      event->request_code == X_GrabKey) {
    atomic_store(&grab_failed, 1);
    return 0;
  }
  XErrorHandler previous = atomic_load(&previous_error_handler);
  return previous ? previous(display, event) : 0;
}
static void each_grab(clipboard_shell *s, int acquire) {
  unsigned masks[] = {0, LockMask, s->num_lock, LockMask | s->num_lock};
  for (unsigned i = 0; i < 4; ++i) {
    int duplicate = 0;
    for (unsigned j = 0; j < i; ++j)
      if (masks[i] == masks[j])
        duplicate = 1;
    if (duplicate)
      continue;
    unsigned modifiers = s->modifiers | masks[i];
    if (acquire)
      XGrabKey(s->display, (int)s->keycode, modifiers, s->root, False,
               GrabModeAsync, GrabModeAsync);
    else
      XUngrabKey(s->display, (int)s->keycode, modifiers, s->root);
  }
}
static int bind_x11(clipboard_shell *s, uint32_t modifiers) {
  if (!s->key[0])
    return 0;
  /* XWayland is not a native Wayland global-shortcut implementation. */
  if (getenv("WAYLAND_DISPLAY"))
    return 1;
  XInitThreads();
  s->display = XOpenDisplay(NULL);
  if (!s->display)
    return 1;
  s->root = DefaultRootWindow(s->display);
  KeySym symbol = XStringToKeysym(!strcmp(s->key, "SPACE") ? "space" : s->key);
  s->keycode = XKeysymToKeycode(s->display, symbol);
  if (!s->keycode)
    return 1;
  s->modifiers = 0;
  if (modifiers & 1)
    s->modifiers |= ControlMask;
  if (modifiers & 2)
    s->modifiers |= Mod1Mask;
  if (modifiers & 4)
    s->modifiers |= ShiftMask;
  if (modifiers & 8)
    s->modifiers |= Mod4Mask;
  KeyCode num = XKeysymToKeycode(s->display, XK_Num_Lock);
  XModifierKeymap *map = XGetModifierMapping(s->display);
  if (map) {
    for (unsigned modifier = 0; modifier < 8; ++modifier)
      for (int key = 0; key < map->max_keypermod; ++key)
        if (num && map->modifiermap[modifier * map->max_keypermod + key] == num)
          s->num_lock = 1U << modifier;
    XFreeModifiermap(map);
  }
  XSelectInput(s->display, s->root, KeyPressMask | KeyReleaseMask);
  Bool supported = False;
  XkbSetDetectableAutoRepeat(s->display, True, &supported);
  s->detectable_repeat = supported;
  pthread_mutex_lock(&grab_lock);
  XSync(s->display, False);
  atomic_store(&grab_failed, 0);
  atomic_store(&trap_display, s->display);
  XErrorHandler previous = XSetErrorHandler(grab_error_handler);
  atomic_store(&previous_error_handler, previous);
  each_grab(s, 1);
  XSync(s->display, False);
  int failed = atomic_load(&grab_failed);
  XSetErrorHandler(previous);
  atomic_store(&trap_display, NULL);
  pthread_mutex_unlock(&grab_lock);
  if (failed) {
    each_grab(s, 0);
    XSync(s->display, False);
    return 2;
  }
  atomic_fetch_or(&s->capabilities, 2);
  return 0;
}
static void dispatch_x11_key_press(clipboard_shell *s, const XKeyEvent *event) {
  unsigned keyboard_modifiers = ShiftMask | ControlMask | Mod1Mask | Mod2Mask |
                                Mod3Mask | Mod4Mask | Mod5Mask;
  unsigned state = event->state & keyboard_modifiers & ~s->num_lock;
  if ((atomic_load(&s->capabilities) & 2) && event->keycode == s->keycode &&
      state == s->modifiers) {
    if (!s->pressed) {
      atomic_store(&s->activation_time, (unsigned)event->time);
      emit(s, 1);
    }
    s->pressed = 1;
  }
}
static void pump_x11(clipboard_shell *s) {
  if (!s->display)
    return;
  while (XPending(s->display)) {
    XEvent event;
    XNextEvent(s->display, &event);
    if (event.type == KeyPress) {
      dispatch_x11_key_press(s, &event.xkey);    } else if (event.type == KeyRelease && event.xkey.keycode == s->keycode) {
      if (!s->detectable_repeat && XPending(s->display)) {
        XEvent next;
        XPeekEvent(s->display, &next);
        if (next.type == KeyPress && next.xkey.keycode == event.xkey.keycode &&
            next.xkey.time == event.xkey.time)
          continue;
      }
      s->pressed = 0;
    }
  }
}
static void send_reply(DBusConnection *connection, DBusMessage *message) {
  if (!message)
    return;
  dbus_connection_send(connection, message, NULL);
  dbus_message_unref(message);
}
static void append_string(DBusMessageIter *iter, const char *value) {
  dbus_message_iter_append_basic(iter, DBUS_TYPE_STRING, &value);
}
static void string_property(DBusMessageIter *dict, const char *name,
                            const char *value) {
  DBusMessageIter entry, variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
  append_string(&entry, name);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
  append_string(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}
static void boolean_property(DBusMessageIter *dict, const char *name,
                             dbus_bool_t value) {
  DBusMessageIter entry, variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
  append_string(&entry, name);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &variant);
  dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}
static const char *item_signature(const char *property) {
  if (!strcmp(property, "Menu"))
    return "o";
  if (!strcmp(property, "ItemIsMenu"))
    return "b";
  if (!strcmp(property, "WindowId"))
    return "u";
  if (!strcmp(property, "IconPixmap"))
    return "a(iiay)";
  if (!strcmp(property, "ToolTip"))
    return "(sa(iiay)ss)";
  if (!strcmp(property, "Category") || !strcmp(property, "Id") ||
      !strcmp(property, "Title") || !strcmp(property, "Status") ||
      !strcmp(property, "IconName") || !strcmp(property, "IconThemePath"))
    return "s";
  return NULL;
}
static void append_item_value(clipboard_shell *s, DBusMessageIter *iter,
                              const char *property) {
  if (!strcmp(property, "Menu")) {
    const char *path = "/MenuBar";
    dbus_message_iter_append_basic(iter, DBUS_TYPE_OBJECT_PATH, &path);
  } else if (!strcmp(property, "ItemIsMenu")) {
    dbus_bool_t value = FALSE;
    dbus_message_iter_append_basic(iter, DBUS_TYPE_BOOLEAN, &value);
  } else if (!strcmp(property, "WindowId")) {
    dbus_uint32_t value = 0;
    dbus_message_iter_append_basic(iter, DBUS_TYPE_UINT32, &value);
  } else if (!strcmp(property, "IconPixmap")) {
    DBusMessageIter array;
    dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "(iiay)", &array);
    dbus_message_iter_close_container(iter, &array);
  } else if (!strcmp(property, "ToolTip")) {
    DBusMessageIter structure, array;
    dbus_message_iter_open_container(iter, DBUS_TYPE_STRUCT, NULL, &structure);
    append_string(&structure, "edit-paste");
    dbus_message_iter_open_container(&structure, DBUS_TYPE_ARRAY, "(iiay)",
                                     &array);
    dbus_message_iter_close_container(&structure, &array);
    append_string(&structure, "Clipboard");
    append_string(&structure,
                  atomic_load(&s->chinese)
                      ? (atomic_load(&s->recording) ? "正在录制" : "已暂停")
                      : (atomic_load(&s->recording) ? "Recording" : "Paused"));
    dbus_message_iter_close_container(iter, &structure);
  } else {
    const char *value = "";
    if (!strcmp(property, "Category"))
      value = "ApplicationStatus";
    else if (!strcmp(property, "Id"))
      value = "clipboard";
    else if (!strcmp(property, "Title"))
      value = atomic_load(&s->chinese)
                  ? (atomic_load(&s->recording) ? "Clipboard - 正在录制"
                                                : "Clipboard - 已暂停")
                  : (atomic_load(&s->recording) ? "Clipboard - recording"
                                                : "Clipboard - paused");
    else if (!strcmp(property, "Status"))
      value = "Active";
    else if (!strcmp(property, "IconName"))
      value = "edit-paste";
    append_string(iter, value);
  }
}
static void append_item_property(clipboard_shell *s, DBusMessageIter *dict,
                                 const char *property) {
  DBusMessageIter entry, variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
  append_string(&entry, property);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT,
                                   item_signature(property), &variant);
  append_item_value(s, &variant, property);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}
static DBusHandlerResult item_properties(clipboard_shell *s,
                                         DBusMessage *request) {
  const char *interface = NULL, *property = NULL;
  DBusMessage *reply = NULL;
  if (dbus_message_is_method_call(request, DBUS_INTERFACE_PROPERTIES, "Get") &&
      dbus_message_get_args(request, NULL, DBUS_TYPE_STRING, &interface,
                            DBUS_TYPE_STRING, &property, DBUS_TYPE_INVALID) &&
      !strcmp(interface, "org.kde.StatusNotifierItem") &&
      item_signature(property)) {
    reply = dbus_message_new_method_return(request);
    DBusMessageIter iter, variant;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT,
                                     item_signature(property), &variant);
    append_item_value(s, &variant, property);
    dbus_message_iter_close_container(&iter, &variant);
  } else if (dbus_message_is_method_call(request, DBUS_INTERFACE_PROPERTIES,
                                         "GetAll") &&
             dbus_message_get_args(request, NULL, DBUS_TYPE_STRING, &interface,
                                   DBUS_TYPE_INVALID) &&
             !strcmp(interface, "org.kde.StatusNotifierItem")) {
    reply = dbus_message_new_method_return(request);
    DBusMessageIter iter, dict;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    const char *properties[] = {"Category",   "Id",       "Title",
                                "Status",     "IconName", "IconThemePath",
                                "IconPixmap", "ToolTip",  "Menu",
                                "ItemIsMenu", "WindowId"};
    for (unsigned i = 0; i < sizeof(properties) / sizeof(properties[0]); ++i)
      append_item_property(s, &dict, properties[i]);
    dbus_message_iter_close_container(&iter, &dict);
  } else
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  send_reply(s->bus, reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}
static const char *menu_label(clipboard_shell *s, int id) {
  if (id == 1)
    return atomic_load(&s->chinese) ? "显示历史" : "Show history";
  if (id == 2)
    return atomic_load(&s->chinese)
               ? (atomic_load(&s->recording) ? "暂停录制" : "开始录制")
               : (atomic_load(&s->recording) ? "Pause recording"
                                             : "Start recording");
  if (id == 3)
    return atomic_load(&s->chinese) ? "设置" : "Settings";
  if (id == 4)
    return atomic_load(&s->chinese) ? "退出" : "Quit";
  return "";
}
static void menu_properties(clipboard_shell *s, DBusMessageIter *dict, int id) {
  if (id == 0)
    string_property(dict, "children-display", "submenu");
  else {
    string_property(dict, "label", menu_label(s, id));
    string_property(dict, "type", "standard");
    boolean_property(dict, "enabled", TRUE);
    boolean_property(dict, "visible", TRUE);
  }
}
static void menu_layout(clipboard_shell *s, DBusMessageIter *iter) {
  DBusMessageIter root, properties, children;
  dbus_int32_t id = 0;
  dbus_message_iter_open_container(iter, DBUS_TYPE_STRUCT, NULL, &root);
  dbus_message_iter_append_basic(&root, DBUS_TYPE_INT32, &id);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "{sv}", &properties);
  menu_properties(s, &properties, 0);
  dbus_message_iter_close_container(&root, &properties);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "v", &children);
  for (id = 1; id <= 4; ++id) {
    DBusMessageIter variant, item, dict, empty;
    dbus_message_iter_open_container(&children, DBUS_TYPE_VARIANT, "(ia{sv}av)",
                                     &variant);
    dbus_message_iter_open_container(&variant, DBUS_TYPE_STRUCT, NULL, &item);
    dbus_message_iter_append_basic(&item, DBUS_TYPE_INT32, &id);
    dbus_message_iter_open_container(&item, DBUS_TYPE_ARRAY, "{sv}", &dict);
    menu_properties(s, &dict, id);
    dbus_message_iter_close_container(&item, &dict);
    dbus_message_iter_open_container(&item, DBUS_TYPE_ARRAY, "v", &empty);
    dbus_message_iter_close_container(&item, &empty);
    dbus_message_iter_close_container(&variant, &item);
    dbus_message_iter_close_container(&children, &variant);
  }
  dbus_message_iter_close_container(&root, &children);
  dbus_message_iter_close_container(iter, &root);
}
static const char *menu_signature(const char *property) {
  if (!strcmp(property, "Version"))
    return "u";
  if (!strcmp(property, "IconThemePath"))
    return "as";
  if (!strcmp(property, "TextDirection") || !strcmp(property, "Status"))
    return "s";
  return NULL;
}
static void append_menu_value(DBusMessageIter *iter, const char *property) {
  if (!strcmp(property, "Version")) {
    dbus_uint32_t version = 3;
    dbus_message_iter_append_basic(iter, DBUS_TYPE_UINT32, &version);
  } else if (!strcmp(property, "IconThemePath")) {
    DBusMessageIter array;
    dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "s", &array);
    dbus_message_iter_close_container(iter, &array);
  } else
    append_string(iter, !strcmp(property, "Status") ? "normal" : "ltr");
}
static DBusHandlerResult menu_bus_properties(clipboard_shell *s,
                                             DBusMessage *request) {
  const char *interface = NULL, *property = NULL;
  DBusMessage *reply = NULL;
  if (dbus_message_is_method_call(request, DBUS_INTERFACE_PROPERTIES, "Get") &&
      dbus_message_get_args(request, NULL, DBUS_TYPE_STRING, &interface,
                            DBUS_TYPE_STRING, &property, DBUS_TYPE_INVALID) &&
      !strcmp(interface, "com.canonical.dbusmenu") &&
      menu_signature(property)) {
    reply = dbus_message_new_method_return(request);
    DBusMessageIter iter, variant;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT,
                                     menu_signature(property), &variant);
    append_menu_value(&variant, property);
    dbus_message_iter_close_container(&iter, &variant);
  } else if (dbus_message_is_method_call(request, DBUS_INTERFACE_PROPERTIES,
                                         "GetAll") &&
             dbus_message_get_args(request, NULL, DBUS_TYPE_STRING, &interface,
                                   DBUS_TYPE_INVALID) &&
             !strcmp(interface, "com.canonical.dbusmenu")) {
    reply = dbus_message_new_method_return(request);
    DBusMessageIter iter, dict;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    const char *properties[] = {"Version", "TextDirection", "Status",
                                "IconThemePath"};
    for (unsigned i = 0; i < 4; ++i) {
      DBusMessageIter entry, variant;
      dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL,
                                       &entry);
      append_string(&entry, properties[i]);
      dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT,
                                       menu_signature(properties[i]), &variant);
      append_menu_value(&variant, properties[i]);
      dbus_message_iter_close_container(&entry, &variant);
      dbus_message_iter_close_container(&dict, &entry);
    }
    dbus_message_iter_close_container(&iter, &dict);
  } else
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  send_reply(s->bus, reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}
static DBusHandlerResult menu_message(clipboard_shell *s,
                                      DBusMessage *request) {
  const char *member = dbus_message_get_member(request);
  if (!member)
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  if (dbus_message_has_interface(request, DBUS_INTERFACE_PROPERTIES))
    return menu_bus_properties(s, request);
  DBusMessage *reply = dbus_message_new_method_return(request);
  DBusMessageIter iter;
  dbus_message_iter_init_append(reply, &iter);
  if (!strcmp(member, "GetLayout")) {
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_UINT32, &s->menu_revision);
    menu_layout(s, &iter);
  } else if (!strcmp(member, "AboutToShow")) {
    dbus_bool_t value = FALSE;
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_BOOLEAN, &value);
  } else if (!strcmp(member, "Event")) {
    DBusMessageIter input;
    dbus_message_iter_init(request, &input);
    dbus_int32_t id = 0;
    const char *event = NULL;
    if (dbus_message_iter_get_arg_type(&input) == DBUS_TYPE_INT32) {
      dbus_message_iter_get_basic(&input, &id);
      dbus_message_iter_next(&input);
      if (dbus_message_iter_get_arg_type(&input) == DBUS_TYPE_STRING)
        dbus_message_iter_get_basic(&input, &event);
    }
    if (event && !strcmp(event, "clicked")) {
      if (id == 1)
        emit(s, 2);
      else if (id == 2)
        emit(s, 4);
      else if (id == 3)
        emit(s, 3);
      else if (id == 4)
        emit(s, 5);
    }
  } else if (!strcmp(member, "GetGroupProperties")) {
    DBusMessageIter array;
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(ia{sv})",
                                     &array);
    for (dbus_int32_t id = 0; id <= 4; ++id) {
      DBusMessageIter row, dict;
      dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, NULL, &row);
      dbus_message_iter_append_basic(&row, DBUS_TYPE_INT32, &id);
      dbus_message_iter_open_container(&row, DBUS_TYPE_ARRAY, "{sv}", &dict);
      menu_properties(s, &dict, id);
      dbus_message_iter_close_container(&row, &dict);
      dbus_message_iter_close_container(&array, &row);
    }
    dbus_message_iter_close_container(&iter, &array);
  } else {
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  send_reply(s->bus, reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}
static const char *menu_introspection_xml =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' "
    "direction='in'/>"
    "<arg type='as' direction='in'/><arg type='u' direction='out'/><arg "
    "type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg "
    "type='as' direction='in'/><arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' "
    "direction='in'/><arg type='v' direction='in'/><arg type='u' "
    "direction='in'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' "
    "direction='out'/></method>"
    "<property name='Version' type='u' access='read'/><property "
    "name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/><property "
    "name='IconThemePath' type='as' access='read'/>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "</interface></node>";
static const char *introspection_xml =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' "
    "direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg "
    "type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' "
    "direction='in'/></method>"
    "<property name='Category' type='s' access='read'/><property name='Id' "
    "type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' "
    "type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/><property "
    "name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/><property "
    "name='Menu' type='o' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/><signal "
    "name='NewTitle'/><signal name='NewToolTip'/>"
    "</interface><interface name='org.freedesktop.DBus.Properties'>"
    "<method name='Get'><arg type='s' direction='in'/><arg type='s' "
    "direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='GetAll'><arg type='s' direction='in'/><arg type='a{sv}' "
    "direction='out'/></method>"
    "</interface><interface name='org.freedesktop.DBus.Introspectable'>"
    "<method name='Introspect'><arg type='s' "
    "direction='out'/></method></interface></node>";
static DBusHandlerResult object_message(DBusConnection *connection,
                                        DBusMessage *request, void *data) {
  clipboard_shell *s = data;
  const char *path = dbus_message_get_path(request);
  if (dbus_message_is_method_call(request, DBUS_INTERFACE_INTROSPECTABLE,
                                  "Introspect")) {
    DBusMessage *reply = dbus_message_new_method_return(request);
    const char *xml = path && !strcmp(path, "/MenuBar") ? menu_introspection_xml
                                                        : introspection_xml;
    dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
    send_reply(connection, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (path && !strcmp(path, "/StatusNotifierItem")) {
    if (dbus_message_has_interface(request, DBUS_INTERFACE_PROPERTIES))
      return item_properties(s, request);
    if (dbus_message_is_method_call(request, "org.kde.StatusNotifierItem",
                                    "Activate")) {
      atomic_store(&s->activation_time, 0);
      emit(s, 2);
    } else if (dbus_message_is_method_call(
                   request, "org.kde.StatusNotifierItem", "SecondaryActivate"))
      emit(s, 4);
    else if (dbus_message_is_method_call(request, "org.kde.StatusNotifierItem",
                                         "ContextMenu"))
      emit(s, 3);
    else
      return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    send_reply(connection, dbus_message_new_method_return(request));
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (path && !strcmp(path, "/MenuBar"))
    return menu_message(s, request);
  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}
/* Keep serving incoming SNI/property calls while a watcher registration is in
   flight; some hosts query the item before replying to
   RegisterStatusNotifierItem. */
static DBusMessage *call_bus(clipboard_shell *s, DBusMessage *request) {
  DBusPendingCall *pending = NULL;
  if (!dbus_connection_send_with_reply(s->bus, request, &pending, 1500) ||
      !pending)
    return NULL;
  dbus_connection_flush(s->bus);
  while (!dbus_pending_call_get_completed(pending) &&
         dbus_connection_get_is_connected(s->bus))
    dbus_connection_read_write_dispatch(s->bus, 50);
  DBusMessage *reply = dbus_pending_call_get_completed(pending)
                           ? dbus_pending_call_steal_reply(pending)
                           : NULL;
  if (!reply)
    dbus_pending_call_cancel(pending);
  dbus_pending_call_unref(pending);
  if (reply && dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_ERROR) {
    dbus_message_unref(reply);
    return NULL;
  }
  return reply;
}
static DBusObjectPathVTable object_vtable = {.message_function =
                                                 object_message};
static void register_watcher(clipboard_shell *s) {
  if (!s->bus)
    return;
  const char *watcher = "org.kde.StatusNotifierWatcher";
  DBusMessage *request = dbus_message_new_method_call(
      watcher, "/StatusNotifierWatcher", watcher, "RegisterStatusNotifierItem");
  const char *path = "/StatusNotifierItem";
  dbus_message_append_args(request, DBUS_TYPE_STRING, &path, DBUS_TYPE_INVALID);
  DBusMessage *reply = call_bus(s, request);
  dbus_message_unref(request);
  int host_present = 0;
  if (reply) {
    dbus_message_unref(reply);
    request = dbus_message_new_method_call(watcher, "/StatusNotifierWatcher",
                                           DBUS_INTERFACE_PROPERTIES, "Get");
    const char *property = "IsStatusNotifierHostRegistered";
    dbus_message_append_args(request, DBUS_TYPE_STRING, &watcher,
                             DBUS_TYPE_STRING, &property, DBUS_TYPE_INVALID);
    reply = call_bus(s, request);
    dbus_message_unref(request);
    if (reply) {
      DBusMessageIter iter, value;
      dbus_message_iter_init(reply, &iter);
      if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&iter, &value);
        dbus_bool_t registered = FALSE;
        if (dbus_message_iter_get_arg_type(&value) == DBUS_TYPE_BOOLEAN)
          dbus_message_iter_get_basic(&value, &registered);
        host_present = registered;
      }
      dbus_message_unref(reply);
    }
  }
  if (host_present)
    atomic_fetch_or(&s->capabilities, 1);
  else
    atomic_fetch_and(&s->capabilities, ~1U);
}
static DBusHandlerResult bus_filter(DBusConnection *connection,
                                    DBusMessage *message, void *data) {
  (void)connection;
  clipboard_shell *s = data;
  if (dbus_message_is_signal(message, DBUS_INTERFACE_DBUS,
                             "NameOwnerChanged")) {
    const char *name, *old_owner, *new_owner;
    if (dbus_message_get_args(message, NULL, DBUS_TYPE_STRING, &name,
                              DBUS_TYPE_STRING, &old_owner, DBUS_TYPE_STRING,
                              &new_owner, DBUS_TYPE_INVALID) &&
        !strcmp(name, "org.kde.StatusNotifierWatcher")) {
      if (*new_owner)
        s->needs_registration = 1;
      else {
        atomic_fetch_and(&s->capabilities, ~1U);
        emit(s, 6);
      }
    }
  } else if (dbus_message_is_signal(message, "org.kde.StatusNotifierWatcher",
                                    "StatusNotifierHostRegistered")) {
    s->needs_registration = 1;
  } else if (dbus_message_is_signal(message, "org.kde.StatusNotifierWatcher",
                                    "StatusNotifierHostUnregistered")) {
    atomic_fetch_and(&s->capabilities, ~1U);
    emit(s, 6);
  }
  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}
static pthread_once_t dbus_once = PTHREAD_ONCE_INIT;
static void init_dbus_threads(void) { dbus_threads_init_default(); }
static void connect_bus(clipboard_shell *s) {
  pthread_once(&dbus_once, init_dbus_threads);
  DBusError error;
  dbus_error_init(&error);
  s->bus = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
  dbus_error_free(&error);
  if (!s->bus)
    return;
  dbus_connection_set_exit_on_disconnect(s->bus, FALSE);
  dbus_connection_register_object_path(s->bus, "/StatusNotifierItem",
                                       &object_vtable, s);
  dbus_connection_register_object_path(s->bus, "/MenuBar", &object_vtable, s);
  dbus_connection_add_filter(s->bus, bus_filter, s, NULL);
  dbus_bus_add_match(s->bus,
                     "type='signal',interface='org.freedesktop.DBus',member='"
                     "NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'",
                     NULL);
  dbus_bus_add_match(
      s->bus, "type='signal',interface='org.kde.StatusNotifierWatcher'", NULL);
  register_watcher(s);
}
static void update_tray(clipboard_shell *s) {
  if (!s->bus)
    return;
  const char *signals[] = {"NewTitle", "NewToolTip"};
  for (unsigned i = 0; i < 2; ++i) {
    DBusMessage *signal = dbus_message_new_signal(
        "/StatusNotifierItem", "org.kde.StatusNotifierItem", signals[i]);
    send_reply(s->bus, signal);
  }
  DBusMessage *signal = dbus_message_new_signal(
      "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated");
  dbus_int32_t parent = 0;
  ++s->menu_revision;
  dbus_message_append_args(signal, DBUS_TYPE_UINT32, &s->menu_revision,
                           DBUS_TYPE_INT32, &parent, DBUS_TYPE_INVALID);
  send_reply(s->bus, signal);
  dbus_connection_flush(s->bus);
}
static void *shell_thread(void *value) {
  clipboard_shell *s = value;
  int shortcut_error = bind_x11(s, s->modifiers);
  connect_bus(s);
  s->error = shortcut_error;
  pthread_mutex_lock(&s->lock);
  s->ready = 1;
  pthread_cond_signal(&s->ready_condition);
  pthread_mutex_unlock(&s->lock);
  while (!atomic_load(&s->stopping)) {
    pump_x11(s);
    if (s->bus) {
      dbus_connection_read_write(s->bus, 0);
      while (dbus_connection_dispatch(s->bus) == DBUS_DISPATCH_DATA_REMAINS) {
      }
      if (s->needs_registration) {
        s->needs_registration = 0;
        register_watcher(s);
        emit(s, 6);
      }
      if (!dbus_connection_get_is_connected(s->bus)) {
        atomic_fetch_and(&s->capabilities, ~1U);
        emit(s, 6);
        dbus_connection_close(s->bus);
        dbus_connection_unref(s->bus);
        s->bus = NULL;
      }
    }
    struct pollfd descriptors[3];
    unsigned count = 0;
    descriptors[count++] = (struct pollfd){s->wake[0], POLLIN, 0};
    if (s->display)
      descriptors[count++] =
          (struct pollfd){ConnectionNumber(s->display), POLLIN, 0};
    int bus_socket;
    if (s->bus && dbus_connection_get_unix_fd(s->bus, &bus_socket))
      descriptors[count++] = (struct pollfd){bus_socket, POLLIN, 0};
    int result = poll(descriptors, count, -1);
    if (result < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (descriptors[0].revents & POLLIN) {
      char buffer[64];
      while (read(s->wake[0], buffer, sizeof(buffer)) > 0) {
      }
      if (!atomic_load(&s->stopping))
        update_tray(s);
    }
  }
  if (s->display) {
    if (atomic_load(&s->capabilities) & 2)
      each_grab(s, 0);
    XCloseDisplay(s->display);
  }
  if (s->bus) {
    dbus_connection_unregister_object_path(s->bus, "/StatusNotifierItem");
    dbus_connection_unregister_object_path(s->bus, "/MenuBar");
    dbus_connection_close(s->bus);
    dbus_connection_unref(s->bus);
  }
  atomic_store(&s->capabilities, 0);
  return NULL;
}
clipboard_shell *clipboard_shell_create(const char *key, uint32_t modifiers,
                                        int recording,
                                        clipboard_shell_callback callback,
                                        void *context, int *error) {
  if (error)
    *error = 1;
  clipboard_shell *s = calloc(1, sizeof(*s));
  if (!s || !key || strlen(key) >= sizeof(s->key)) {
    free(s);
    return NULL;
  }
  strcpy(s->key, key);
  s->modifiers = modifiers;
  s->callback = callback;
  s->context = context;
  atomic_init(&s->stopping, 0);
  atomic_init(&s->recording, recording);
  atomic_init(&s->capabilities, 0);
  atomic_init(&s->activation_time, 0);
  pthread_mutex_init(&s->lock, NULL);
  pthread_cond_init(&s->ready_condition, NULL);
  if (pipe(s->wake) != 0) {
    pthread_cond_destroy(&s->ready_condition);
    pthread_mutex_destroy(&s->lock);
    free(s);
    return NULL;
  }
  fcntl(s->wake[0], F_SETFL, O_NONBLOCK);
  fcntl(s->wake[1], F_SETFL, O_NONBLOCK);
  fcntl(s->wake[0], F_SETFD, FD_CLOEXEC);
  fcntl(s->wake[1], F_SETFD, FD_CLOEXEC);
  if (pthread_create(&s->thread, NULL, shell_thread, s) != 0) {
    close(s->wake[0]);
    close(s->wake[1]);
    pthread_cond_destroy(&s->ready_condition);
    pthread_mutex_destroy(&s->lock);
    free(s);
    return NULL;
  }
  pthread_mutex_lock(&s->lock);
  while (!s->ready)
    pthread_cond_wait(&s->ready_condition, &s->lock);
  pthread_mutex_unlock(&s->lock);
  if (error)
    *error = s->error;
  return s;
}
uint32_t clipboard_shell_capabilities(clipboard_shell *s) {
  return s ? atomic_load(&s->capabilities) : 0;
}
uint32_t clipboard_shell_activation_time(clipboard_shell *s) {
  return s ? atomic_load(&s->activation_time) : 0;
}
static void wake_shell(clipboard_shell *s) {
  char value = 1;
  ssize_t result;
  do {
    result = write(s->wake[1], &value, 1);
  } while (result < 0 && errno == EINTR);
  /* EAGAIN means an earlier wake is already queued. */
}
void clipboard_shell_set_language(clipboard_shell *s, int chinese) {
  if (!s)
    return;
  atomic_store(&s->chinese, chinese != 0);
  wake_shell(s);
}
void clipboard_shell_set_recording(clipboard_shell *s, int recording) {
  if (!s)
    return;
  atomic_store(&s->recording, recording);
  wake_shell(s);
}
void clipboard_shell_destroy(clipboard_shell *s) {
  if (!s)
    return;
  atomic_store(&s->stopping, 1);
  wake_shell(s);
  pthread_join(s->thread, NULL);
  close(s->wake[0]);
  close(s->wake[1]);
  pthread_cond_destroy(&s->ready_condition);
  pthread_mutex_destroy(&s->lock);
  free(s);
}
#else
struct clipboard_shell {
  int unused;
};
clipboard_shell *clipboard_shell_create(const char *key, uint32_t modifiers,
                                        int recording,
                                        clipboard_shell_callback callback,
                                        void *context, int *error) {
  (void)key;
  (void)modifiers;
  (void)recording;
  (void)callback;
  (void)context;
  if (error)
    *error = 1;
  return NULL;
}
uint32_t clipboard_shell_capabilities(clipboard_shell *s) {
  (void)s;
  return 0;
}
uint32_t clipboard_shell_activation_time(clipboard_shell *s) {
  (void)s;
  return 0;
}
void clipboard_shell_set_language(clipboard_shell *s, int chinese) {
  (void)s;
  (void)chinese;
}
void clipboard_shell_set_recording(clipboard_shell *s, int recording) {
  (void)s;
  (void)recording;
}
void clipboard_shell_destroy(clipboard_shell *s) { (void)s; }
#endif
