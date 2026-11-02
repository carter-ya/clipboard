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
  [StructLayout(LayoutKind.Sequential)] struct WindowRect { public int left, top, right, bottom; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out WindowRect rectangle);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
  [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
  [DllImport("imm32.dll")] static extern bool ImmIsIME(IntPtr layout);
  [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr window);
  [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr window, IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetOpenStatus(IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetConversionStatus(IntPtr context, out uint conversion, out uint sentence);
  [DllImport("imm32.dll", CharSet = CharSet.Unicode)] static extern int ImmGetCompositionStringW(IntPtr context, uint kind, IntPtr data, uint size);
  [DllImport("imm32.dll", CharSet = CharSet.Unicode)] static extern uint ImmGetCandidateListW(IntPtr context, uint index, IntPtr data, uint size);
  [DllImport("msctf.dll")] static extern int TF_CreateInputProcessorProfiles(out IntPtr profiles);
  [DllImport("msctf.dll")] static extern int TF_GetThreadMgr(out IntPtr manager);
  // First vtable entry from the official msctf.h ITfInputProcessorProfileMgr.
  [ComImport, Guid("71c6e74c-0f28-11d8-a82a-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface InputProcessorProfileManager {
    [PreserveSig] int ActivateProfile(uint type, ushort language, ref Guid processor,
                                    ref Guid profile, IntPtr layout, uint flags);
  }
  [ComImport, Guid("ea1ea135-19df-11d7-a6d2-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface UiElementManager {
    [PreserveSig] int BeginUIElement(IntPtr element, [MarshalAs(UnmanagedType.Bool)] ref bool show, out uint id);
    [PreserveSig] int UpdateUIElement(uint id);
    [PreserveSig] int EndUIElement(uint id);
    [PreserveSig] int GetUIElement(uint id, out IntPtr element);
    [PreserveSig] int EnumUIElements(out IntPtr enumerator);
  }
  [ComImport, Guid("887aa91e-acba-4931-84da-3c5208cf543f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface UiElementEnumerator {
    [PreserveSig] int Clone(out IntPtr clone);
    [PreserveSig] int Next(uint count, out IntPtr element, out uint fetched);
    [PreserveSig] int Reset();
    [PreserveSig] int Skip(uint count);
  }
  [ComImport, Guid("4ea48a35-60ae-446f-8fd6-e6a8d82459f7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface TsfSource {
    [PreserveSig] int AdviseSink(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] object sink, out uint cookie);
    [PreserveSig] int UnadviseSink(uint cookie);
  }
  [ComVisible(true), Guid("ea1ea136-19df-11d7-a6d2-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface UiElementSink {
    [PreserveSig] int BeginUIElement(uint id, [MarshalAs(UnmanagedType.Bool)] ref bool show);
    [PreserveSig] int UpdateUIElement(uint id);
    [PreserveSig] int EndUIElement(uint id);
  }
  [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
  public sealed class CandidateObserver : UiElementSink {
    public int Begins, Updates, Ends;
    public readonly HashSet<uint> Active = new HashSet<uint>();
    public int BeginUIElement(uint id, ref bool show) { Begins++; Active.Add(id); show = true; return 0; }
    public int UpdateUIElement(uint id) { Updates++; return 0; }
    public int EndUIElement(uint id) { Ends++; Active.Remove(id); return 0; }
  }
  // Include ITfUIElement's four inherited slots before candidate-list methods.
  [ComImport, Guid("ea1ea138-19df-11d7-a6d2-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface CandidateElement {
    [PreserveSig] int GetDescription([MarshalAs(UnmanagedType.BStr)] out string description);
    [PreserveSig] int GetGUID(out Guid guid);
    [PreserveSig] int Show([MarshalAs(UnmanagedType.Bool)] bool show);
    [PreserveSig] int IsShown([MarshalAs(UnmanagedType.Bool)] out bool show);
    [PreserveSig] int GetUpdatedFlags(out uint flags);
    [PreserveSig] int GetDocumentMgr(out IntPtr manager);
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetSelection(out uint index);
    [PreserveSig] int GetString(uint index, [MarshalAs(UnmanagedType.BStr)] out string text);
  }
  public int ImeActivationResult { get; private set; }
  public int TsfCandidateResult { get; private set; }
  public int TsfUiElementCount { get; private set; }
  public int TsfSinkResult { get; private set; }
  object tsfThread;
  TsfSource tsfSource;
  CandidateObserver candidateObserver;
  uint sinkCookie;
  public int CandidateBeginCount { get { return OnPeer<int>(delegate { return candidateObserver == null ? 0 : candidateObserver.Begins; }); } }
  public int CandidateEndCount { get { return OnPeer<int>(delegate { return candidateObserver == null ? 0 : candidateObserver.Ends; }); } }

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
      if (tsfThread == null) {
        IntPtr threadPointer;
        TsfSinkResult = TF_GetThreadMgr(out threadPointer);
        if (TsfSinkResult < 0 || threadPointer == IntPtr.Zero) throw new InvalidOperationException("native_tsf_thread_unavailable");
        try { tsfThread = Marshal.GetObjectForIUnknown(threadPointer); }
        finally { Marshal.Release(threadPointer); }
        tsfSource = (TsfSource)tsfThread;
        candidateObserver = new CandidateObserver();
        Guid sinkId = typeof(UiElementSink).GUID;
        TsfSinkResult = tsfSource.AdviseSink(ref sinkId, candidateObserver, out sinkCookie);
        if (TsfSinkResult < 0) throw new InvalidOperationException("native_tsf_candidate_observer_unavailable");
      }
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
  T WithCandidates<T>(Func<IntPtr, uint, T> action, T empty) {
    return WithIme<T>(delegate(IntPtr context) {
      uint size = ImmGetCandidateListW(context, 0, IntPtr.Zero, 0);
      if (size == 0) return empty;
      if (size < 24 || size > 65536) throw new InvalidOperationException("native_ime_candidate_bound");
      IntPtr data = Marshal.AllocHGlobal((int)size);
      try {
        uint read = ImmGetCandidateListW(context, 0, data, size);
        if (read == 0 || read > size) return empty;
        uint actual = (uint)Marshal.ReadInt32(data, 0);
        uint count = (uint)Marshal.ReadInt32(data, 8);
        if (actual < 24 || actual > size || count > 256 || 24 + count * 4 > actual)
          throw new InvalidOperationException("native_ime_candidate_header");
        return action(data, actual);
      } finally { Marshal.FreeHGlobal(data); }
    });
  }
  T WithTsfCandidate<T>(Func<CandidateElement, T> action, T empty) {
    return OnPeer<T>(delegate {
      if (GetForegroundWindow() != handle) return empty;
      IntPtr threadPointer = IntPtr.Zero, enumPointer = IntPtr.Zero;
      object threadObject = null, enumObject = null;
      TsfUiElementCount = 0;
      try {
        if (tsfThread != null) threadObject = tsfThread;
        else {
          TsfCandidateResult = TF_GetThreadMgr(out threadPointer);
          if (TsfCandidateResult < 0 || threadPointer == IntPtr.Zero) return empty;
          threadObject = Marshal.GetObjectForIUnknown(threadPointer);
        }
        var manager = threadObject as UiElementManager;
        if (manager == null) return empty;
        // Microsoft documents GetUIElement with IDs delivered to the sink.
        // Some providers notify a live element without enumerating it.
        if (candidateObserver != null) {
          if (candidateObserver.Active.Count > 32) throw new InvalidOperationException("native_tsf_active_element_bound");
          foreach (uint id in candidateObserver.Active) {
            IntPtr observedPointer;
            TsfCandidateResult = manager.GetUIElement(id, out observedPointer);
            if (TsfCandidateResult < 0 || observedPointer == IntPtr.Zero) continue;
            object observedObject = null;
            try {
              observedObject = Marshal.GetObjectForIUnknown(observedPointer);
              var candidate = observedObject as CandidateElement;
              if (candidate == null) continue;
              uint count;
              TsfCandidateResult = candidate.GetCount(out count);
              if (TsfCandidateResult < 0 || count == 0) continue;
              if (count > 256) throw new InvalidOperationException("native_tsf_candidate_bound");
              TsfUiElementCount++;
              return action(candidate);
            } finally {
              if (observedObject != null) Marshal.ReleaseComObject(observedObject);
              Marshal.Release(observedPointer);
            }
          }
        }
        TsfCandidateResult = manager.EnumUIElements(out enumPointer);
        if (TsfCandidateResult < 0 || enumPointer == IntPtr.Zero) return empty;
        enumObject = Marshal.GetObjectForIUnknown(enumPointer);
        var enumerator = (UiElementEnumerator)enumObject;
        for (int iteration = 0; iteration < 32; iteration++) {
          IntPtr elementPointer;
          uint fetched;
          TsfCandidateResult = enumerator.Next(1, out elementPointer, out fetched);
          if (TsfCandidateResult < 0 || fetched == 0 || elementPointer == IntPtr.Zero) return empty;
          TsfUiElementCount++;
          object elementObject = null;
          try {
            elementObject = Marshal.GetObjectForIUnknown(elementPointer);
            var candidate = elementObject as CandidateElement;
            if (candidate == null) continue;
            uint count;
            TsfCandidateResult = candidate.GetCount(out count);
            if (TsfCandidateResult < 0 || count == 0) continue;
            if (count > 256) throw new InvalidOperationException("native_tsf_candidate_bound");
            return action(candidate);
          } finally {
            if (elementObject != null) Marshal.ReleaseComObject(elementObject);
            Marshal.Release(elementPointer);
          }
        }
        throw new InvalidOperationException("native_tsf_ui_element_bound");
      } finally {
        if (enumObject != null) Marshal.ReleaseComObject(enumObject);
        if (enumPointer != IntPtr.Zero) Marshal.Release(enumPointer);
        if (threadObject != null && threadPointer != IntPtr.Zero) Marshal.ReleaseComObject(threadObject);
        if (threadPointer != IntPtr.Zero) Marshal.Release(threadPointer);
      }
    });
  }
  public int CandidateCount {
    get {
      int count = WithTsfCandidate<int>(delegate(CandidateElement candidate) {
        uint value;
        if (candidate.GetCount(out value) < 0 || value > 256) throw new InvalidOperationException("native_tsf_candidate_count");
        return (int)value;
      }, 0);
      return count > 0 ? count : WithCandidates<int>(delegate(IntPtr data, uint size) { return Marshal.ReadInt32(data, 8); }, 0);
    }
  }
  public string CandidateAt(int index) {
    string modern = WithTsfCandidate<string>(delegate(CandidateElement candidate) {
      uint count;
      if (candidate.GetCount(out count) < 0 || index < 0 || index >= count) throw new InvalidOperationException("native_tsf_candidate_index");
      string value;
      if (candidate.GetString((uint)index, out value) < 0 || value == null || value.Length > 4096)
        throw new InvalidOperationException("native_tsf_candidate_text_bound");
      return value;
    }, null);
    if (modern != null) return modern;
    return WithCandidates<string>(delegate(IntPtr data, uint size) {
      int count = Marshal.ReadInt32(data, 8);
      if (index < 0 || index >= count) throw new InvalidOperationException("native_ime_candidate_index");
      uint offset = (uint)Marshal.ReadInt32(data, 24 + index * 4);
      if (offset < 24 + count * 4 || offset >= size || offset % 2 != 0)
        throw new InvalidOperationException("native_ime_candidate_offset");
      int length = 0;
      while (offset + (uint)(length + 1) * 2 <= size && Marshal.ReadInt16(data, (int)offset + length * 2) != 0) length++;
      if (offset + (uint)(length + 1) * 2 > size) throw new InvalidOperationException("native_ime_candidate_termination");
      return Marshal.PtrToStringUni(IntPtr.Add(data, (int)offset), length);
    }, null);
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
    if (form != null && thread.IsAlive) OnPeer<bool>(delegate {
      if (tsfSource != null && TsfSinkResult >= 0) tsfSource.UnadviseSink(sinkCookie);
      tsfSource = null;
      candidateObserver = null;
      if (tsfThread != null) { Marshal.ReleaseComObject(tsfThread); tsfThread = null; }
      form.Close(); return true;
    });
    if (!thread.Join(5000)) throw new InvalidOperationException("keyboard_peer_shutdown_timeout");
    disposed = true;
    ready.Dispose();
  }
}
