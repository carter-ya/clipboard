using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// Owns precisely one CreateProcess result. No clipboard, keyboard or window
// enumeration APIs; normal GUI launches have null standard handles too.
public sealed class ClipboardNoConsoleProcess : IDisposable {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct StartupInfo {
    public int Size;
    public string Reserved, Desktop, Title;
    public int X, Y, Width, Height, Columns, Rows, Fill, Flags;
    public short Show, ExtraLength;
    public IntPtr Extra, Input, Output, Error;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct ProcessInfo {
    public IntPtr Process, Thread;
    public int ProcessId, ThreadId;
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CreateProcess(string application, StringBuilder command,
    IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
    IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
  [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr handle, uint code);
  [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
  private IntPtr process;
  public int Id { get; private set; }
  public uint ExitCode {
    get {
      uint code;
      if (!GetExitCodeProcess(process, out code)) throw new Win32Exception();
      return code;
    }
  }
  public bool HasExited { get { return WaitForSingleObject(process, 0) == 0; } }
  public static ClipboardNoConsoleProcess Start(string executable, string arguments) {
    StartupInfo startup = new StartupInfo();
    startup.Size = Marshal.SizeOf(startup);
    startup.Flags = 0x100; // STARTF_USESTDHANDLES: all three remain NULL.
    ProcessInfo created;
    if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
        IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, Path.GetDirectoryName(executable),
        ref startup, out created)) throw new Win32Exception();
    CloseHandle(created.Thread);
    return new ClipboardNoConsoleProcess { process = created.Process, Id = created.ProcessId };
  }
  public void Dispose() {
    if (process == IntPtr.Zero) return;
    try {
      if (!HasExited && !TerminateProcess(process, 94)) throw new Win32Exception();
      if (WaitForSingleObject(process, 5000) != 0) throw new InvalidOperationException("owned_process_cleanup_timeout");
    } finally { CloseHandle(process); process = IntPtr.Zero; }
  }
}
