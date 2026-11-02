// Owned Windows Actions browser only. No production application references.
using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class ClipboardBrowserFixture : IDisposable {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo {
    public uint size; public string reserved, desktop, title;
    public uint x, y, width, height, charsX, charsY, fill, flags;
    public ushort show, reservedSize; public IntPtr reservedData, input, output, error;
  }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint id, threadID; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
    public long processTime, jobTime; public uint flags; public UIntPtr minWorking, maxWorking;
    public uint active; public UIntPtr affinity; public uint priority, scheduling;
  }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
    public BasicLimits basic; public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
    public UIntPtr processMemory, jobMemory, peakProcess, peakJob;
  }
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
    public long user, kernel, periodUser, periodKernel;
    public uint faults, total, active, terminated;
  }
  delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr security, string name);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint size);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting accounting, uint size, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string application, StringBuilder arguments, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
  [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();

  IntPtr job, process;
  ClientWebSocket socket;
  bool disposed;
  bool processAssigned;
  public string Root { get; private set; }
  public string Owner { get; private set; }
  public string PageUrl { get; private set; }
  public uint ProcessId { get; private set; }
  public bool CleanupComplete { get; private set; }
  public uint ClipboardRevision {
    get {
      Running(); uint revision = GetClipboardSequenceNumber();
      if (revision == 0) throw new InvalidOperationException("browser_clipboard_revision_unavailable");
      return revision;
    }
  }
  public string PlainText { get { return "Browser fixture \u4e2d\u6587\ud83d\ude00\nsecond line"; } }
  public string HtmlText { get { return "Browser rich \u4e2d\u6587\ud83d\ude00"; } }
  public string BoldText { get { return "rich \u4e2d\u6587\ud83d\ude00"; } }
  public string PixelData { get { return Convert.ToBase64String(new byte[] {255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255, 0,255,255,255, 255,0,255,255}); } }
  public string[] Files { get { return new string[] { Path.Combine(Root, "alpha \u4e2d\u6587.txt"), Path.Combine(Root, "beta space.txt") }; } }
  static void Guard() {
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.OSVersion.Platform != PlatformID.Win32NT)
      throw new InvalidOperationException("browser_fixture_requires_windows_actions");
  }
  void Running() { Guard(); if (disposed || job == IntPtr.Zero) throw new InvalidOperationException("owned_browser_not_running"); }
  public ClipboardBrowserFixture(string executable, string page) {
    Guard();
    if (String.IsNullOrEmpty(Environment.GetEnvironmentVariable("RUNNER_TEMP")) ||
        Path.GetFileName(executable) != "chrome.exe" || !File.Exists(executable) ||
        page.Length > 16384 || !page.Contains("@@OWNER_TOKEN@@"))
      throw new InvalidOperationException("owned_browser_arguments");
    Owner = Guid.NewGuid().ToString("N");
    Root = Path.Combine(Environment.GetEnvironmentVariable("RUNNER_TEMP"), "clipboard-browser-" + Owner);
    if (Directory.Exists(Root) || File.Exists(Root)) throw new InvalidOperationException("owned_browser_root_exists");
    Directory.CreateDirectory(Root);
    try {
      string html = Path.Combine(Root, "paste.html");
      File.WriteAllText(html, page.Replace("@@OWNER_TOKEN@@", Owner), new UTF8Encoding(false));
      PageUrl = new Uri(html).AbsoluteUri;
      File.WriteAllText(Files[0], "alpha file \u4e2d\u6587\ud83d\ude00\n", new UTF8Encoding(false));
      File.WriteAllText(Files[1], "beta file second line\n", new UTF8Encoding(false));
      job = CreateJobObject(IntPtr.Zero, null);
      var limits = new ExtendedLimits { basic = new BasicLimits { flags = 0x2000 } }; // KILL_ON_JOB_CLOSE, no breakaway/UI limits.
      if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
        throw new InvalidOperationException("owned_browser_job_creation");
      string profile = Path.Combine(Root, "profile");
      string command = "\"" + executable + "\" --user-data-dir=\"" + profile + "\" --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 --no-first-run --no-default-browser-check --disable-background-networking --disable-component-update --disable-sync --enable-automation --new-window --window-position=32,32 --window-size=800,600 \"" + PageUrl + "\"";
      var startup = new StartupInfo { size = (uint)Marshal.SizeOf(typeof(StartupInfo)) };
      ProcessInfo info;
      if (!CreateProcessW(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, 4, IntPtr.Zero, Root, ref startup, out info))
        throw new InvalidOperationException("owned_browser_create_suspended");
      process = info.process; ProcessId = info.id;
      try {
        // Assign while suspended, before any child can escape cleanup ownership.
        if (!AssignProcessToJobObject(job, process)) {
          throw new InvalidOperationException("owned_browser_job_assignment");
        }
        processAssigned = true;
        if (ResumeThread(info.thread) == UInt32.MaxValue) throw new InvalidOperationException("owned_browser_resume");
      } finally { CloseHandle(info.thread); }
    } catch {
      Dispose(); throw;
    }
  }
  public bool PortReady { get { Running(); return File.Exists(Path.Combine(Root, "profile", "DevToolsActivePort")); } }
  public bool Connect() {
    Running();
    uint code;
    if (!GetExitCodeProcess(process, out code)) throw new InvalidOperationException("owned_browser_process_status");
    if (code != 259) throw new InvalidOperationException("owned_browser_exited_before_endpoint_" + code);
    string path = Path.Combine(Root, "profile", "DevToolsActivePort");
    if (new FileInfo(path).Length > 256) throw new InvalidOperationException("owned_browser_endpoint_bound");
    string[] lines = File.ReadAllLines(path);
    int port;
    if (lines.Length != 2 || !Int32.TryParse(lines[0], out port) || port < 1024 || port > 65535 ||
        !System.Text.RegularExpressions.Regex.IsMatch(lines[1], "^/devtools/browser/[a-zA-Z0-9-]+$"))
      throw new InvalidOperationException("owned_browser_endpoint_invalid");
    var connection = new ClientWebSocket();
    // The endpoint is private loopback, never the runner's configured proxy.
    connection.Options.Proxy = null;
    try {
      using (var deadline = new CancellationTokenSource(1000))
        connection.ConnectAsync(new Uri("ws://127.0.0.1:" + port + lines[1]), deadline.Token).GetAwaiter().GetResult();
      socket = connection;
      return true;
    } catch (WebSocketException) { connection.Dispose(); return false; }
      catch (OperationCanceledException) { connection.Dispose(); return false; }
      catch (System.Net.WebException error) {
        connection.Dispose();
        if (error.Status == System.Net.WebExceptionStatus.ConnectFailure || error.Status == System.Net.WebExceptionStatus.Timeout) return false;
        throw;
      }
  }
  public void Send(string packet) {
    Running();
    byte[] data = Encoding.UTF8.GetBytes(packet);
    if (data.Length > 65536) throw new InvalidOperationException("browser_command_bound");
    using (var deadline = new CancellationTokenSource(5000))
      socket.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Text, true, deadline.Token).GetAwaiter().GetResult();
  }
  public string Receive(int milliseconds) {
    Running();
    if (milliseconds <= 0 || milliseconds > 5000) throw new InvalidOperationException("browser_reply_deadline");
    using (var deadline = new CancellationTokenSource(milliseconds))
    using (var output = new MemoryStream()) {
      var bytes = new byte[8192];
      WebSocketReceiveResult part;
      do {
        part = socket.ReceiveAsync(new ArraySegment<byte>(bytes), deadline.Token).GetAwaiter().GetResult();
        if (part.MessageType != WebSocketMessageType.Text || output.Length + part.Count > 262144)
          throw new InvalidOperationException("browser_reply_bound");
        output.Write(bytes, 0, part.Count);
      } while (!part.EndOfMessage);
      return Encoding.UTF8.GetString(output.ToArray());
    }
  }
  public IntPtr Window() {
    Running(); IntPtr found = IntPtr.Zero; int count = 0;
    EnumWindows(delegate(IntPtr window, IntPtr ignored) {
      uint owner; GetWindowThreadProcessId(window, out owner);
      if (owner != ProcessId || !IsWindowVisible(window)) return true;
      var name = new StringBuilder(128);
      if (GetClassName(window, name, name.Capacity) > 0 && name.ToString() == "Chrome_WidgetWin_1") { found = window; count++; }
      return true;
    }, IntPtr.Zero);
    if (count > 1) throw new InvalidOperationException("owned_browser_window_not_unique");
    return found;
  }
  public void Activate(IntPtr window) {
    Running(); uint owner; GetWindowThreadProcessId(window, out owner);
    if (window == IntPtr.Zero || owner != ProcessId || window != Window()) throw new InvalidOperationException("browser_window_not_owned");
    SetForegroundWindow(window);
  }
  public void WriteFixture(string kind) {
    Running(); Exception failure = null;
    var writer = new Thread(delegate() {
      try {
        var data = new DataObject();
        if (kind == "text") data.SetData(DataFormats.UnicodeText, false, PlainText);
        else if (kind == "html") {
          string prefix = "<html><body><!--StartFragment-->";
          string fragment = "<p>Browser <b>" + BoldText + "</b></p>";
          string suffix = "<!--EndFragment--></body></html>";
          string format = "Version:1.0\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
          int start = Encoding.UTF8.GetByteCount(String.Format(format, 0, 0, 0, 0));
          int fragmentStart = start + Encoding.UTF8.GetByteCount(prefix);
          int fragmentEnd = fragmentStart + Encoding.UTF8.GetByteCount(fragment);
          string header = String.Format(format, start, fragmentEnd + Encoding.UTF8.GetByteCount(suffix), fragmentStart, fragmentEnd);
          data.SetData(DataFormats.Html, false, header + prefix + fragment + suffix);
          data.SetData(DataFormats.UnicodeText, false, HtmlText);
        } else if (kind == "files") {
          var paths = new StringCollection(); paths.AddRange(Files); data.SetFileDropList(paths);
        } else if (kind == "image") {
          using (var image = new Bitmap(3, 2))
          using (var png = new MemoryStream()) {
            var colors = new Color[] { Color.Red, Color.Lime, Color.Blue, Color.Yellow, Color.Cyan, Color.Magenta };
            for (int i = 0; i < colors.Length; i++) image.SetPixel(i % 3, i / 3, colors[i]);
            image.Save(png, System.Drawing.Imaging.ImageFormat.Png); png.Position = 0;
            data.SetData("PNG", false, png); data.SetImage(image);
            Clipboard.SetDataObject(data, true, 0, 0); return;
          }
        } else throw new InvalidOperationException("unknown_browser_fixture");
        Clipboard.SetDataObject(data, true, 0, 0);
      } catch (Exception error) { failure = error; }
    });
    writer.IsBackground = true; writer.SetApartmentState(ApartmentState.STA); writer.Start();
    if (!writer.Join(5000)) throw new InvalidOperationException("browser_fixture_writer_timeout");
    if (failure != null) throw new InvalidOperationException("browser_fixture_writer_failed", failure);
  }
  public void Dispose() {
    if (disposed) return;
    disposed = true;
    Exception teardownFailure = null, profileFailure = null;
    try {
      try {
        if (socket != null) socket.Dispose();
        if (process != IntPtr.Zero && !processAssigned && !TerminateProcess(process, 1))
          throw new InvalidOperationException("owned_suspended_browser_termination");
        if (job != IntPtr.Zero) {
          if (!TerminateJobObject(job, 0)) throw new InvalidOperationException("owned_browser_job_termination");
          var deadline = Stopwatch.StartNew();
          while (true) {
            Accounting accounting;
            if (!QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero))
              throw new InvalidOperationException("owned_browser_job_accounting");
            if (accounting.active == 0) break;
            if (deadline.ElapsedMilliseconds > 5000) throw new InvalidOperationException("owned_browser_job_cleanup_timeout");
            Thread.Sleep(50);
          }
        }
        if (process != IntPtr.Zero && WaitForSingleObject(process, 5000) != 0)
          throw new InvalidOperationException("owned_browser_process_exit_timeout");
      } finally {
        if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
      }
    } catch (Exception error) { teardownFailure = error; }
    finally {
      // Attempt private-file cleanup even if termination/accounting/handle
      // teardown fails. Preserve both failures instead of hiding the first.
      try {
        if (Root != null && Directory.Exists(Root)) {
          var deadline = Stopwatch.StartNew();
          while (true) {
            try { Directory.Delete(Root, true); break; }
            catch (IOException) { if (deadline.ElapsedMilliseconds > 5000) throw; Thread.Sleep(100); }
            catch (UnauthorizedAccessException) { if (deadline.ElapsedMilliseconds > 5000) throw; Thread.Sleep(100); }
          }
        }
      } catch (Exception error) { profileFailure = error; }
    }
    if (teardownFailure != null && profileFailure != null)
      throw new AggregateException("owned_browser_teardown_and_profile_cleanup_failed", teardownFailure, profileFailure);
    if (teardownFailure != null)
      throw new InvalidOperationException("owned_browser_process_teardown_failed", teardownFailure);
    if (profileFailure != null)
      throw new InvalidOperationException("owned_browser_profile_cleanup_failed", profileFailure);
    CleanupComplete = true;
  }
}
