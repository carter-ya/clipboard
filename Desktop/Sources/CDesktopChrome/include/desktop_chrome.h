#pragma once
// UI-only native GTK window integration. No clipboard or focus manipulation.
void clipboard_window_chrome_install(void *window, const char *icon_path);
void clipboard_window_chrome_refresh(void *window);
