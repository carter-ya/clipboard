// Independent owned Windows RichEdit receiver. No application references.
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class ClipboardOwnedRichText : IDisposable {
  sealed class PasteEditor : RichTextBox {
    public int ScannedPasteKeys, PasteMessages;
    protected override bool ProcessCmdKey(ref Message message, Keys keys) {
      if (keys == (Keys.Control | Keys.V) && message.Msg == 0x0100 &&
          ((long)message.LParam & 0x00ff0000) != 0) ScannedPasteKeys++;
      return base.ProcessCmdKey(ref message, keys);
    }
    protected override void WndProc(ref Message message) {
      if (message.Msg == 0x0302) PasteMessages++;
      base.WndProc(ref message);
    }
  }
  public sealed class Receipt {
    public string Text, SelectedText;
    public int SelectionStart, SelectionLength, Color, ScannedPasteKeys, PasteMessages;
    public bool Focused, Bold, Italic, HasSingleFont;
    public float Points;
  }
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
  [DllImport("user32.dll")] static extern bool CloseClipboard();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
  [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
  [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
  [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);

  readonly Thread thread;
  readonly ManualResetEvent ready = new ManualResetEvent(false);
  Form form;
  PasteEditor editor;
  Exception startupError;
  IntPtr handle;
  bool disposed;
  public IntPtr Handle { get { return handle; } }
  public bool Stopped { get { Guard(); return !thread.IsAlive; } }
  public bool CleanupComplete { get; private set; }
  public uint ClipboardRevision { get { Guard(); return GetClipboardSequenceNumber(); } }
  public string ExpectedText { get { return "RTF fixture \u4e2d\u6587\ud83d\ude00\nsecond line"; } }
  public string Rtf { get { return
    "{\\rtf1\\ansi\\ansicpg1252\\uc1{\\fonttbl{\\f0\\fnil Segoe UI;}}" +
    "{\\colortbl;\\red220\\green20\\blue60;}\\f0\\fs24 RTF " +
    "\\cf1\\b fixture\\b0\\cf0  \\u20013?\\u25991?\\u-10179?\\u-8704?\\par \\i second line\\i0}"; } }
  static void Guard() {
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
        Environment.OSVersion.Platform != PlatformID.Win32NT)
      throw new InvalidOperationException("richtext_fixture_requires_owned_windows_actions");
  }
  void Running() {
    Guard();
    if (disposed || handle == IntPtr.Zero || !thread.IsAlive)
      throw new InvalidOperationException("owned_richtext_not_running");
  }
  public ClipboardOwnedRichText() {
    Guard();
    thread = new Thread(delegate() {
      try {
        InputLanguage english = null;
        foreach (InputLanguage input in InputLanguage.InstalledInputLanguages)
          if (input.Culture.Name == "en-US") { english = input; break; }
        if (english == null) throw new InvalidOperationException("owned_richtext_requires_english_profile");
        InputLanguage.CurrentInputLanguage = english;
        form = new Form { Text = "Clipboard owned synthetic rich-text target", Width = 560, Height = 220 };
        editor = new PasteEditor { Dock = DockStyle.Fill, DetectUrls = false };
        form.Controls.Add(editor);
        form.Shown += delegate { handle = form.Handle; editor.Focus(); ready.Set(); };
        Application.Run(form);
      } catch (Exception error) { startupError = error; ready.Set(); }
    });
    thread.IsBackground = true;
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    if (!ready.WaitOne(10000) || startupError != null || handle == IntPtr.Zero) {
      var failure = new InvalidOperationException("owned_richtext_start_failed", startupError);
      try { Dispose(); } catch (Exception cleanup) { throw new AggregateException(failure, cleanup); }
      throw failure;
    }
  }
  T OnEditor<T>(Func<T> action) {
    Guard();
    if (disposed || form == null || !thread.IsAlive)
      throw new InvalidOperationException("owned_richtext_dispatch_unavailable");
    IAsyncResult pending = form.BeginInvoke(action);
    try {
      if (!pending.AsyncWaitHandle.WaitOne(5000))
        throw new InvalidOperationException("owned_richtext_dispatch_timeout");
      return (T)form.EndInvoke(pending);
    } finally { pending.AsyncWaitHandle.Close(); }
  }
  void VerifyOwned() {
    uint owner, childOwner;
    GetWindowThreadProcessId(handle, out owner);
    GetWindowThreadProcessId(editor.Handle, out childOwner);
    uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    if (owner != self || childOwner != self || form.Handle != handle)
      throw new InvalidOperationException("richtext_receiver_identity_mismatch");
  }
  public void Activate() {
    Running();
    OnEditor<bool>(delegate { VerifyOwned(); form.Activate(); editor.Focus(); return true; });
    SetForegroundWindow(handle);
  }
  public Receipt Read() {
    Running();
    return OnEditor<Receipt>(delegate {
      VerifyOwned();
      if (editor.TextLength > 4096) throw new InvalidOperationException("owned_richtext_document_bound");
      using (Font font = editor.SelectionFont) {
        return new Receipt { Text = editor.Text, SelectedText = editor.SelectedText,
          SelectionStart = editor.SelectionStart, SelectionLength = editor.SelectionLength,
          Focused = GetForegroundWindow() == handle && editor.Focused,
          HasSingleFont = font != null, Bold = font != null && font.Bold,
          Italic = font != null && font.Italic, Points = font == null ? 0 : font.SizeInPoints,
          Color = editor.SelectionColor.ToArgb() & 0xffffff,
          ScannedPasteKeys = editor.ScannedPasteKeys, PasteMessages = editor.PasteMessages };
      }
    });
  }
  public void WriteFixture() {
    Running();
    Exception failure = null;
    var writer = new Thread(delegate() {
      try {
        using (var bytes = new MemoryStream(Encoding.ASCII.GetBytes(Rtf + "\0"))) {
          var data = new DataObject();
          data.SetData(DataFormats.Rtf, false, bytes);
          Clipboard.SetDataObject(data, true, 0, 0);
        }
      } catch (Exception error) { failure = error; }
    });
    writer.IsBackground = true;
    writer.SetApartmentState(ApartmentState.STA);
    writer.Start();
    if (!writer.Join(5000)) throw new InvalidOperationException("owned_rtf_writer_timeout");
    if (failure != null) throw new InvalidOperationException("owned_rtf_writer_failed", failure);
  }
  public bool SourceMatches() {
    Running();
    if (!OpenClipboard(IntPtr.Zero)) return false;
    try {
      IntPtr value = GetClipboardData(RegisterClipboardFormat("Rich Text Format"));
      ulong size = value == IntPtr.Zero ? 0 : GlobalSize(value).ToUInt64();
      if (size == 0 || size > 4096) return false;
      IntPtr pointer = GlobalLock(value);
      if (pointer == IntPtr.Zero) return false;
      try {
        byte[] bytes = new byte[(int)size];
        Marshal.Copy(pointer, bytes, 0, bytes.Length);
        return Encoding.ASCII.GetString(bytes).TrimEnd('\0') == Rtf;
      } finally { GlobalUnlock(value); }
    } finally { CloseClipboard(); }
  }
  public void Dispose() {
    Guard();
    if (disposed) return;
    if (form != null && thread.IsAlive)
      OnEditor<bool>(delegate { form.Close(); return true; });
    if (!thread.Join(5000)) throw new InvalidOperationException("owned_richtext_shutdown_timeout");
    disposed = true;
    ready.Dispose();
    CleanupComplete = true;
  }
}
