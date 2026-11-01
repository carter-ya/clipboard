param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$OutputDirectory,
      [string]$ClipboardPeer,
      [string]$OCRFixture,
      [switch]$Baseline,
      [switch]$ValidateOnly,
      [int]$LifecycleCycles = 0)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
# GTK has server-side AccessKit providers; native common-dialog controls use
# the managed client's Win32 proxies. Register from a compiled caller before
# traversing HWNDs: ProxyManager's default-loader stack walk is not reliable
# when the first caller is a generated PowerShell method.
# https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/UIAutomation/UIAutomationClient/MS/Internal/Automation/ProxyManager.cs
$automationClient = [Windows.Automation.AutomationElement].Assembly
$proxyName = $automationClient.GetName()
$proxyName.Name = 'UIAutomationClientsideProviders'
$standardProviders = [Reflection.Assembly]::Load($proxyName)
Add-Type -ReferencedAssemblies $automationClient.Location -TypeDefinition @'
using System.Reflection;
using System.Windows.Automation;
public static class ClipboardStandardProviders {
  public static void Register(AssemblyName assembly) {
    try {
      ClientSettings.RegisterClientSideProviderAssembly(assembly);
    } catch (System.NullReferenceException) {
      // .NET Framework marks its default-proxy attempt consumed before walking
      // reflection-generated PowerShell frames. That first walk can throw;
      // a single explicit retry registers the requested table without that walk.
      // Other failures, and any failure of the second call, remain hard errors.
      ClientSettings.RegisterClientSideProviderAssembly(assembly);
    }
  }
}
'@
[ClipboardStandardProviders]::Register($standardProviders.GetName())
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PreviewNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr parameter);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr parameter);
  [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr control);
  public static IntPtr[] DialogFields(IntPtr parent, bool filenameOnly) {
    var result = new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(parent, (control, _) => {
      var type = new System.Text.StringBuilder(128);
      GetClassName(control, type, type.Capacity);
      int id = GetDlgCtrlID(control);
      if ((type.ToString() == "Edit" || type.ToString() == "ComboBox" || type.ToString() == "ComboBoxEx32") &&
          (!filenameOnly || id == 1001 || id == 1148)) result.Add(control);
      return result.Count < 32;
    }, IntPtr.Zero);
    return result.ToArray();
  }
  public static IntPtr DialogButton(IntPtr parent, int id) {
    IntPtr result = IntPtr.Zero;
    EnumChildWindows(parent, (control, _) => {
      var type = new System.Text.StringBuilder(128);
      GetClassName(control, type, type.Capacity);
      if (GetDlgCtrlID(control) == id && type.ToString() == "Button") { result = control; return false; }
      return true;
    }, IntPtr.Zero);
    return result;
  }
  public static string DescribeDialogField(IntPtr control) {
    var type = new System.Text.StringBuilder(128);
    GetClassName(control, type, type.Capacity);
    return GetDlgCtrlID(control).ToString() + ":" + type.ToString();
  }
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder text, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder text, int max);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  public static IntPtr FindWindow(uint processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hwnd, _) => {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      if (owner == processId && IsWindowVisible(hwnd)) {
        var title = new System.Text.StringBuilder(256);
        var windowClass = new System.Text.StringBuilder(256);
        GetWindowText(hwnd, title, title.Capacity);
        GetClassName(hwnd, windowClass, windowClass.Capacity);
        // SwiftPM's console subsystem can create a visible console HWND first.
        // Only the actual GTK application window is an accessibility target.
        if (title.ToString() == "Clipboard" && windowClass.ToString() != "ConsoleWindowClass") {
          found = hwnd; return false;
        }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static IntPtr FindDialog(uint processId, string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hwnd, _) => {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      var text = new System.Text.StringBuilder(512);
      if (owner == processId && IsWindowVisible(hwnd) && GetWindowText(hwnd, text, text.Capacity) > 0 && text.ToString() == title) {
        found = hwnd; return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowEx(
    uint extended, string className, string title, uint style, int x, int y, int width, int height,
    IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
  [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr WindowProcedure(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct WindowClass {
    public uint Style; public IntPtr Procedure; public int ClassExtra, WindowExtra;
    public IntPtr Instance, Icon, Cursor, Background; public string MenuName, ClassName;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern ushort RegisterClass(ref WindowClass windowClass);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool UnregisterClass(string name, IntPtr instance);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
  private static readonly WindowProcedure focusProcedure = FocusWindowProcedure;
  private static IntPtr FocusWindowProcedure(IntPtr window, uint message, IntPtr wparam, IntPtr lparam) {
    if (message == 0x0002) { PostQuitMessage(0); return IntPtr.Zero; }
    return DefWindowProc(window, message, wparam, lparam);
  }
  [StructLayout(LayoutKind.Sequential)] private struct Message {
    public IntPtr Window; public uint Id; public UIntPtr WParam; public IntPtr LParam;
    public uint Time; public int X, Y; public uint Private;
  }
  [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] private static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
  [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
  [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref Message message);
  [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, UIntPtr wparam, IntPtr lparam);
  private static System.Threading.Thread focusThread;
  private static System.Threading.ManualResetEventSlim focusReady;
  private static uint focusThreadId;
  private static IntPtr focusWindow, focusControl;
  [StructLayout(LayoutKind.Sequential)] private struct MouseInput {
    public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra;
  }
  [StructLayout(LayoutKind.Sequential)] private struct PointerInput {
    public uint Type; public MouseInput Mouse;
  }
  [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
  [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")] private static extern uint SendInput(uint count, PointerInput[] inputs, int size);
  public static bool ClickFocusFixture() {
    // SetForegroundWindow may be refused by the OS foreground lock. In the
    // isolated runner, activate only our own visible control with a real mouse
    // click. Keep the strict foreground-window assertion in the caller.
    if (focusWindow == IntPtr.Zero || focusControl == IntPtr.Zero) return false;
    uint owner;
    GetWindowThreadProcessId(focusWindow, out owner);
    if (owner != (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return false;
    if (!SetWindowPos(focusWindow, new IntPtr(-1), 0, 0, 0, 0, 0x0053)) return false;
    try {
      Rect rect;
      if (!GetWindowRect(focusControl, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return false;
      var point = new Point { X = rect.Left + (rect.Right - rect.Left) / 2,
                              Y = rect.Top + (rect.Bottom - rect.Top) / 2 };
      if (WindowFromPoint(point) != focusControl || !SetCursorPos(point.X, point.Y)) return false;
      var inputs = new[] {
        new PointerInput { Mouse = new MouseInput { Flags = 0x0002 } },
        new PointerInput { Mouse = new MouseInput { Flags = 0x0004 } }
      };
      uint sent = SendInput(2, inputs, Marshal.SizeOf(typeof(PointerInput)));
      if (sent == 1) SendInput(1, new[] { inputs[1] }, Marshal.SizeOf(typeof(PointerInput)));
      return sent == 2;
    } finally {
      SetWindowPos(focusWindow, new IntPtr(-2), 0, 0, 0, 0, 0x0013);
    }
  }
  public static IntPtr CreateFocusFixture() {
    if (focusThread != null) return IntPtr.Zero;
    var ready = focusReady = new System.Threading.ManualResetEventSlim(false);
    // A native HWND on the busy PowerShell thread has no message pump and
    // cannot reliably participate in activation or UI Automation. Own this
    // private focusable window on a separate STA thread with a real loop.
    focusThread = new System.Threading.Thread(() => {
      focusThreadId = GetCurrentThreadId();
      const string className = "ClipboardPrivateFocusFixture";
      IntPtr instance = GetModuleHandle(null);
      var windowClass = new WindowClass { Procedure = Marshal.GetFunctionPointerForDelegate(focusProcedure),
        Instance = instance, Background = new IntPtr(6), ClassName = className };
      if (RegisterClass(ref windowClass) == 0) { ready.Set(); return; }
      focusWindow = CreateWindowEx(0, className, "Clipboard startup focus fixture", 0x12CF0000,
                                 10, 10, 220, 120, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
      if (focusWindow != IntPtr.Zero) {
        focusControl = CreateWindowEx(0x200, "EDIT", "Synthetic focus target", 0x50010000,
                                      10, 10, 180, 24, focusWindow, new IntPtr(1), instance, IntPtr.Zero);
      }
      ready.Set();
      try {
        if (focusWindow == IntPtr.Zero || focusControl == IntPtr.Zero) return;
        Message message;
        while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
          TranslateMessage(ref message);
          DispatchMessage(ref message);
        }
      } finally {
        if (focusWindow != IntPtr.Zero) DestroyWindow(focusWindow);
        UnregisterClass(className, instance);
      }
    });
    focusThread.IsBackground = true;
    focusThread.SetApartmentState(System.Threading.ApartmentState.STA);
    focusThread.Start();
    if (!ready.Wait(10000)) { CloseFocusFixture(); return IntPtr.Zero; }
    return focusControl == IntPtr.Zero ? IntPtr.Zero : focusWindow;
  }
  public static void CloseFocusFixture() {
    if (focusThread == null) return;
    if (focusThread.IsAlive) {
      PostThreadMessage(focusThreadId, 0x0012, UIntPtr.Zero, IntPtr.Zero);
      if (!focusThread.Join(5000)) return;
    }
    focusReady.Dispose(); focusReady = null;
    focusThread = null; focusWindow = IntPtr.Zero; focusControl = IntPtr.Zero; focusThreadId = 0;
  }
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
  [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint DragQueryFile(IntPtr drop, uint index, System.Text.StringBuilder path, uint length);
  public static bool HasPngClipboard() {
    if (!OpenClipboard(IntPtr.Zero)) return false;
    try { return GetClipboardData(RegisterClipboardFormat("PNG")) != IntPtr.Zero; }
    finally { CloseClipboard(); }
  }
  public static uint ClipboardFileCount() {
    if (!OpenClipboard(IntPtr.Zero)) return 0;
    try { return DragQueryFile(GetClipboardData(15), 0xffffffff, null, 0); }
    finally { CloseClipboard(); }
  }
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr handle);
  [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr handle);
  [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr handle);
  public static byte[] ReadRichClipboard(string format) {
    if (!OpenClipboard(IntPtr.Zero)) throw new Exception("clipboard_busy");
    try {
      IntPtr handle = GetClipboardData(RegisterClipboardFormat(format));
      ulong length = GlobalSize(handle).ToUInt64();
      if (length == 0 || length > 1024 * 1024) throw new Exception("fixture_format_size");
      IntPtr data = GlobalLock(handle);
      if (data == IntPtr.Zero) throw new Exception("clipboard_unavailable");
      try {
        byte[] bytes = new byte[(int)length];
        Marshal.Copy(data, bytes, 0, bytes.Length);
        return bytes;
      } finally { GlobalUnlock(handle); }
    } finally { CloseClipboard(); }
  }
  public static string ReadClipboard() {
    if (!OpenClipboard(IntPtr.Zero)) throw new Exception("clipboard_busy");
    try {
      IntPtr handle = GetClipboardData(13);
      IntPtr data = GlobalLock(handle);
      if (data == IntPtr.Zero) throw new Exception("clipboard_unavailable");
      try { return Marshal.PtrToStringUni(data); } finally { GlobalUnlock(handle); }
    } finally { CloseClipboard(); }
  }
}
'@
if ($ValidateOnly) { exit 0 }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$Executable = [IO.Path]::GetFullPath($Executable)
$checks = [Collections.Generic.List[object]]::new()
$application = $null
$window = $null
$nativeWindowHandle = [IntPtr]::Zero
$probeStarted = Get-Date
$sensitiveProbe = $false
$sensitiveStage = ""
$sensitiveInitialBounds = [PreviewNative+Rect]::new()

function Add-Check([string]$Name, [bool]$Passed) {
  if ($script:sensitiveProbe) { $script:sensitiveStage = $Name }
  $script:checks.Add(@{ name = $Name; passed = $Passed })
  if (!$Passed) { throw $Name }
}
function Wait-For([scriptblock]$Predicate, [string]$Name) {
  if ($script:sensitiveProbe) { $script:sensitiveStage = $Name }
  $deadline = [DateTime]::UtcNow.AddSeconds(40)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($script:application -and $script:application.HasExited) { throw ('application_exited_code_' + $script:application.ExitCode) }
    try { $value = & $Predicate; if ($value) { return $value } } catch { }
    Start-Sleep -Milliseconds 150
  }
  throw $Name
}
function Find-Named([string]$Name) {
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::NameProperty, $Name)
  return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Get-Editor {
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
  return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Get-EditorWithValue([string]$Value) {
  if ($script:sensitiveProbe) { throw 'public_editor_lookup_after_sensitive_phase' }
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
  foreach ($control in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
    try {
      if ($control.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -ceq $Value) { return $control }
    } catch {}
  }
  return $null
}
function Get-ImagePreview {
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Image)
  return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Read-SharedJson([string]$Path) {
  # Snapshot replacement needs delete sharing on Windows. Get-Content's live
  # read handle can otherwise make the application fail its own rename.
  $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
  try {
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
    finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
}
function Invoke-Button([string]$Label) {
  $element = Wait-For {
    $candidate = Find-Named $Label
    # A composed label can name its Text child. Resolve the live button again
    # while waiting for an asynchronous transition to enable the control.
    for ($depth = 0; $depth -lt 10 -and $candidate; $depth++) {
      if ($candidate.Current.ControlType -eq [Windows.Automation.ControlType]::Button) { break }
      $candidate = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($candidate)
    }
    if ($candidate -and $candidate.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $candidate.Current.IsEnabled) { return $candidate }
  } ('enabled_button_' + $Label)
  $pattern = $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
  $pattern.Invoke()
}
function Get-ArchiveFilenamePattern($Element) {
  try {
    $pattern = $Element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    if (!$pattern.Current.IsReadOnly) { return $pattern }
  } catch {}
  return $null
}
function Complete-ArchiveDialog([string]$Title, [string]$Path, [bool]$CheckDefault = $false) {
  $handle = Wait-For {
    $candidate = [PreviewNative]::FindDialog([uint32]$application.Id, $Title)
    if ($candidate -ne [IntPtr]::Zero) { $candidate }
  } 'archive_native_dialog'
  $dialog = [Windows.Automation.AutomationElement]::FromHandle($handle)
  # Windows common dialogs may expose the filename as an editable ComboBox
  # rather than an Edit node. Anchor only to known filename host/control IDs,
  # then require a writable native accessibility value; never pick the address/search editor.
  $value = $null
  try {
    $value = Wait-For {
    # Native child handles also cover controls omitted from the dialog's
    # provider fragment. Accessibility remains mandatory; no text messages/keys.
    foreach ($native in [PreviewNative]::DialogFields($handle, $true)) {
      try {
        $candidate = [Windows.Automation.AutomationElement]::FromHandle($native)
        $pattern = Get-ArchiveFilenamePattern $candidate
        if ($pattern) { return $pattern }
      } catch {}
    }
    foreach ($id in @('1001', '1148', 'FileNameControlHost')) {
      $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
      foreach ($hostControl in $dialog.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
        $controls = @($hostControl)
        if ($id -eq 'FileNameControlHost') {
          $editable = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
          $controls += @($hostControl.FindAll([Windows.Automation.TreeScope]::Descendants, $editable))
        }
        foreach ($control in $controls) {
          if (!$control.Current.IsEnabled) { continue }
          $pattern = Get-ArchiveFilenamePattern $control
          if ($pattern) { return $pattern }
        }
      }
    }
    } 'archive_filename_editor'
  } catch {
    # Bounded native IDs/classes and capability booleans only. Never record
    # names, paths, editor values, clipboard content or exception text.
    $metadata = @()
    foreach ($native in [PreviewNative]::DialogFields($handle, $false)) {
      $supportsValue = $false
      try {
        $element = [Windows.Automation.AutomationElement]::FromHandle($native)
        $supportsValue = [bool]$element.GetCurrentPropertyValue([Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty)
      } catch {}
      $metadata += @{ control = [PreviewNative]::DescribeDialogField($native); valuePattern = $supportsValue }
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'archive-native-controls.json'), (ConvertTo-Json -InputObject $metadata), [Text.UTF8Encoding]::new($false))
    throw 'archive_filename_editor'
  }
  if ($CheckDefault) {
    $defaultName = $value.Current.Value
    # Classify only this fixed synthetic default. Never emit a field value.
    $defaultMetadata = @{
      literalZIP = $defaultName -ceq 'clipboard-history.zip'
      extensionHidden = $defaultName -ceq 'clipboard-history'
      quotedZIP = $defaultName -ceq '"clipboard-history.zip"'
      empty = [string]::IsNullOrEmpty($defaultName)
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'archive-default-name.json'), ($defaultMetadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    if (!$defaultMetadata.literalZIP -and !$defaultMetadata.extensionHidden) { throw 'archive_unexpected_default_name' }
    $expected = [IO.Path]::GetFullPath((Join-Path $historyRoot 'clipboard-history.zip'))
    if ([IO.Path]::GetFullPath($Path) -cne $expected -or (Test-Path -LiteralPath $Path)) { throw 'archive_default_fixture_not_empty_or_private' }
  } else {
    $value.SetValue($Path)
  }
  $acceptCondition = [Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button),
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, '1'))
  $accept = Wait-For {
    $native = [PreviewNative]::DialogButton($handle, 1)
    $button = if ($native -ne [IntPtr]::Zero) { [Windows.Automation.AutomationElement]::FromHandle($native) }
              else { $dialog.FindFirst([Windows.Automation.TreeScope]::Descendants, $acceptCondition) }
    if (!$button) { return $null }
    try {
      if ($button.Current.IsEnabled) {
        return $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
      }
    } catch {}
    return $null
  } 'archive_dialog_accept'
  $accept.Invoke()
  if ($CheckDefault) {
    # The shell may hide a known extension in its edit control. Leave the
    # filename untouched and require the real default save to create this ZIP.
    Wait-For { Test-Path -LiteralPath $Path -PathType Leaf } 'native_default_zip_export_created' | Out-Null
    Add-Check 'native_archive_save_dialog_defaults_to_zip' $true
  }
}
function Set-Search([string]$Text) {
  $element = Wait-For { Get-Editor } 'search_control'
  $pattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
  $pattern.SetValue($Text)
}
function Wake-Existing {
  $peer = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
    -ArgumentList @('--data-root', ('"' + $historyRoot + '"')) -PassThru
  if (!$peer.WaitForExit(15000)) { $peer.Kill(); throw 'secondary_launch_timeout' }
  Add-Check 'secondary_launch_exits_without_new_store_owner' ($peer.ExitCode -eq 0 -and !$application.HasExited)
  $script:nativeWindowHandle = Wait-For {
    $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
    if ($handle -ne [IntPtr]::Zero) { $handle }
  } 'existing_window_reopened'
  $script:window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
  Wait-For { Get-Editor } 'reopened_search_control' | Out-Null
}
function Save-Screenshot([string]$Name) {
  $rect = New-Object PreviewNative+Rect
  $handle = $script:nativeWindowHandle
  if (![PreviewNative]::GetWindowRect($handle, [ref]$rect)) { throw 'window_bounds' }
  $bitmap = New-Object Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $OutputDirectory $Name), [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
  $historyRoot = Join-Path $OutputDirectory ('history-' + [Guid]::NewGuid().ToString('N'))
  $primaryHistoryRoot = $historyRoot
  $launchArguments = @('--smoke-root', ('"' + $historyRoot + '"'))
  if ($Baseline) { $launchArguments += '--ui-baseline' }
  $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
    -ArgumentList $launchArguments -PassThru `
    -RedirectStandardOutput (Join-Path $OutputDirectory 'application.stdout.log') `
    -RedirectStandardError (Join-Path $OutputDirectory 'application.stderr.log')
  # Retain the process handle so ExitCode remains available after an early crash.
  $null = $application.Handle
  $nativeWindowHandle = Wait-For {
    $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
    if ($handle -ne [IntPtr]::Zero) { $handle }
  } 'native_window_without_automation'
  # The hosted desktop is 1024x768; cascading default placement clips the window.
  # Move only this probe's own window, keeping its original dimensions.
  if (![PreviewNative]::SetWindowPos($nativeWindowHandle, [IntPtr]::Zero, 16, 16, 0, 0, 0x0005)) { throw 'position_probe_window' }
  [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
  Start-Sleep -Seconds 2
  Add-Check 'native_window_survives_without_ui_automation' (!$application.HasExited)
  Save-Screenshot 'startup-without-uia.png'
  # Start accessibility traversal only after retaining ordinary-window evidence.
  $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
  if ($Baseline) {
    Wait-For { Find-Named 'SwiftCrossUI baseline' } 'baseline_window' | Out-Null
    Add-Check 'baseline_window_visible' $true
    Invoke-Button 'Increment'
    Wait-For { Find-Named 'Counter: 1' } 'baseline_state_update' | Out-Null
    Add-Check 'baseline_button_updates_state' $true
    Save-Screenshot 'baseline.png'
  } else {
    Wait-For { (Find-Named 'Ready') -and (Find-Named '3 items') } 'initial_history' | Out-Null
    Add-Check 'native_window_and_history_visible' $true
    Save-Screenshot 'history.png'
    $edit = Wait-For { Get-Editor } 'search_control'
    $edit.SetFocus()
    Wait-For { (Get-Editor).Current.HasKeyboardFocus } 'programmatic_search_focus' | Out-Null
    Add-Check 'native_search_control_focus' $true
    Invoke-Button 'Copy'
    Wait-For { Find-Named 'Copied to clipboard' } 'copy_status' | Out-Null
    Add-Check 'copy_button_writes_native_clipboard' ([PreviewNative]::ReadClipboard() -eq 'Release checklist · build, test, publish')
    Set-Search 'Welcome'
    Wait-For { (Find-Named '1 items') -and (Find-Named 'Welcome to Clipboard Preview') } 'older_item_selected' | Out-Null
    $PreviousCopyRevision = [PreviewNative]::GetClipboardSequenceNumber()
    Invoke-Button 'Copy'
    Wait-For {
      $promotedHistory = Read-SharedJson (Join-Path $historyRoot 'history.json')
      ([PreviewNative]::GetClipboardSequenceNumber() -ne $PreviousCopyRevision) -and
        ($promotedHistory.items[0].preview -eq 'Welcome to Clipboard Preview')
    } 'copied_item_promoted_while_capture_paused' | Out-Null
    Add-Check 'copy_promotes_older_item_with_capture_paused' ([PreviewNative]::ReadClipboard() -eq 'Welcome to Clipboard Preview')
    Set-Search '中文'
    Wait-For { (Find-Named '1 items') -and (Find-Named '中文笔记 · 设计评审与输入测试') } 'unicode_search_results' | Out-Null
    Add-Check 'native_unicode_search_updates_list' $true
    Save-Screenshot 'unicode-search.png'
    Invoke-Button 'Pin / unpin'
    Wait-For { Find-Named 'Item pinned' } 'pin_status' | Out-Null
    Invoke-Button 'Pinned'
    Wait-For { Find-Named '1 items' } 'pinned_filter' | Out-Null
    Add-Check 'pin_and_pinned_filter' $true
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'settings_view' | Out-Null
    Save-Screenshot 'settings.png'
    Invoke-Button 'Back to history'
    Wait-For { (Find-Named '1 items') -and (Get-Editor) } 'history_restored' | Out-Null
    Wait-For { (Get-Editor).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -eq '中文' } 'restored_search_value' | Out-Null
    Add-Check 'settings_round_trip_preserves_search' $true
    Wait-For { (Get-Editor).Current.HasKeyboardFocus } 'settings_return_focus' | Out-Null
    Add-Check 'settings_return_focuses_native_search' $true
    Invoke-Button 'Hide'
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'window_hidden' | Out-Null
    Wake-Existing
    $value = (Get-Editor).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    Wait-For { (Get-Editor).Current.HasKeyboardFocus } 'wake_search_focus' | Out-Null
    Add-Check 'hide_and_secondary_launch_preserve_search_and_focus' ($value -eq '中文')
    if (![PreviewNative]::PostMessage($nativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'native_close_request' }
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'close_hides_window' | Out-Null
    Add-Check 'native_close_keeps_existing_process_alive' (!$application.HasExited)
    Wake-Existing
    $value = (Get-Editor).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    Add-Check 'native_close_reopen_preserves_query' ($value -eq '中文')
    if ($LifecycleCycles -gt 0) {
      if ($LifecycleCycles -lt 5 -or $LifecycleCycles -gt 100) { throw 'lifecycle_cycles_out_of_range' }
      $ResourceBaseline = $null
      for ($Cycle = 0; $Cycle -lt $LifecycleCycles + 5; $Cycle++) {
        Invoke-Button 'Hide'
        Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'cycle_window_hidden' | Out-Null
        Wake-Existing
        Wait-For { (Get-Editor).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -eq '中文' } 'cycle_search_value' | Out-Null
        Wait-For { (Get-Editor).Current.HasKeyboardFocus } 'cycle_search_focus' | Out-Null
        if ($Cycle -eq 4) {
          $application.Refresh()
          $ResourceBaseline = @{ privateBytes=$application.PrivateMemorySize64; handles=$application.HandleCount }
        }
      }
      $application.Refresh()
      $ResourceFinal = @{ privateBytes=$application.PrivateMemorySize64; handles=$application.HandleCount }
      @{ cycles=$LifecycleCycles; baseline=$ResourceBaseline; final=$ResourceFinal } |
        ConvertTo-Json -Depth 4 | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'lifecycle-resources.json')
      Add-Check 'repeated_hide_reopen_preserves_query_and_focus' $true
      Add-Check 'repeated_window_lifecycle_keeps_handles_bounded' ($ResourceFinal.handles -le $ResourceBaseline.handles + 8)
      Add-Check 'repeated_window_lifecycle_keeps_memory_bounded' ($ResourceFinal.privateBytes -le $ResourceBaseline.privateBytes + 33554432)
    }
    Invoke-Button 'Delete'
    Wait-For { (Find-Named 'Item deleted') -and (Find-Named '0 items') } 'delete_updates_list' | Out-Null
    Add-Check 'delete_updates_real_store' $true
    Invoke-Button 'All'
    Set-Search ''
    Wait-For { Find-Named '2 items' } 'remaining_history' | Out-Null
    $history = Read-SharedJson (Join-Path $historyRoot 'history.json')
    Add-Check 'store_persistence_matches_ui' ($history.items.Count -eq 2)
    if ($ClipboardPeer) {
      foreach ($fixture in @('rich', 'files')) {
        Invoke-Button 'Start recording'
        Wait-For { Find-Named 'Recording clipboard' } 'rich_recording_enabled' | Out-Null
        $peerInfo = New-Object Diagnostics.ProcessStartInfo
        $peerInfo.FileName = [IO.Path]::GetFullPath($ClipboardPeer)
        $peerInfo.Arguments = 'rich-clipboard-peer ' + $fixture
        $peerInfo.UseShellExecute = $false
        $peerInfo.RedirectStandardInput = $true
        $peerInfo.RedirectStandardOutput = $true
        $peer = [Diagnostics.Process]::Start($peerInfo)
        try {
          $line = $peer.StandardOutput.ReadLineAsync()
          if (!$line.Wait(10000) -or $line.Result -ne 'ready') { throw 'rich_peer_startup' }
          $kind = if ($fixture -eq 'rich') { 'Image' } else { 'File' }
          Invoke-Button $kind
          Wait-For {
            if (!(Find-Named '1 items')) { return $false }
            if ($fixture -eq 'files') { return Find-Named 'fixture 中文.txt' }
            $imageCondition = [Windows.Automation.PropertyCondition]::new(
              [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Image)
            return $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $imageCondition)
          } ('capture_native_' + $fixture) | Out-Null
          Add-Check ('native_' + $fixture + '_capture_reaches_type_filter_and_preview') $true
          # Establish a distinct status before Copy. A previous 'Copied' label
          # cannot acknowledge a new asynchronous invocation. Pause after native
          # capture also proves this control works for each rich fixture.
          Invoke-Button 'Pause recording'
          Wait-For { (Find-Named 'Recording paused') -and (Find-Named 'Start recording') } 'rich_recording_paused' | Out-Null
          Add-Check ('recording_can_pause_after_native_' + $fixture + '_capture') $true
          $CopyRevision = [PreviewNative]::GetClipboardSequenceNumber()
          if ($fixture -eq 'rich') {
            $imageCondition = [Windows.Automation.PropertyCondition]::new(
              [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Image)
            Wait-For { $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $imageCondition) } 'native_image_preview' | Out-Null
            Add-Check 'image_preview_has_native_picture' $true
            Save-Screenshot 'image-preview.png'
            Invoke-Button 'Copy'
            Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $CopyRevision } 'copy_image_status' | Out-Null
            Add-Check 'image_copy_keeps_original_native_png' ([PreviewNative]::HasPngClipboard())
          } else {
            Invoke-Button 'Copy'
            Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $CopyRevision } 'copy_files_status' | Out-Null
            Add-Check 'file_copy_keeps_both_native_paths' ([PreviewNative]::ClipboardFileCount() -eq 2)
          }
        } finally {
          $peer.StandardInput.Close()
          if (!$peer.WaitForExit(5000)) { $peer.Kill(); $peer.WaitForExit() }
          $peer.Dispose()
        }
      }
      Invoke-Button 'Text'
      Set-Search 'Long preview fixture'
      Invoke-Button 'Start recording'
      Wait-For { Find-Named 'Recording clipboard' } 'long_preview_recording' | Out-Null
      $peerInfo = New-Object Diagnostics.ProcessStartInfo
      $peerInfo.FileName = [IO.Path]::GetFullPath($ClipboardPeer)
      $peerInfo.Arguments = 'rich-clipboard-peer preview-long'
      $peerInfo.UseShellExecute = $false
      $peerInfo.RedirectStandardInput = $true
      $peerInfo.RedirectStandardOutput = $true
      $peer = [Diagnostics.Process]::Start($peerInfo)
      try {
        $line = $peer.StandardOutput.ReadLineAsync()
        if (!$line.Wait(10000) -or $line.Result -ne 'ready') { throw 'long_preview_peer_startup' }
        Wait-For { (Find-Named '1 items') -and (Find-Named 'Preview truncated. Copy keeps the full text.') } 'long_preview_truncation_notice' | Out-Null
        Add-Check 'long_text_preview_reports_truncation' $true
        Save-Screenshot 'long-text-preview.png'
        Invoke-Button 'Pause recording'
        Wait-For { Find-Named 'Recording paused' } 'long_preview_pause_before_copy' | Out-Null
        $CopyRevision = [PreviewNative]::GetClipboardSequenceNumber()
        Invoke-Button 'Copy'
        Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $CopyRevision } 'long_preview_copied' | Out-Null
        $expected = ("Long preview fixture 中文😀`r`n" * 4096) + 'end-of-full-preview-fixture'
        Add-Check 'truncated_preview_copy_keeps_full_unicode_payload' ([PreviewNative]::ReadClipboard() -ceq $expected)
      } finally {
        $peer.StandardInput.Close()
        if (!$peer.WaitForExit(5000)) { $peer.Kill(); $peer.WaitForExit() }
        $peer.Dispose()
      }
      Invoke-Button 'Delete'
      Wait-For { Find-Named '0 items' } 'long_preview_fixture_removed' | Out-Null
      Set-Search ''
      if ($OCRFixture) {
        Invoke-Button 'Image'
        Wait-For { (Find-Named '1 items') -and (Get-ImagePreview) } 'image_for_ocr_replacement' | Out-Null
        Invoke-Button 'Delete'
        Wait-For { Find-Named '0 items' } 'previous_image_removed' | Out-Null
        Invoke-Button 'Start recording'
        Wait-For { Find-Named 'Recording clipboard' } 'ocr_capture_enabled' | Out-Null
        $peerInfo = New-Object Diagnostics.ProcessStartInfo
        $peerInfo.FileName = [IO.Path]::GetFullPath($ClipboardPeer)
        $peerInfo.Arguments = 'rich-clipboard-peer ocr "' + [IO.Path]::GetFullPath($OCRFixture) + '"'
        $peerInfo.UseShellExecute = $false
        $peerInfo.RedirectStandardInput = $true
        $peerInfo.RedirectStandardOutput = $true
        $peer = [Diagnostics.Process]::Start($peerInfo)
        try {
          $line = $peer.StandardOutput.ReadLineAsync()
          if (!$line.Wait(10000) -or $line.Result -ne 'ready') { throw 'ocr_peer_startup' }
          Wait-For { (Find-Named '1 items') -and (Get-ImagePreview) -and (Find-Named 'Recognize text') } 'ocr_image_captured' | Out-Null
          Invoke-Button 'Recognize text'
          Wait-For { (Find-Named 'OCR text ready') -and (Find-Named 'OCR / AI result') } 'ocr_result_visible' | Out-Null
          Add-Check 'native_ocr_result_reaches_real_preview' $true
          Invoke-Button 'Pause recording'
          Wait-For { Find-Named 'Recording paused' } 'pause_before_copying_ocr' | Out-Null
          Invoke-Button 'Copy result'
          Wait-For { Find-Named 'Copied to clipboard' } 'ocr_result_copy_status' | Out-Null
          $ocrText = [PreviewNative]::ReadClipboard()
          Add-Check 'ocr_result_can_be_copied_without_replacing_original_item' ($ocrText.ToUpperInvariant().Contains('CLIPBOARD') -and $ocrText.Contains('123'))
        } finally {
          $peer.StandardInput.Close()
          if (!$peer.WaitForExit(5000)) { $peer.Kill(); $peer.WaitForExit() }
          $peer.Dispose()
        }
      }
      Invoke-Button 'All types'
      Wait-For { Find-Named '4 items' } 'all_content_restored' | Out-Null
    }
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'preferences_for_save' | Out-Null
    Invoke-Button 'Dark'
    Wait-For { Find-Named 'Appearance saved' } 'dark_appearance_saved' | Out-Null
    Start-Sleep -Milliseconds 200
    Save-Screenshot 'settings-dark.png'
    $probeBitmap = [Drawing.Bitmap]::new((Join-Path $OutputDirectory 'settings-dark.png'))
    try {
      $total = 0.0; $samples = 0
      for ($y = 0; $y -lt $probeBitmap.Height; $y += 16) {
        for ($x = 0; $x -lt $probeBitmap.Width; $x += 16) {
          $pixel = $probeBitmap.GetPixel($x, $y)
          $total += ($pixel.R + $pixel.G + $pixel.B) / 765.0; $samples++
        }
      }
      Add-Check 'native_dark_appearance_changes_rendered_window' ($total / $samples -lt 0.6)
    } finally { $probeBitmap.Dispose() }
    Invoke-Button 'Light'
    Wait-For { Find-Named 'Appearance saved' } 'light_appearance_saved' | Out-Null
    Invoke-Button '简体中文'
    Wait-For { (Find-Named '偏好设置') -and (Find-Named '语言已保存') } 'localized_settings' | Out-Null
    Add-Check 'language_switch_updates_native_controls' ($null -ne (Find-Named '返回历史'))
    Save-Screenshot 'settings-chinese.png'
    Invoke-Button '返回历史'
    Wait-For { (Get-Editor) -and (Find-Named '设置') } 'localized_history' | Out-Null
    Wait-For { (Get-Editor).Current.HasKeyboardFocus } 'localized_history_focus' | Out-Null
    Add-Check 'language_change_preserves_history_focus' $true
    Invoke-Button '设置'
    Wait-For { Find-Named '偏好设置' } 'localized_settings_return' | Out-Null
    Invoke-Button 'English'
    Wait-For { (Find-Named 'Preferences') -and (Find-Named 'Language saved') } 'english_restored' | Out-Null
    function Find-PublicEndpointEditor([string]$Value) {
      $editCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
      foreach ($candidate in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition)) {
        if ($candidate.Current.IsPassword) { continue }
        try {
          $pattern = $candidate.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
          if ($pattern.Current.Value -ceq $Value) { return $candidate }
        } catch { }
      }
    }
    $draftValue = 'https://fixture.invalid/localized-draft'
    $draftEditor = Wait-For { Find-PublicEndpointEditor 'https://api.openai.com/v1' } 'public_endpoint_editor'
    $draftID = ($draftEditor.GetRuntimeId() -join ',')
    $draftEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($draftValue)
    $languageCases = @(
      @{ tag = 'zh-Hant'; label = '繁體中文'; preferences = '偏好設定'; saved = '語言已保存'; behavior = '保存行為設定'; ocr = '本地 OCR 使用已安裝的語言包，此平台不提供 Apple 專屬模型。'; ai = '遠端 AI 預設關閉。啓用後，符合條件的內容會發送到指定服務。' },
      @{ tag = 'ja'; label = '日本語'; preferences = '環境設定'; saved = '言語を保存しました'; behavior = '動作設定を保存'; ocr = 'ローカル OCR はインストール済みのシステム言語パックを使用します。Apple 専用モデルは利用できません。'; ai = 'リモート AI は初期状態で無効です。有効にすると、対象の内容が指定した接続先に送信されます。' },
      @{ tag = 'ko'; label = '한국어'; preferences = '환경설정'; saved = '언어를 저장했습니다'; behavior = '동작 설정 저장'; ocr = '로컬 OCR은 설치된 시스템 언어 팩을 사용합니다. Apple 전용 모델은 사용할 수 없습니다.'; ai = '원격 AI는 기본적으로 꺼져 있습니다. 켜면 조건에 맞는 콘텐츠가 지정한 엔드포인트로 전송됩니다.' },
      @{ tag = 'de'; label = 'Deutsch'; preferences = 'Einstellungen'; saved = 'Sprache gespeichert'; behavior = 'Verhalten speichern'; ocr = 'Lokale OCR nutzt installierte Systemsprachpakete. Apple-exklusive Modelle sind hier nicht verfügbar.'; ai = 'Remote-KI ist standardmäßig deaktiviert. Bei Aktivierung werden geeignete Inhalte an deinen gewählten Endpunkt gesendet.' },
      @{ tag = 'es'; label = 'Español'; preferences = 'Preferencias'; saved = 'Idioma guardado'; behavior = 'Guardar comportamiento'; ocr = 'El OCR local usa los paquetes de idioma del sistema instalados. Los modelos exclusivos de Apple no están disponibles aquí.'; ai = 'La IA remota está desactivada por defecto. Al activarla, el contenido permitido se envía al destino elegido.' })
    foreach ($case in $languageCases) {
      Invoke-Button $case.label
      Wait-For { (Find-Named $case.preferences) -and (Find-Named $case.saved) -and (Find-Named $case.behavior) } ('localized_controls_' + $case.tag) | Out-Null
      Add-Check ('language_' + $case.tag + '_updates_controls_and_privacy_notes') ((Find-Named $case.ocr) -and (Find-Named $case.ai))
      $currentEditor = Find-PublicEndpointEditor $draftValue
      Add-Check ('language_' + $case.tag + '_preserves_editor_draft') ($currentEditor -and ($currentEditor.GetRuntimeId() -join ',') -eq $draftID)
      Save-Screenshot ('settings-' + $case.tag + '.png')
    }
    Invoke-Button 'English'
    Wait-For { (Find-Named 'Preferences') -and (Find-Named 'Language saved') } 'english_after_all_languages' | Out-Null
    Invoke-Button 'Save behavior'
    $settingsFile = Join-Path $historyRoot 'desktop-settings.json'
    Wait-For { Test-Path $settingsFile } 'saved_settings_file' | Out-Null
    $saved = Read-SharedJson $settingsFile
    Add-Check 'behavior_saved_without_enabling_recording' (!$saved.recordingEnabled -and $saved.closeToTray)
    Add-Check 'language_switches_keep_remote_AI_disabled_and_endpoint_draft_unsaved' (!$saved.ai.enabled -and $saved.ai.endpoint -ceq 'https://api.openai.com/v1' -and $saved.languageOverride -ceq 'en')
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'explicit_quit_timeout' }
    Add-Check 'explicit_quit_flushes_and_exits' ($application.ExitCode -eq 0)
    $historyRoot = Join-Path $OutputDirectory ('production-empty-' + [Guid]::NewGuid().ToString('N'))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--data-root', ('"' + $historyRoot + '"')) -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'production.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'production.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'fresh_production_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named '0 items') } 'fresh_production_history' | Out-Null
    Add-Check 'normal_launch_has_no_sample_history_and_starts_paused' ($null -ne (Find-Named 'Start recording'))
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'fresh_settings' | Out-Null
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'normal_quit_timeout' }
    Add-Check 'normal_launch_quits_cleanly' ($application.ExitCode -eq 0)
    $historyRoot = Join-Path $OutputDirectory ('background-' + [Guid]::NewGuid().ToString('N'))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--data-root', ('"' + $historyRoot + '"'), '--background') -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'background.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'background.stderr.log')
    $null = $application.Handle
    Wait-For { Test-Path (Join-Path $historyRoot 'blobs') } 'background_profile_claimed' | Out-Null
    Wait-For { [PreviewNative]::FindWindow([uint32]$application.Id) -eq [IntPtr]::Zero } 'background_launch_stays_hidden' | Out-Null
    Add-Check 'startup_background_argument_keeps_window_hidden' (!$application.HasExited)
    Wake-Existing
    Wait-For { (Find-Named 'Ready') -and (Find-Named '0 items') } 'background_launch_reopened' | Out-Null
    Add-Check 'startup_background_instance_can_be_reopened' $true
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'background_settings' | Out-Null
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'background_quit_timeout' }
    $historyRoot = Join-Path $OutputDirectory ('history-counts-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $historyRoot | Out-Null
    $snapshot = Read-SharedJson (Join-Path $primaryHistoryRoot 'history.json')
    Copy-Item -Path (Join-Path $primaryHistoryRoot 'blobs') -Destination (Join-Path $historyRoot 'blobs') -Recurse
    $mixedBytes = [Text.Encoding]::UTF8.GetBytes('Legacy mixed fixture')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $mixedHash = [BitConverter]::ToString($sha.ComputeHash($mixedBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $mixed = @{ id = [Guid]::NewGuid().ToString(); createdAt = $snapshot.items[0].createdAt;
      kind = 'mixed'; preview = 'Legacy mixed fixture'; pinned = $false; sensitive = $false;
      sha256 = $mixedHash; sizeBytes = $mixedBytes.Length;
      payloads = @(@{ pasteboardType = 'public.utf8-plain-text'; inlineData = [Convert]::ToBase64String($mixedBytes) }) }
    $snapshot.items = @($mixed) + @($snapshot.items)
    $expectedAll = $snapshot.items.Count
    [IO.File]::WriteAllText((Join-Path $historyRoot 'history.json'), ($snapshot | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--data-root', ('"' + $historyRoot + '"')) -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'counts.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'counts.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'counted_history_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named ($expectedAll.ToString() + ' items')) -and (Find-Named 'Mixed') } 'counted_history_ready' | Out-Null
    Add-Check 'query_wide_tab_and_type_counts_are_visible' ((Find-Named ('(' + $expectedAll + ')')) -and (Find-Named '(2)'))
    Save-Screenshot 'history-counts.png'
    Invoke-Button 'Mixed'
    Wait-For { (Find-Named '1 items') -and (Find-Named 'Legacy mixed fixture') } 'legacy_mixed_filter' | Out-Null
    Add-Check 'legacy_mixed_kind_can_be_filtered' ($null -ne (Find-Named ('(' + $expectedAll + ')')))
    Invoke-Button 'Pin / unpin'
    Wait-For { Find-Named 'Item pinned' } 'pin_legacy_mixed' | Out-Null
    Invoke-Button 'Pinned'
    Wait-For { (Find-Named '1 items') -and !(Find-Named '(2)') } 'pinned_kind_counts' | Out-Null
    Invoke-Button 'Text'
    Wait-For { Find-Named '0 items' } 'empty_pinned_kind' | Out-Null
    Add-Check 'kind_counts_follow_pinned_tab_without_collapsing_library_total' ((Find-Named ('(' + $expectedAll + ')')) -and (Find-Named '(1)') -and !(Find-Named '(2)'))
    Invoke-Button 'All'
    Wait-For { (Find-Named '2 items') -and (Find-Named '(2)') } 'all_tab_restores_text_count' | Out-Null
    Set-Search 'Legacy mixed fixture'
    Wait-For { (Find-Named '0 items') -and !(Find-Named ('(' + $expectedAll + ')')) } 'query_updates_cross_kind_counts' | Out-Null
    Invoke-Button 'Mixed'
    Wait-For { (Find-Named '1 items') -and (Find-Named 'Legacy mixed fixture') } 'matched_mixed_kind' | Out-Null
    Add-Check 'tab_and_type_counts_follow_the_active_query' ((Find-Named '(1)') -and !(Find-Named ('(' + $expectedAll + ')')))
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'counted_history_quit_settings' | Out-Null
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'counted_history_quit_timeout' }
    Add-Check 'counted_history_quits_cleanly' ($application.ExitCode -eq 0)

    $historyRoot = Join-Path $OutputDirectory ('rich-preview-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $historyRoot 'blobs') -Force | Out-Null
    $snapshot = Read-SharedJson (Join-Path $primaryHistoryRoot 'history.json')
    $createdAt = $snapshot.items[0].createdAt
    $fixtures = @(
      @{ name = 'HTML budget fixture'; kind = 'public.html'; body = '<p>' + ('中😀' * 12000) + ' HTML_COPY_TAIL</p>'; format = 'HTML Format' },
      @{ name = 'RTF budget fixture'; kind = 'public.rtf'; body = '{\rtf1 ' + ('x' * 70000) + ' RTF_COPY_TAIL}'; format = 'Rich Text Format' })
    $snapshot.items = @($fixtures | ForEach-Object {
      $bytes = [Text.Encoding]::UTF8.GetBytes($_.body)
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
      finally { $sha.Dispose() }
      @{ id = [Guid]::NewGuid().ToString(); createdAt = $createdAt; kind = 'rtf'; preview = $_.name;
         pinned = $false; sensitive = $false; sha256 = $hash; sizeBytes = $bytes.Length;
         payloads = @(@{ pasteboardType = $_.kind; inlineData = [Convert]::ToBase64String($bytes) }) }
    })
    [IO.File]::WriteAllText((Join-Path $historyRoot 'history.json'), ($snapshot | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--data-root', ('"' + $historyRoot + '"')) -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'rich-budget.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'rich-budget.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'rich_budget_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named '2 items') } 'rich_budget_profile' | Out-Null
    foreach ($fixture in $fixtures) {
      Set-Search $fixture.name
      Wait-For { (Find-Named '1 items') -and (Find-Named $fixture.name) -and (Find-Named 'Preview truncated. Copy keeps the full text.') } 'rich_budget_notice' | Out-Null
      Add-Check ('rich_' + $fixture.kind + '_reports_truncation') (!(Find-Named 'HTML_COPY_TAIL') -and !(Find-Named 'RTF_COPY_TAIL'))
      $copyRevision = [PreviewNative]::GetClipboardSequenceNumber()
      Invoke-Button 'Copy'
      Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $copyRevision } 'rich_budget_copied' | Out-Null
      $native = [Text.Encoding]::UTF8.GetString([PreviewNative]::ReadRichClipboard($fixture.format)).TrimEnd([char]0)
      if ($fixture.kind -eq 'public.html') {
        $start = [int]([regex]::Match($native, 'StartFragment:(\d+)').Groups[1].Value)
        $end = [int]([regex]::Match($native, 'EndFragment:(\d+)').Groups[1].Value)
        $nativeBytes = [Text.Encoding]::UTF8.GetBytes($native)
        if ($start -lt 0 -or $end -le $start -or $end -gt $nativeBytes.Length) { throw 'fixture_html_offsets' }
        $native = [Text.Encoding]::UTF8.GetString($nativeBytes, $start, $end - $start)
      }
      Add-Check ('rich_' + $fixture.kind + '_copy_preserves_complete_payload') ($native -ceq $fixture.body)
    }
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'rich_budget_quit_settings' | Out-Null
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'rich_budget_quit_timeout' }
    Add-Check 'rich_budget_profile_quits_cleanly' ($application.ExitCode -eq 0)

    $historyRoot = Join-Path $OutputDirectory ('archive-state-' + [Guid]::NewGuid().ToString('N'))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--smoke-root', ('"' + $historyRoot + '"')) -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'archive.stdout.log') -RedirectStandardError (Join-Path $OutputDirectory 'archive.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'archive_private_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named '3 items') } 'archive_private_profile' | Out-Null
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'archive_preferences' | Out-Null
    Invoke-Button 'Export history'
    $archivePath = Join-Path $historyRoot 'clipboard-history.zip'
    Complete-ArchiveDialog 'Export history' $archivePath $true
    Wait-For { (Test-Path $archivePath) -and (Find-Named 'History exported. Sensitive items excluded.') } 'archive_export_finished' | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
      $reader = [IO.StreamReader]::new($archive.GetEntry('history.json').Open(), [Text.Encoding]::UTF8)
      try { $exported = $reader.ReadToEnd() | ConvertFrom-Json }
      finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    Add-Check 'native_archive_export_contains_mac_history' ($exported.items.Count -eq 3 -and @($exported.items | Where-Object { $_.sensitive }).Count -eq 0)
    Invoke-Button 'Clear history'
    Invoke-Button 'Delete all history'
    Wait-For { Find-Named 'History cleared' } 'archive_source_cleared' | Out-Null
    Invoke-Button 'Import history'
    Complete-ArchiveDialog 'Import history' $archivePath
    Wait-For { Find-Named 'Imported 3 items; 0 skipped; 0 missing blobs.' } 'archive_native_round_trip' | Out-Null
    $restored = Read-SharedJson (Join-Path $historyRoot 'history.json')
    Add-Check 'native_archive_import_preserves_original_order_and_content' (($restored.items.sha256 -join ',') -ceq ($exported.items.sha256 -join ','))
    Invoke-Button 'Import history'
    Complete-ArchiveDialog 'Import history' $archivePath
    Wait-For { Find-Named 'Imported 0 items; 3 skipped; 0 missing blobs.' } 'archive_duplicate_result' | Out-Null
    Add-Check 'native_archive_duplicate_import_is_counted' ((Read-SharedJson (Join-Path $historyRoot 'history.json')).items.Count -eq 3)
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'archive_state_quit_timeout' }
    if ($application.ExitCode -ne 0) {
      # Process metadata only: retain a nullable numeric code for a real crash
      # or an unexpected process-object lifetime issue, never payload/log text.
      $exitMetadata = @{ hasExited = $application.HasExited; exitCode = $application.ExitCode }
      [IO.File]::WriteAllText((Join-Path $OutputDirectory 'archive-exit.json'), ($exitMetadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    Add-Check 'archive_state_profile_quits_cleanly' ($application.ExitCode -eq 0)

    $historyRoot = Join-Path $OutputDirectory ('startup-state-' + [Guid]::NewGuid().ToString('N'))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--smoke-root', ('"' + $historyRoot + '"'), '--smoke-startup') -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'startup-state.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'startup-state.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'startup_private_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named '3 items') } 'startup_private_profile' | Out-Null
    Invoke-Button 'Settings'
    Wait-For { (Find-Named 'Preferences') -and (Find-Named 'Enable launch at login') } 'startup_initial_disabled' | Out-Null
    $settingsEditor = Get-Editor
    $settingsEditorID = ($settingsEditor.GetRuntimeId() -join ',')
    $settingsEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('321')
    $runPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
    function Get-PrivateStartupNames {
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
      if ($null -eq $key) { return @() }
      try { return @($key.GetValueNames() | Where-Object { $_.StartsWith('com.clipboard.test.', [StringComparison]::Ordinal) }) }
      finally { $key.Dispose() }
    }
    $beforeStartupNames = @(Get-PrivateStartupNames)
    $startupRegistrationName = $null
    $startupCommand = $null
    $foreignStartupCommand = $null
    $focusFixture = [IntPtr]::Zero
    try {
      Invoke-Button 'Enable launch at login'
      Wait-For { Find-Named 'Disable launch at login' } 'startup_explicit_enable' | Out-Null
      $newNames = @(Get-PrivateStartupNames | Where-Object { $_ -notin $beforeStartupNames })
      Add-Check 'private_startup_toggle_uses_only_synthetic_registration' ($newNames.Count -eq 1)
      $startupRegistrationName = $newNames[0]
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
      try {
        $startupCommand = [string]$key.GetValue($startupRegistrationName)
        if (!$startupCommand.Contains('.startup-no-launch')) { throw 'startup_fixture_command' }
        $key.DeleteValue($startupRegistrationName, $false)
      } finally { $key.Dispose() }
      [PreviewNative]::ShowWindow($nativeWindowHandle, 6) | Out-Null
      Wait-For { [PreviewNative]::IsIconic($nativeWindowHandle) } 'startup_settings_minimized' | Out-Null
      [PreviewNative]::ShowWindow($nativeWindowHandle, 9) | Out-Null
      [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
      Wait-For { (Find-Named 'Preferences') -and (Find-Named 'Enable launch at login') } 'startup_state_after_restore' | Out-Null
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
      try { Add-Check 'settings_restore_reconciles_external_startup_disable' ($null -eq $key.GetValue($startupRegistrationName)) }
      finally { $key.Dispose() }
      $currentEditor = Get-Editor
      Add-Check 'startup_restore_preserves_native_editor_draft' (($currentEditor.GetRuntimeId() -join ',') -eq $settingsEditorID -and $currentEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -ceq '321')
      $focusFixture = [PreviewNative]::CreateFocusFixture()
      if ($focusFixture -eq [IntPtr]::Zero) { throw 'startup_focus_fixture' }
      if ($env:GITHUB_ACTIONS -ne 'true') { throw 'startup_pointer_fixture_requires_isolated_runner' }
      if (![PreviewNative]::ClickFocusFixture()) { throw 'startup_pointer_activation_failed' }
      Wait-For { [PreviewNative]::GetForegroundWindow() -eq $focusFixture } 'startup_settings_deactivated_without_unmap' | Out-Null
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
      try { $key.SetValue($startupRegistrationName, $startupCommand, [Microsoft.Win32.RegistryValueKind]::String) }
      finally { $key.Dispose() }
      [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
      Wait-For { [PreviewNative]::GetForegroundWindow() -eq $nativeWindowHandle } 'startup_settings_reactivated_without_remap' | Out-Null
      Wait-For { (Find-Named 'Preferences') -and (Find-Named 'Disable launch at login') } 'startup_state_after_reactivation' | Out-Null
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
      try { Add-Check 'settings_reactivation_reads_external_startup_state_without_writing' ($key.GetValue($startupRegistrationName) -ceq $startupCommand) }
      finally { $key.Dispose() }
      Invoke-Button 'Disable launch at login'
      Wait-For { Find-Named 'Enable launch at login' } 'startup_explicit_disable' | Out-Null
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
      try { Add-Check 'explicit_startup_disable_removes_the_owned_registration' ($null -eq $key.GetValue($startupRegistrationName)) }
      finally { $key.Dispose() }
      $foreignStartupCommand = $startupCommand.Replace('.startup-no-launch', '.startup-other-no-launch')
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
      try { $key.SetValue($startupRegistrationName, $foreignStartupCommand, [Microsoft.Win32.RegistryValueKind]::String) }
      finally { $key.Dispose() }
      Invoke-Button 'Enable launch at login'
      Wait-For { Find-Named 'Startup entry conflicts with this installation. Check system startup settings before retrying.' } 'startup_conflict_guidance' | Out-Null
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
      try { Add-Check 'startup_conflict_preserves_other_installation_entry' ($key.GetValue($startupRegistrationName) -ceq $foreignStartupCommand) }
      finally { $key.Dispose() }
      $currentEditor = Get-Editor
      Add-Check 'startup_conflict_preserves_native_editor_draft' (($currentEditor.GetRuntimeId() -join ',') -eq $settingsEditorID -and $currentEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -ceq '321')
      $settingsFile = Join-Path $historyRoot 'desktop-settings.json'
      $draftUnsaved = !(Test-Path $settingsFile)
      if (!$draftUnsaved) { $draftUnsaved = (Read-SharedJson $settingsFile).historyCapacity -eq 100 }
      Add-Check 'startup_reconciliation_does_not_save_content_drafts' $draftUnsaved
      $sizeEditor = Wait-For { Get-EditorWithValue '10' } 'size_preference_editor'
      $sizeEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('0')
      Invoke-Button 'Save content settings'
      Wait-For { (Find-Named 'Content settings saved') -and (Read-SharedJson $settingsFile).maxClipSizeBytes -eq 0 } 'disabled_size_preference_saved' | Out-Null
      Add-Check 'native_settings_can_disable_size_filtering' ($null -ne (Find-Named '0 disables size filtering. Clipboard transfers remain limited to 16 MiB.'))
      $sizeEditor = Wait-For { Get-EditorWithValue '0' } 'disabled_size_editor'
      $sizeEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('-1')
      Invoke-Button 'Save content settings'
      Wait-For { Find-Named 'Enter a capacity of 1–5000 and a size of 0–16 MiB.' } 'negative_size_preference_rejected' | Out-Null
      Add-Check 'invalid_size_does_not_replace_disabled_preference' ((Read-SharedJson $settingsFile).maxClipSizeBytes -eq 0)
      Invoke-Button 'Quit Clipboard'
      if (!$application.WaitForExit(10000)) { throw 'startup_state_quit_timeout' }
      Add-Check 'startup_state_profile_quits_cleanly' ($application.ExitCode -eq 0)
    } finally {
      [PreviewNative]::CloseFocusFixture()
      if ($startupRegistrationName -and $startupCommand) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
        if ($key) {
          try { if ($key.GetValue($startupRegistrationName) -ceq $startupCommand -or ($foreignStartupCommand -and $key.GetValue($startupRegistrationName) -ceq $foreignStartupCommand)) { $key.DeleteValue($startupRegistrationName, $false) } }
          finally { $key.Dispose() }
        }
      }
    }

    $sensitiveProbe = $true
    $historyRoot = Join-Path $OutputDirectory ('sensitive-preview-' + [Guid]::NewGuid().ToString('N'))
    $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
      -ArgumentList @('--smoke-root', ('"' + $historyRoot + '"'), '--smoke-sensitive') -PassThru `
      -RedirectStandardOutput (Join-Path $OutputDirectory 'sensitive.stdout.log') `
      -RedirectStandardError (Join-Path $OutputDirectory 'sensitive.stderr.log')
    $null = $application.Handle
    $nativeWindowHandle = Wait-For {
      $handle = [PreviewNative]::FindWindow([uint32]$application.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'sensitive_private_window'
    $window = [Windows.Automation.AutomationElement]::FromHandle($nativeWindowHandle)
    Wait-For { (Find-Named 'Ready') -and (Find-Named '5 items') } 'sensitive_private_profile' | Out-Null
    Invoke-Button 'Image'
    Wait-For { (Find-Named '1 items') -and (Find-Named 'Reveal for this session') -and (Find-Named 'Sensitive content is hidden.') } 'sensitive_image_masked' | Out-Null
    Add-Check 'sensitive_image_starts_masked' ($null -eq (Get-ImagePreview))
    [PreviewNative]::GetWindowRect($nativeWindowHandle, [ref]$sensitiveInitialBounds) | Out-Null
    $sensitiveStage = 'sensitive_filter_initial_identity'
    $sensitiveFilterID = ((Find-Named 'Text').GetRuntimeId() -join ',')
    Invoke-Button 'Reveal for this session'
    Wait-For { Get-ImagePreview } 'sensitive_image_revealed' | Out-Null
    Add-Check 'explicit_sensitive_reveal_decodes_native_image' $true
    $ocrControl = Find-Named 'Recognize text'
    for ($depth = 0; $depth -lt 10 -and $ocrControl -and $ocrControl.Current.ControlType -ne [Windows.Automation.ControlType]::Button; $depth++) {
      $ocrControl = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ocrControl)
    }
    Add-Check 'revealed_sensitive_image_still_disables_ocr' ($ocrControl -and !$ocrControl.Current.IsEnabled)
    Invoke-Button 'Hide'
    Wait-For { [PreviewNative]::FindWindow([uint32]$application.Id) -eq [IntPtr]::Zero } 'sensitive_window_hidden' | Out-Null
    Wake-Existing
    Wait-For { (Find-Named 'Sensitive content is hidden.') -and (Find-Named 'Reveal for this session') } 'sensitive_remasked_after_hide' | Out-Null
    Add-Check 'hide_reopen_revokes_sensitive_reveal' ($null -eq (Get-ImagePreview))
    Add-Check 'sensitive_filter_identity_survives_one_hide' (((Find-Named 'Text').GetRuntimeId() -join ',') -eq $sensitiveFilterID)
    Invoke-Button 'Reveal for this session'
    Wait-For { Get-ImagePreview } 'sensitive_image_revealed_again' | Out-Null
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'sensitive_settings_handoff' | Out-Null
    Invoke-Button 'Back to history'
    Wait-For { (Find-Named 'Sensitive content is hidden.') -and (Find-Named 'Reveal for this session') } 'sensitive_remasked_after_settings' | Out-Null
    Add-Check 'settings_handoff_revokes_sensitive_reveal' $true
    $sensitiveFilterID = ((Find-Named 'Text').GetRuntimeId() -join ',')
    Invoke-Button 'Reveal for this session'
    Invoke-Button 'Hide'
    Wait-For { [PreviewNative]::FindWindow([uint32]$application.Id) -eq [IntPtr]::Zero } 'rapid_sensitive_hide' | Out-Null
    Wake-Existing
    Wait-For { (Find-Named 'Sensitive content is hidden.') -and (Find-Named 'Reveal for this session') } 'rapid_reveal_remains_revoked' | Out-Null
    Add-Check 'rapid_reveal_hide_does_not_restore_sensitive_preview' ($null -eq (Get-ImagePreview))
    Add-Check 'sensitive_filter_identity_survives_rapid_hide' (((Find-Named 'Text').GetRuntimeId() -join ',') -eq $sensitiveFilterID)
    Invoke-Button 'Text'
    Wait-For { (Find-Named '4 items') -and (Find-Named 'Reveal for this session') } 'sensitive_text_masked' | Out-Null
    $secret = 'Sensitive synthetic preview fixture · 中文'
    Add-Check 'sensitive_text_starts_masked' ($null -eq (Find-Named $secret))
    Invoke-Button 'Reveal for this session'
    Wait-For { Find-Named $secret } 'sensitive_text_explicitly_revealed' | Out-Null
    Add-Check 'explicit_sensitive_reveal_displays_text' $true
    Set-Search 'Welcome'
    Wait-For { (Find-Named '1 items') -and !(Find-Named $secret) } 'public_selection_after_reveal' | Out-Null
    Invoke-Button 'Image'
    Wait-For { Find-Named '0 items' } 'different_kind_after_reveal' | Out-Null
    Set-Search ''
    Wait-For { (Find-Named '1 items') -and (Find-Named 'Reveal for this session') } 'selection_change_revoked_reveal' | Out-Null
    Add-Check 'selection_change_revokes_sensitive_reveal' ($null -eq (Find-Named $secret))
    $persisted = Read-SharedJson (Join-Path $historyRoot 'history.json')
    $sensitiveRows = @($persisted.items | Where-Object { $_.sensitive })
    $blobFiles = @(Get-ChildItem -File (Join-Path $historyRoot 'blobs'))
    Add-Check 'sensitive_reveal_keeps_history_memory_only' ($persisted.items.Count -eq 3 -and $sensitiveRows.Count -eq 0 -and $blobFiles.Count -eq 0)
    Invoke-Button 'Settings'
    Wait-For { Find-Named 'Preferences' } 'sensitive_quit_settings' | Out-Null
    Invoke-Button 'Quit Clipboard'
    if (!$application.WaitForExit(10000)) { throw 'sensitive_quit_timeout' }
    Add-Check 'sensitive_preview_quits_cleanly' ($application.ExitCode -eq 0)
  }
} catch {
  if ($sensitiveProbe) {
    $checks.Add(@{ name = 'sensitive_ui_probe'; passed = $false; detail = $sensitiveStage; errorType = $_.Exception.GetType().FullName })
    'Sensitive preview probe failed; content diagnostics suppressed.' | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'probe-error.log')
    try {
      $bounds = [PreviewNative+Rect]::new()
      [PreviewNative]::GetWindowRect($nativeWindowHandle, [ref]$bounds) | Out-Null
      @{ stage = $sensitiveStage; width = $bounds.Right - $bounds.Left; height = $bounds.Bottom - $bounds.Top;
         initialWidth = $sensitiveInitialBounds.Right - $sensitiveInitialBounds.Left;
         initialHeight = $sensitiveInitialBounds.Bottom - $sensitiveInitialBounds.Top;
         compactFiltersControl = [bool]((Find-Named 'Filters') -or (Find-Named 'Hide filters'));
         textFilterControl = [bool](Find-Named 'Text'); fourItems = [bool](Find-Named '4 items');
         masked = [bool](Find-Named 'Sensitive content is hidden.');
         revealControl = [bool](Find-Named 'Reveal for this session');
         emptyPreview = [bool](Find-Named 'Choose an item to preview its content.');
         nativeImage = [bool](Get-ImagePreview) } | ConvertTo-Json -Depth 3 |
        Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'sensitive-control-metadata.json')
    } catch { }
  } else {
    $checks.Add(@{ name = 'ui_probe'; passed = $false; detail = $_.Exception.Message })
    try {
      if ($window) {
        $controls = $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        $controls | ForEach-Object {
          @{ type=$_.Current.ControlType.ProgrammaticName; class=$_.Current.ClassName;
             focusable=$_.Current.IsKeyboardFocusable; focused=$_.Current.HasKeyboardFocus;
             enabled=$_.Current.IsEnabled; runtimeID=($_.GetRuntimeId() -join ',');
             valueLength=$(try { $_.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value.Length } catch { -1 }) }
        } | ConvertTo-Json -Depth 5 | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'control-state.json')
      }
    } catch { }
    $_ | Format-List * -Force | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'probe-error.log')
    # Keep crash evidence from this isolated CI desktop without changing machine settings.
    try {
      Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $probeStarted } -ErrorAction Stop |
        Where-Object { $_.Id -in @(1000, 1001, 1026) -and $_.Message -match 'ClipboardDesktop|Microsoft.UI.Xaml' } |
        Select-Object TimeCreated, Id, Message | Format-List |
        Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'application-events.log')
    } catch { $_.Exception.Message | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'event-query.log') }

    try { if ($nativeWindowHandle -ne [IntPtr]::Zero -and !$application.HasExited) { Save-Screenshot 'failure.png' } } catch { }
  }
} finally {
  if ($application -and !$application.HasExited) { Stop-Process -Id $application.Id -Force }
  $passed = $checks.Count -gt 0 -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $report = @{ platform = 'windows-gtk4-accesskit'; passed = $passed; checks = @($checks.ToArray());
    limitations = @('Native accessibility value/invoke operations and an owned CI-only mouse activation fixture; no keyboard injection.',
      'Real Chinese IME and global hotkey focus transfer remain untested.') }
  $json = $report | ConvertTo-Json -Depth 6
  $json | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'results.json')
  Write-Output $json
}
if (!$passed) { exit 1 }
