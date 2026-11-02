// Read-only observation of the exact classic Notepad process started by the
// Windows Actions keyboard fixture. Never loaded by the application.
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ClipboardOwnedNotepad {
  delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
  static extern IntPtr ReadLength(IntPtr window, uint message, UIntPtr parameter, IntPtr data, uint flags, uint timeout, out UIntPtr result);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
  static extern IntPtr ReadBuffer(IntPtr window, uint message, UIntPtr parameter, StringBuilder data, uint flags, uint timeout, out UIntPtr result);
  [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
    public uint size, flags;
    public IntPtr active, focus, capture, menu, move, caret;
    public int left, top, right, bottom;
  }
  [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo information);

  static void Guard(uint process) {
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
        Environment.OSVersion.Platform != PlatformID.Win32NT || process == 0)
      throw new InvalidOperationException("notepad_fixture_requires_owned_windows_actions_process");
  }
  static bool Matches(IntPtr window, uint process, string name) {
    uint owner;
    GetWindowThreadProcessId(window, out owner);
    if (owner != process || window == IntPtr.Zero) return false;
    var type = new StringBuilder(128);
    return GetClassName(window, type, type.Capacity) > 0 && type.ToString() == name;
  }
  public static IntPtr FindWindow(uint process) {
    Guard(process);
    IntPtr found = IntPtr.Zero;
    int matches = 0;
    EnumWindows(delegate(IntPtr window, IntPtr ignored) {
      // Do not read titles, text or children of any other process.
      if (Matches(window, process, "Notepad") && IsWindowVisible(window)) {
        matches++;
        found = window;
      }
      return true;
    }, IntPtr.Zero);
    if (matches > 1) throw new InvalidOperationException("owned_notepad_window_not_unique");
    return found;
  }
  public static IntPtr FindEditor(IntPtr window, uint process) {
    Guard(process);
    if (!Matches(window, process, "Notepad")) throw new InvalidOperationException("notepad_window_not_owned");
    IntPtr found = IntPtr.Zero;
    int matches = 0;
    EnumChildWindows(window, delegate(IntPtr child, IntPtr ignored) {
      if (Matches(child, process, "Edit") && IsWindowVisible(child)) {
        matches++;
        found = child;
      }
      return true;
    }, IntPtr.Zero);
    if (matches > 1) throw new InvalidOperationException("owned_notepad_editor_not_unique");
    return found;
  }
  static void VerifyEditor(IntPtr window, IntPtr editor, uint process) {
    Guard(process);
    if (!Matches(window, process, "Notepad") || !Matches(editor, process, "Edit") || !IsChild(window, editor))
      throw new InvalidOperationException("notepad_editor_not_owned");
  }
  public static bool EditorFocused(IntPtr window, IntPtr editor, uint process) {
    VerifyEditor(window, editor, process);
    uint owner;
    uint thread = GetWindowThreadProcessId(window, out owner);
    var information = new GuiThreadInfo { size = (uint)Marshal.SizeOf(typeof(GuiThreadInfo)) };
    return GetGUIThreadInfo(thread, ref information) && information.active == window && information.focus == editor;
  }
  public static string ReadText(IntPtr window, IntPtr editor, uint process) {
    VerifyEditor(window, editor, process);
    UIntPtr length, read;
    if (ReadLength(editor, 0x000e, UIntPtr.Zero, IntPtr.Zero, 3, 1000, out length) == IntPtr.Zero || length.ToUInt64() > 4096)
      throw new InvalidOperationException("owned_notepad_text_length_bound");
    var text = new StringBuilder(4097);
    if (ReadBuffer(editor, 0x000d, new UIntPtr(4097), text, 3, 1000, out read) == IntPtr.Zero || read.ToUInt64() > 4096)
      throw new InvalidOperationException("owned_notepad_text_read_failed");
    return text.ToString();
  }
}
