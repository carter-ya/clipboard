// Owned GitHub Actions desktop only. Never loaded by the application.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public sealed class ClipboardKeyboardFixture : IDisposable {
  public sealed class TargetImeStatus {
    public long Layout;
    public int Language;
    public bool WindowPresent, QuerySucceeded, Open;
    public ulong Conversion;
  }
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
  [StructLayout(LayoutKind.Sequential)] struct WindowRect { public int left, top, right, bottom; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out WindowRect rectangle);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr parameter, IntPtr data, uint flags, uint timeout, out UIntPtr result);
  [DllImport("imm32.dll")] static extern IntPtr ImmGetDefaultIMEWnd(IntPtr window);
  [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
  [DllImport("imm32.dll")] static extern bool ImmIsIME(IntPtr layout);
  [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr window);
  [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr window, IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetOpenStatus(IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetConversionStatus(IntPtr context, out uint conversion, out uint sentence);
  [DllImport("imm32.dll", CharSet = CharSet.Unicode)] static extern int ImmGetCompositionStringW(IntPtr context, uint kind, IntPtr data, uint size);
  [DllImport("msctf.dll")] static extern int TF_CreateInputProcessorProfiles(out IntPtr profiles);
  // First vtable entry from the official msctf.h ITfInputProcessorProfileMgr.
  [ComImport, Guid("71c6e74c-0f28-11d8-a82a-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface InputProcessorProfileManager {
    [PreserveSig] int ActivateProfile(uint type, ushort language, ref Guid processor,
                                    ref Guid profile, IntPtr layout, uint flags);
  }
  public int ImeActivationResult { get; private set; }

  sealed class PasteEditor : TextBox {
    public int PasteCount;
    public int KeyMessages, ScannedKeyMessages, ImeMessages;
    protected override void WndProc(ref Message message) {
      if (message.Msg == 0x0302) PasteCount++; // WM_PASTE from the actual Ctrl+V.
      if (message.Msg == 0x0100 || message.Msg == 0x0104) {
        KeyMessages++;
        if (((long)message.LParam & 0x00ff0000) != 0) ScannedKeyMessages++;
      }
      if (message.Msg >= 0x010d && message.Msg <= 0x010f) ImeMessages++;
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
    // powershell.exe targets the legacy .NET Framework compatibility defaults.
    // Opt this owned helper process into the documented multiline Ctrl+A fix.
    AppContext.SetSwitch("Switch.System.Windows.Forms.DoNotSupportSelectAllShortcutInMultilineTextBox", false);
    thread = new Thread(delegate() {
      try {
        InputLanguage english = null;
        foreach (InputLanguage language in InputLanguage.InstalledInputLanguages)
          if (language.Culture.Name == "en-US") { english = language; break; }
        if (english == null) throw new InvalidOperationException("owned_peer_requires_english_input_profile");
        InputLanguage.CurrentInputLanguage = english;
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
  public int SelectionLength { get { return OnPeer<int>(delegate { return editor.SelectionLength; }); } }
  public int KeyMessageCount { get { return OnPeer<int>(delegate { return editor.KeyMessages; }); } }
  public int ScannedKeyMessageCount { get { return OnPeer<int>(delegate { return editor.ScannedKeyMessages; }); } }
  public int ImeMessageCount { get { return OnPeer<int>(delegate { return editor.ImeMessages; }); } }
  public long InputLayout { get { return OnPeer<long>(delegate { uint owner; return (long)GetKeyboardLayout(GetWindowThreadProcessId(editor.Handle, out owner)); }); } }
  public byte[] CaptureOwnedForegroundWindow() {
    return OnPeer<byte[]>(delegate {
      uint owner;
      GetWindowThreadProcessId(handle, out owner);
      WindowRect rectangle;
      if (GetForegroundWindow() != handle || owner != (uint)System.Diagnostics.Process.GetCurrentProcess().Id ||
          !GetWindowRect(handle, out rectangle)) throw new InvalidOperationException("ime_capture_requires_owned_foreground");
      int width = rectangle.right - rectangle.left, height = rectangle.bottom - rectangle.top;
      if (width <= 0 || height <= 0 || width > 2048 || height > 2048) throw new InvalidOperationException("ime_capture_bound");
      using (var bitmap = new System.Drawing.Bitmap(width, height))
      using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
      using (var output = new System.IO.MemoryStream()) {
        graphics.CopyFromScreen(rectangle.left, rectangle.top, 0, 0, bitmap.Size);
        bitmap.Save(output, System.Drawing.Imaging.ImageFormat.Png);
        return output.ToArray();
      }
    });
  }

  void CheckTarget(IntPtr expected, bool checkModifiers = true) {
    if (disposed || expected == IntPtr.Zero || GetForegroundWindow() != expected)
      throw new InvalidOperationException("keyboard_target_is_not_foreground");
    uint owner;
    GetWindowThreadProcessId(expected, out owner);
    if (owner == 0 || (expected == handle
        ? owner != (uint)System.Diagnostics.Process.GetCurrentProcess().Id
        : owner != applicationProcess))
      throw new InvalidOperationException("keyboard_target_not_owned");
    if (checkModifiers)
      foreach (int modifier in new int[] { 0x10, 0x11, 0x12, 0x5b, 0x5c })
        if ((GetAsyncKeyState(modifier) & 0x8000) != 0)
          throw new InvalidOperationException("keyboard_modifier_already_held");
  }
  static Input Key(ushort key, bool up) {
    // Navigation keys and Windows keys carry the E0 extended-key flag on a
    // physical keyboard. Without it an IME may interpret keypad navigation.
    bool extended = (key >= 0x21 && key <= 0x28) || key == 0x2d || key == 0x2e ||
                    key == 0x5b || key == 0x5c || key == 0xa3 || key == 0xa5;
    ushort scan = (ushort)(MapVirtualKey(key, 0) & 0xff);
    if (scan == 0) throw new InvalidOperationException("keyboard_virtual_key_has_no_scan_code");
    return new Input { type = 1, data = new InputData {
      keyboard = new KeyboardInput { key = key, scan = scan, flags = (extended ? 1u : 0u) | (up ? 2u : 0u) } } };
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
  public int TargetInputLanguage(IntPtr target) {
    CheckTarget(target, false);
    uint process;
    return (int)((long)GetKeyboardLayout(GetWindowThreadProcessId(target, out process)) & 0xffff);
  }
  // Content-free observation of the owned target only. These WM_IME_CONTROL
  // commands query state; they never set a profile, mode, text or composition.
  public TargetImeStatus ReadTargetImeStatus(IntPtr target) {
    CheckTarget(target, false);
    uint process;
    long layout = GetKeyboardLayout(GetWindowThreadProcessId(target, out process)).ToInt64();
    var state = new TargetImeStatus { Layout = layout, Language = (int)(layout & 0xffff) };
    IntPtr ime = ImmGetDefaultIMEWnd(target);
    state.WindowPresent = ime != IntPtr.Zero;
    if (!state.WindowPresent) return state;
    UIntPtr open = UIntPtr.Zero, conversion = UIntPtr.Zero;
    state.QuerySucceeded =
      SendMessageTimeout(ime, 0x0283, new UIntPtr(5), IntPtr.Zero, 3, 1000, out open) != IntPtr.Zero &&
      SendMessageTimeout(ime, 0x0283, new UIntPtr(1), IntPtr.Zero, 3, 1000, out conversion) != IntPtr.Zero;
    if (state.QuerySucceeded) {
      state.Open = open.ToUInt64() != 0;
      state.Conversion = conversion.ToUInt64();
    }
    return state;
  }
  // Query only the OS-created IME window associated with this owned target.
  // This does not set conversion flags or synthesize composition messages.
  public bool TargetChineseMode(IntPtr target) {
    CheckTarget(target, false);
    IntPtr ime = ImmGetDefaultIMEWnd(target);
    if (ime == IntPtr.Zero) throw new InvalidOperationException("owned_target_ime_window_unavailable");
    UIntPtr open, conversion;
    if (SendMessageTimeout(ime, 0x0283, new UIntPtr(5), IntPtr.Zero, 3, 1000, out open) == IntPtr.Zero ||
        SendMessageTimeout(ime, 0x0283, new UIntPtr(1), IntPtr.Zero, 3, 1000, out conversion) == IntPtr.Zero)
      throw new InvalidOperationException("owned_target_ime_status_timeout");
    return open.ToUInt64() != 0 && (conversion.ToUInt64() & 1) != 0;
  }
  public void TypeAscii(IntPtr target, string text) {
    uint ignored;
    uint threadId = GetWindowThreadProcessId(target, out ignored);
    if (((long)GetKeyboardLayout(threadId) & 0xffff) != 0x0409)
      throw new InvalidOperationException("ascii_fixture_requires_english_us_layout");
    TypeLatinKeys(target, text);
  }
  public void TypeLatinKeys(IntPtr target, string text) {
    var inputs = new List<Input>();
    foreach (char character in text) {
      if (character < 'a' || character > 'z') throw new InvalidOperationException("ascii_fixture_only_lowercase_letters");
      ushort key = (ushort)(character - 'a' + 'A');
      uint scan = MapVirtualKey(key, 0);
      if (scan == 0 || scan > 0xff) throw new InvalidOperationException("latin_key_scan_unavailable");
      Input down = new Input { type = 1, data = new InputData {
        keyboard = new KeyboardInput { scan = (ushort)scan, flags = 8 } } };
      Input up = down; up.data.keyboard.flags |= 2;
      inputs.Add(down); inputs.Add(up);
    }
    Send(target, inputs.ToArray());
  }
  T WithIme<T>(Func<IntPtr, T> action) {
    return OnPeer<T>(delegate {
      IntPtr context = ImmGetContext(editor.Handle);
      if (context == IntPtr.Zero) throw new InvalidOperationException("native_ime_context_unavailable");
      try { return action(context); }
      finally { ImmReleaseContext(editor.Handle, context); }
    });
  }
  public void UseChineseIme() {
    OnPeer<bool>(delegate {
      InputLanguage chinese = null;
      foreach (InputLanguage language in InputLanguage.InstalledInputLanguages)
        if (language.Culture.Name == "zh-CN") { chinese = language; break; }
      if (chinese == null) throw new InvalidOperationException("native_chinese_input_language_unavailable");
      InputLanguage.CurrentInputLanguage = chinese;
      // A Chinese keyboard layout alone can still emit literal Latin keys.
      // Activate Microsoft's documented Pinyin text-service profile on this
      // owned STA thread, without changing other applications' input profiles.
      IntPtr pointer;
      ImeActivationResult = TF_CreateInputProcessorProfiles(out pointer);
      if (ImeActivationResult < 0) throw new InvalidOperationException("native_pinyin_profiles_unavailable");
      object profiles = Marshal.GetObjectForIUnknown(pointer);
      try {
        Guid processor = new Guid("81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E");
        Guid profile = new Guid("FA550B04-5AD7-411F-A5AC-CA038EC515D7");
        ImeActivationResult = ((InputProcessorProfileManager)profiles).ActivateProfile(
          1, 0x0804, ref processor, ref profile, IntPtr.Zero, 1);
        if (ImeActivationResult != 0) throw new InvalidOperationException("native_pinyin_profile_activation_failed");
      } finally { Marshal.ReleaseComObject(profiles); Marshal.Release(pointer); }
      // Leave conversion policy to the actual activated text service. The
      // fixture uses the provider's normal mode shortcut rather than letting the
      // legacy Forms focus handler rewrite the provider's conversion state.
      editor.ImeMode = ImeMode.NoControl;
      editor.Focus();
      return true;
    });
  }
  public bool ImeOpen { get { return WithIme<bool>(delegate(IntPtr context) { return ImmGetOpenStatus(context); }); } }
  public uint ImeConversionMode { get { return WithIme<uint>(delegate(IntPtr context) {
    uint conversion, sentence;
    if (!ImmGetConversionStatus(context, out conversion, out sentence)) throw new InvalidOperationException("native_ime_conversion_unavailable");
    return conversion;
  }); } }
  public int CompositionLength {
    get { return WithIme<int>(delegate(IntPtr context) {
      int bytes = ImmGetCompositionStringW(context, 8, IntPtr.Zero, 0);
      if (bytes < -1 || bytes > 65536) throw new InvalidOperationException("native_ime_composition_bound");
      return bytes < 0 ? 0 : bytes / 2;
    }); }
  }
  // Read the real preedit, not the committed TextBox value. Pinyin may add
  // syllable separators; all five Latin letters must have reached the IME.
  public bool CompositionIsNihao {
    get { return WithIme<bool>(delegate(IntPtr context) {
      int bytes = ImmGetCompositionStringW(context, 8, IntPtr.Zero, 0);
      if (bytes <= 0) return false;
      if (bytes > 65536 || bytes % 2 != 0) throw new InvalidOperationException("native_ime_composition_bound");
      IntPtr data = Marshal.AllocHGlobal(bytes);
      try {
        int read = ImmGetCompositionStringW(context, 8, data, (uint)bytes);
        if (read < 0 || read > bytes || read % 2 != 0) throw new InvalidOperationException("native_ime_composition_read");
        return Marshal.PtrToStringUni(data, read / 2).Replace("'", "") == "nihao";
      } finally { Marshal.FreeHGlobal(data); }
    }); }
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
