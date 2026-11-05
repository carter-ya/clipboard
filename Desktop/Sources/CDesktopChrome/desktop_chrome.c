#include "desktop_chrome.h"
#include <gtk/gtk.h>
#include <string.h>
#ifdef _WIN32
#include <gdk/win32/gdkwin32.h>
#include <dwmapi.h>
#elif defined(__linux__)
#include <gdk/x11/gdkx.h>
#include <X11/Xatom.h>
#endif

static void set_class(GtkWidget *widget, const char *name, gboolean enabled) {
  if (gtk_widget_has_css_class(widget, name) == enabled)
    return;
  if (enabled)
    gtk_widget_add_css_class(widget, name);
  else
    gtk_widget_remove_css_class(widget, name);
}

static gboolean high_contrast(GtkWidget *widget) {
  char *theme = NULL;
  g_object_get(gtk_widget_get_settings(widget), "gtk-theme-name", &theme, NULL);
  char *lower = theme ? g_ascii_strdown(theme, -1) : NULL;
  gboolean high = lower && strstr(lower, "highcontrast");
  g_free(lower);
  g_free(theme);
  return high;
}

#ifdef _WIN32
static gboolean native_material(GtkWidget *widget, GdkSurface *surface) {
  HWND hwnd = gdk_win32_surface_get_handle(surface);
  if (!hwnd)
    return FALSE;
  // Public Windows 11 attributes; an older OS rejects them and stays opaque.
  DWORD corner = 2; // DWMWCP_ROUND, Windows 11 build 22000+
  DwmSetWindowAttribute(hwnd, 33, &corner, sizeof(corner));
  BOOL dark = gtk_widget_has_css_class(widget, "clipboard-dark");
  DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
  HIGHCONTRASTW contrast = {0};
  contrast.cbSize = sizeof(contrast);
  DWORD transparency = 1, size = sizeof(transparency);
  RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"EnableTransparency", RRF_RT_REG_DWORD, NULL, &transparency, &size);
  BOOL composition = FALSE;
  gboolean allowed = !high_contrast(widget) && transparency != 0 &&
                     SystemParametersInfoW(SPI_GETHIGHCONTRAST,
                                           sizeof(contrast), &contrast, 0) &&
                     !(contrast.dwFlags & HCF_HIGHCONTRASTON) &&
                     SUCCEEDED(DwmIsCompositionEnabled(&composition)) &&
                     composition;
  DWORD backdrop = allowed ? 3 : 1; // DWMSBT_TRANSIENTWINDOW (Acrylic) / NONE
  HRESULT result = DwmSetWindowAttribute(hwnd, 38, &backdrop, sizeof(backdrop));
  if (FAILED(result))
    return FALSE;
  gboolean enabled = allowed;
  MARGINS margins = enabled ? (MARGINS){-1, -1, -1, -1} : (MARGINS){0};
  if (FAILED(DwmExtendFrameIntoClientArea(hwnd, &margins))) {
    enabled = FALSE;
    backdrop = 1;
    DwmSetWindowAttribute(hwnd, 38, &backdrop, sizeof(backdrop));
  }
  return enabled;
}
#elif defined(__linux__)
static Atom blur_atom(GdkDisplay *display) {
  return gdk_x11_get_xatom_by_name_for_display(
      display, "_KDE_NET_WM_BLUR_BEHIND_REGION");
}

static gboolean root_property_changed(GdkDisplay *display, XEvent *event,
                                      GtkWidget *window) {
  Display *xdisplay = gdk_x11_display_get_xdisplay(display);
  if (event->type == PropertyNotify &&
      event->xproperty.window == DefaultRootWindow(xdisplay) &&
      event->xproperty.atom == blur_atom(display) &&
      gtk_widget_get_mapped(window))
    clipboard_window_chrome_refresh(window);
  return FALSE; // Keep GTK's normal event delivery.
}

