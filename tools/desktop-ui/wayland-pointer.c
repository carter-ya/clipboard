/* Private headless test device. It creates a pointer, never a keyboard. */
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>
static struct zwlr_virtual_pointer_manager_v1 *manager;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  (void)data;
  (void)version;
  if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
    manager = wl_registry_bind(registry, name,
                               &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}
int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display)
    return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  struct wl_registry_listener listener = {.global = global,
                                          .global_remove = removed};
  wl_registry_add_listener(registry, &listener, NULL);
  if (wl_display_roundtrip(display) < 0 || !manager)
    return 1;
  struct zwlr_virtual_pointer_v1 *pointer =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
  if (wl_display_roundtrip(display) < 0)
    return 1;
  puts("ready");
  fflush(stdout);
  char command[32];
  while (fgets(command, sizeof(command), stdin)) {
  }
  zwlr_virtual_pointer_v1_destroy(pointer);
  zwlr_virtual_pointer_manager_v1_destroy(manager);
  wl_registry_destroy(registry);
  wl_display_flush(display);
  wl_display_disconnect(display);
  return 0;
}
