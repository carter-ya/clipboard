#include "desktop_clipboard.h"
#include <X11/Xlib.h>
#include <stdio.h>

static int delegated;
static int host_error(Display *display, XErrorEvent *error) {
  (void)display;
  if (error->error_code == BadWindow)
    delegated++;
  return 0;
}

int main(void) {
  XInitThreads();
  XSetErrorHandler(host_error);
  Display *other = XOpenDisplay(NULL);
  if (!other)
    return 1;
  cb_session *sessions[32] = {0};
  for (unsigned i = 0; i < 32; ++i) {
    sessions[i] = cb_open();
    if (!sessions[i])
      return 2;
  }
  cb_session *overflow = cb_open();
  if (overflow) {
    cb_close(overflow);
    return 3;
  }
  XDestroyWindow(other, None);
  XSync(other, False);
  if (delegated != 1)
    return 4;
  for (unsigned i = 0; i < 32; ++i)
    cb_close(sessions[i]);
  for (unsigned i = 0; i < 40; ++i) {
    cb_session *session = cb_open();
    if (!session)
      return 5;
    cb_close(session);
  }
  XDestroyWindow(other, None);
  XSync(other, False);
  XCloseDisplay(other);
  if (delegated != 2)
    return 6;
  puts("X11 host handler delegation and registry cleanup passed");
  return 0;
}
