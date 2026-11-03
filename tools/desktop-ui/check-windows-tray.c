/* Exercise the actual native dispatcher without a tray icon, hotkey
 * registration, clipboard access or synthesized desktop input. */
#include "../../Core/Sources/CDesktopShell/desktop_shell.c"
#include <stdio.h>

typedef struct {
  int action, count, visible;
} consumer;

static void receive(void *context, int32_t action, const char *token) {
  consumer *state = context;
  (void)token;
  state->action = action;
  state->count++;
  if (action == 1)
    state->visible = !state->visible;
  else if (action == 2)
    state->visible = 1;
}

static int require(int condition, const char *name) {
  if (!condition)
    fprintf(stderr, "FAIL %s\n", name);
  return condition;
}

int main(void) {
  HINSTANCE module = GetModuleHandleW(NULL);
  const WCHAR *name = L"ClipboardPrivateTrayDispatcherRegression";
  WNDCLASSW type = {0};
  type.lpfnWndProc = shell_window_proc;
  type.hInstance = module;
  type.lpszClassName = name;
  if (!RegisterClassW(&type))
    return 2;
  consumer state = {0};
  clipboard_shell shell = {0};
  shell.callback = receive;
  shell.context = &state;
  HWND window = CreateWindowExW(0, name, L"Private fixture", WS_POPUP, 0, 0, 0,
                                0, NULL, NULL, module, &shell);
  if (!window)
    return 3;
  int passed = 1;
  const UINT events[] = {WM_LBUTTONUP, NIN_SELECT, WM_LBUTTONUP, NIN_SELECT,
                         NIN_KEYSELECT};
  for (unsigned i = 0; i < sizeof(events) / sizeof(events[0]); ++i) {
    SendMessageW(window, SHELL_NOTIFY, 0, MAKELPARAM(events[i], 1));
    passed &= require(state.action == 2 && state.visible,
                      "tray_activation_is_idempotent_show");
  }
  passed &= require(state.count == 5, "all_activation_events_delivered");
  SendMessageW(window, SHELL_NOTIFY, 0, MAKELPARAM(WM_MOUSEMOVE, 1));
  passed &= require(state.count == 5, "hover_does_not_activate");
  SendMessageW(window, WM_HOTKEY, 1, 0);
  passed &= require(state.action == 1 && !state.visible,
                    "shortcut_still_toggles_visible_history_off");
  SendMessageW(window, WM_HOTKEY, 1, 0);
  passed &= require(state.action == 1 && state.visible,
                    "shortcut_still_toggles_hidden_history_on");
  DestroyWindow(window);
  UnregisterClassW(name, module);
  if (passed)
    puts("PASS native tray repeat activation and shortcut semantics");
  return passed ? 0 : 1;
}