static gboolean native_material(GtkWidget *widget, GdkSurface *surface) {
  GdkDisplay *display = gdk_surface_get_display(surface);
  // KDE advertises enabled blur as a root property. Never infer support from
  // desktop names or from the mere existence of an interned X atom.
  // Wayland and other compositors retain an opaque, readable fallback.
  if (!GDK_IS_X11_DISPLAY(display) || !GDK_IS_X11_SURFACE(surface))
    return FALSE;
  Display *xdisplay = gdk_x11_display_get_xdisplay(display);
  Atom blur = blur_atom(display);
  gboolean enabled = FALSE;
  if (gdk_display_is_composited(display) && gdk_display_is_rgba(display) &&
      !high_contrast(widget)) {
    int count = 0;
    Atom *properties =
        XListProperties(xdisplay, DefaultRootWindow(xdisplay), &count);
    for (int i = 0; properties && i < count; ++i)
      if (properties[i] == blur)
        enabled = TRUE;
    if (properties)
      XFree(properties);
  }
  Window xid = gdk_x11_surface_get_xid(surface);
  if (enabled)
    XChangeProperty(xdisplay, xid, blur, XA_CARDINAL, 32, PropModeReplace, NULL,
                    0);
  else
    XDeleteProperty(xdisplay, xid, blur);
  return enabled;
}
#else
static gboolean native_material(GtkWidget *widget, GdkSurface *surface) {
  (void)widget;
  (void)surface;
  return FALSE;
}
#endif

void clipboard_window_chrome_refresh(void *window) {
  GtkWidget *widget = GTK_WIDGET(window);
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
  if (!surface)
    return;
  gboolean enabled = native_material(widget, surface);
  set_class(widget, "clipboard-material", enabled);
}

static void mapped(GtkWidget *widget, gpointer data) {
  (void)data;
  clipboard_window_chrome_refresh(widget);
}

static void changed(GObject *object, GParamSpec *property, gpointer window) {
  (void)object;
  (void)property;
  clipboard_window_chrome_refresh(window);
}

void clipboard_window_chrome_install(void *window) {
  GtkWidget *widget = GTK_WIDGET(window);
  if (g_object_get_data(G_OBJECT(window), "clipboard-chrome-installed"))
    return;
  g_object_set_data(G_OBJECT(window), "clipboard-chrome-installed",
                    GINT_TO_POINTER(1));
#if defined(__linux__)
  GdkDisplay *display = gtk_widget_get_display(widget);
  if (GDK_IS_X11_DISPLAY(display)) {
    Display *xdisplay = gdk_x11_display_get_xdisplay(display);
    Window root = DefaultRootWindow(xdisplay);
    XWindowAttributes attributes;
    if (XGetWindowAttributes(xdisplay, root, &attributes) &&
        !(attributes.your_event_mask & PropertyChangeMask))
      XSelectInput(xdisplay, root,
                   attributes.your_event_mask | PropertyChangeMask);
    g_signal_connect_object(display, "xevent",
                            G_CALLBACK(root_property_changed), window, 0);
    g_signal_connect_object(display, "notify::composited", G_CALLBACK(changed),
                            window, 0);
  }
#endif
  // Use the search surface's existing top inset as a native move handle.
  // A client decoration retains edge resizing, window menus and CSD shadows.
  GtkWidget *inset = gtk_window_handle_new();
  gtk_widget_add_css_class(inset, "clipboard-top-inset");
  gtk_window_set_titlebar(GTK_WINDOW(window), inset);
  g_signal_connect(widget, "map", G_CALLBACK(mapped), NULL);
  g_signal_connect(widget, "notify::is-active", G_CALLBACK(changed), window);
  g_signal_connect_object(gtk_widget_get_settings(widget),
                          "notify::gtk-theme-name", G_CALLBACK(changed), window,
                          0);
  g_signal_connect_object(gtk_widget_get_settings(widget),
                          "notify::gtk-application-prefer-dark-theme",
                          G_CALLBACK(changed), window, 0);
}
