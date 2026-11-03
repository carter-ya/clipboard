using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// Only addresses windows belonging to the child PID supplied by the fixture.
// Sends shell callback notifications, never mouse/keyboard or clipboard input.
public sealed class ClipboardOwnedTray {
  private delegate bool WindowCallback(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, WindowCallback callback, IntPtr data);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeout(IntPtr window,
    uint message, UIntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr result);
  private readonly int processId;
  private readonly IntPtr mainWindow, shellWindow;
  private void RequireOwner(IntPtr window) {
    uint owner;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)processId)
      throw new InvalidOperationException("tray_fixture_window_owner_mismatch");
  }
  public ClipboardOwnedTray(int childId, IntPtr childWindow) {
    processId = childId;
    mainWindow = childWindow;
    RequireOwner(mainWindow);
    IntPtr found = IntPtr.Zero;
    WindowCallback callback = delegate(IntPtr window, IntPtr unused) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      StringBuilder name = new StringBuilder(128);
      GetClassName(window, name, name.Capacity);
      if (owner == (uint)processId && name.ToString() == "ClipboardDesktopShell") found = window;
      return true;
    };
    using (Process child = Process.GetProcessById(processId)) {
      foreach (ProcessThread thread in child.Threads) {
        try { EnumThreadWindows((uint)thread.Id, callback, IntPtr.Zero); }
        finally { thread.Dispose(); }
      }
    }
    shellWindow = found;
    RequireOwner(shellWindow);
  }
  public bool Visible { get { RequireOwner(mainWindow); return IsWindowVisible(mainWindow); } }
  public void Notify(uint notification) {
    // Only the three activation notifications accepted by the product adapter.
    if (notification != 0x202 && notification != 0x400 && notification != 0x401)
      throw new ArgumentOutOfRangeException("notification");
    RequireOwner(shellWindow);
    UIntPtr result;
    if (SendMessageTimeout(shellWindow, 0x8000 + 320, UIntPtr.Zero,
        new IntPtr((1 << 16) | notification), 2, 2000, out result) == IntPtr.Zero)
      throw new InvalidOperationException("tray_fixture_notification_timeout");
  }
}
