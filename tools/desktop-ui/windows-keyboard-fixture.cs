// Owned GitHub Actions desktop only. Never loaded by the application.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public sealed class ClipboardKeyboardFixture : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct KeyboardInput {
    public ushort key, scan;
    public uint flags, time;
    public UIntPtr extra;
  }
  [StructLayout(LayoutKind.Sequential)] struct MouseInput {
    public int x, y;
    public uint data, flags, time;
    public UIntPtr extra;
  }
  [StructLayout(LayoutKind.Explicit)] struct InputData {
    [FieldOffset(0)] public KeyboardInput keyboard;
    [FieldOffset(0)] public MouseInput mouse;
  }
  [StructLayout(LayoutKind.Sequential)] struct Input {
    public uint type;
    public InputData data;
  }
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, Input[] inputs, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
  [DllImport("imm32.dll")] static extern bool ImmIsIME(IntPtr layout);

  sealed class PasteEditor : TextBox {
    public int PasteCount;
    protected override void WndProc(ref Message message) {
      if (message.Msg == 0x0302) PasteCount++; // WM_PASTE from the actual Ctrl+V.
      base.WndProc(ref message);
    }
  }
  readonly Thread thread;
  readonly ManualResetEvent ready = new ManualResetEvent(false);
  Form form;
  PasteEditor editor;
  Exception startupError;
  IntPtr handle;
  readonly uint applicationProcess;
  bool disposed;
  public IntPtr Handle { get { return handle; } }

  public ClipboardKeyboardFixture(uint applicationProcess) {
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
        Environment.OSVersion.Platform != PlatformID.Win32NT)
      throw new InvalidOperationException("keyboard_fixture_requires_windows_actions");
    this.applicationProcess = applicationProcess;
    thread = new Thread(delegate() {
      try {
        form = new Form { Text = "Clipboard owned synthetic paste target", Width = 500, Height = 180 };
        editor = new PasteEditor { Multiline = true, Dock = DockStyle.Fill, AcceptsReturn = true };
        form.Controls.Add(editor);
        form.Shown += delegate { handle = form.Handle; editor.Focus(); ready.Set(); };
        Application.Run(form);
      } catch (Exception error) { startupError = error; ready.Set(); }
    });
    thread.IsBackground = true;
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    if (!ready.WaitOne(10000) || startupError != null || handle == IntPtr.Zero)
      throw new InvalidOperationException("keyboard_peer_start_failed");
  }

  T OnPeer<T>(Func<T> action) {
    if (disposed || form == null || !thread.IsAlive) throw new InvalidOperationException("keyboard_peer_not_running");
    IAsyncResult pending = form.BeginInvoke(action);
    if (!pending.AsyncWaitHandle.WaitOne(5000)) throw new InvalidOperationException("keyboard_peer_dispatch_timeout");
    return (T)form.EndInvoke(pending);
  }
  public void Activate() {
    OnPeer<bool>(delegate { form.Show(); form.Activate(); editor.Focus(); return true; });
    SetForegroundWindow(handle);
  }
  public int PasteCount { get { return OnPeer<int>(delegate { return editor.PasteCount; }); } }
  public string Text { get { return OnPeer<string>(delegate { return editor.Text; }); } }

  void CheckTarget(IntPtr expected) {
    if (disposed || expected == IntPtr.Zero || GetForegroundWindow() != expected)
      throw new InvalidOperationException("keyboard_target_is_not_foreground");
    uint owner;
    GetWindowThreadProcessId(expected, out owner);
    if (owner == 0 || (expected == handle
        ? owner != (uint)System.Diagnostics.Process.GetCurrentProcess().Id
        : owner != applicationProcess))
      throw new InvalidOperationException("keyboard_target_not_owned");
    foreach (int modifier in new int[] { 0x10, 0x11, 0x12, 0x5b, 0x5c })
      if ((GetAsyncKeyState(modifier) & 0x8000) != 0)
        throw new InvalidOperationException("keyboard_modifier_already_held");
  }
  static Input Key(ushort key, bool up) {
    return new Input { type = 1, data = new InputData {
      keyboard = new KeyboardInput { key = key, flags = up ? 2u : 0u } } };
  }
  void Send(IntPtr target, Input[] inputs) {
    CheckTarget(target);
    int size = Marshal.SizeOf(typeof(Input));
    if (size != (IntPtr.Size == 8 ? 40 : 28)) throw new InvalidOperationException("keyboard_input_layout");
    uint written = SendInput((uint)inputs.Length, inputs, size);
    if (written != inputs.Length) {
      // Release only keys this submission may have pressed; never retry input.
      var releases = new List<Input>();
      for (int i = 0; i < written; i++) {
        Input input = inputs[i];
        if ((input.data.keyboard.flags & 2) == 0) {
          Input release = input;
          release.data.keyboard.flags |= 2;
          releases.Add(release);
        }
      }
      SendInput((uint)releases.Count, releases.ToArray(), size);
      throw new InvalidOperationException("keyboard_input_incomplete");
    }
  }
  public void Chord(IntPtr target, ushort[] keys) {
    var inputs = new List<Input>();
    foreach (ushort key in keys) inputs.Add(Key(key, false));
    for (int i = keys.Length - 1; i >= 0; i--) inputs.Add(Key(keys[i], true));
    Send(target, inputs.ToArray());
  }
  public void TypeAscii(IntPtr target, string text) {
    uint ignored;
    uint threadId = GetWindowThreadProcessId(target, out ignored);
    if (((long)GetKeyboardLayout(threadId) & 0xffff) != 0x0409)
      throw new InvalidOperationException("ascii_fixture_requires_english_us_layout");
    var inputs = new List<Input>();
    foreach (char character in text) {
      if (character < 'a' || character > 'z') throw new InvalidOperationException("ascii_fixture_only_lowercase_letters");
      ushort key = (ushort)(character - 'a' + 'A');
      inputs.Add(Key(key, false)); inputs.Add(Key(key, true));
    }
    Send(target, inputs.ToArray());
  }
  public void TypeUnicode(IntPtr target, string text) {
    var inputs = new List<Input>();
    foreach (char character in text) {
      Input down = new Input { type = 1, data = new InputData {
        keyboard = new KeyboardInput { scan = character, flags = 4 } } };
      Input up = down; up.data.keyboard.flags |= 2;
      inputs.Add(down); inputs.Add(up);
    }
    Send(target, inputs.ToArray());
  }
  public int InstalledChineseImeCount() {
    int count = GetKeyboardLayoutList(0, null);
    if (count < 0 || count > 256) throw new InvalidOperationException("keyboard_layout_count");
    var layouts = new IntPtr[count];
    count = GetKeyboardLayoutList(count, layouts);
    int result = 0;
    for (int i = 0; i < count; i++)
      if (((long)layouts[i] & 0x3ff) == 4 && ImmIsIME(layouts[i])) result++;
    return result;
  }
  public void Dispose() {
    if (disposed) return;
    if (form != null && thread.IsAlive) OnPeer<bool>(delegate { form.Close(); return true; });
    if (!thread.Join(5000)) throw new InvalidOperationException("keyboard_peer_shutdown_timeout");
    disposed = true;
    ready.Dispose();
  }
}
