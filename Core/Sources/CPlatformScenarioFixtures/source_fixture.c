#include "source_fixture.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static LRESULT CALLBACK fixture_window(HWND window, UINT message, WPARAM wparam,
                                       LPARAM lparam) {
  if (message == WM_CLOSE) {
    DestroyWindow(window);
    return 0;
  }
  if (message == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
static DWORD WINAPI fixture_input(LPVOID parameter) {
  char byte;
  DWORD count;
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  while (ReadFile(input, &byte, 1, &count, NULL) && count && byte != '\n') {
  }
  PostMessageW((HWND)parameter, WM_CLOSE, 0, 0);
  return 0;
}
int clipboard_run_owned_source_fixture(void) {
  const char *allowed = getenv("CLIPBOARD_PRIVATE_SOURCE_TEST");
  if (!allowed || strcmp(allowed, "1"))
    return 1;
  const WCHAR *name = L"ClipboardPrivateSourceFixture";
  HINSTANCE instance = GetModuleHandleW(NULL);
  WNDCLASSW definition = {0};
  definition.lpfnWndProc = fixture_window;
  definition.hInstance = instance;
  definition.lpszClassName = name;
  if (!RegisterClassW(&definition))
    return 1;
  HWND window = CreateWindowExW(0, name, L"Synthetic source fixture", 0, 0, 0,
                                0, 0, HWND_MESSAGE, NULL, instance, NULL);
  int result = 1;
  if (!window)
    goto done;
  // OpenClipboard(NULL) leaves no source owner after EmptyClipboard. The
  // dedicated fixture owns and pumps a real message-only HWND instead.
  const WCHAR text[] = L"synthetic source fixture";
  HGLOBAL value = GlobalAlloc(GMEM_MOVEABLE, sizeof(text));
  if (!value)
    goto done;
  void *bytes = GlobalLock(value);
  if (!bytes) {
    GlobalFree(value);
    goto done;
  }
  memcpy(bytes, text, sizeof(text));
  GlobalUnlock(value);
  if (!OpenClipboard(window)) {
    GlobalFree(value);
    goto done;
  }
  int written =
      EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, value) != NULL;
  CloseClipboard();
  if (!written) {
    GlobalFree(value);
    goto done;
  }
  HANDLE reader = CreateThread(NULL, 0, fixture_input, window, 0, NULL);
  if (!reader)
    goto done;
  DWORD count = 0;
  int announced =
      WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), "ready\n", 6, &count, NULL) &&
      count == 6;
  if (!announced)
    PostMessageW(window, WM_CLOSE, 0, 0);
  MSG message;
  int status;
  while ((status = GetMessageW(&message, NULL, 0, 0)) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  if (WaitForSingleObject(reader, 0) == WAIT_TIMEOUT)
    CancelSynchronousIo(reader);
  if (WaitForSingleObject(reader, 3000) == WAIT_OBJECT_0 && status == 0 &&
      announced)
    result = 0;
  CloseHandle(reader);
done:
  if (window && IsWindow(window))
    DestroyWindow(window);
  UnregisterClassW(name, instance);
  return result;
}
#else
int clipboard_run_owned_source_fixture(void) { return 1; }
#endif
