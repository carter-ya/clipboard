// Exercise the native dispatcher directly; never send keyboard input to X11.
#include "../../Core/Sources/CDesktopShell/desktop_shell.c"
#include <assert.h>
#include <stdio.h>

static unsigned actions;
static void action(void *context, int32_t value) {
  (void)context;
  assert(value == 1);
  actions++;
}
static void press(clipboard_shell *shell, unsigned keycode, unsigned state) {
  XKeyEvent event = {0};
  event.type = KeyPress;
  event.keycode = keycode;
  event.state = state;
  event.time = 123;
  dispatch_x11_key_press(shell, &event);
}
int main(void) {
  clipboard_shell shell = {0};
  shell.keycode = 42;
  shell.modifiers = ControlMask | Mod1Mask;
  shell.num_lock = Mod2Mask;
  shell.callback = action;
  atomic_store(&shell.capabilities, 2);
  press(&shell, 42, 0);
  assert(actions == 0 && !shell.pressed);
  press(&shell, 42, ControlMask);
  press(&shell, 42, shell.modifiers | ShiftMask);
  press(&shell, 41, shell.modifiers);
  assert(actions == 0 && !shell.pressed);
  // Root events after an unsuccessful registration must not activate history.
  atomic_store(&shell.capabilities, 0);
  press(&shell, 42, shell.modifiers);
  assert(actions == 0 && !shell.pressed);
  atomic_store(&shell.capabilities, 2);
  unsigned locks[] = {0, LockMask, Mod2Mask, LockMask | Mod2Mask};
  for (unsigned i = 0; i < 4; ++i) {
    shell.pressed = 0;
    press(&shell, 42, shell.modifiers | locks[i] | Button1Mask);
    assert(actions == i + 1 && shell.pressed);
    assert(atomic_load(&shell.activation_time) == 123);
    press(&shell, 42, shell.modifiers | locks[i]);
    assert(actions == i + 1); // Holding the key emits only one action.
  }
  // Num Lock can be assigned to a modifier other than Mod2.
  shell.num_lock = Mod3Mask;
  shell.pressed = 0;
  press(&shell, 42, shell.modifiers | Mod2Mask);
  assert(actions == 4);
  press(&shell, 42, shell.modifiers | Mod3Mask);
  assert(actions == 5);
  puts("X11 shortcut modifier, registration and repeat checks passed");
  return 0;
}
