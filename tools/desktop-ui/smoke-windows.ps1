param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$OutputDirectory,
      [string]$ClipboardPeer,
      [string]$OCRFixture,
      [switch]$Baseline,
      [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PreviewNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  private delegate bool EnumWindowProc(IntPtr hwnd, IntPtr parameter);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
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
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
  [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
  [DllImport("user32.dll")] private static extern IntPtr GetClipboardOwner();
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
  public static bool OwnsClipboard(uint processId) {
    uint owner;
    GetWindowThreadProcessId(GetClipboardOwner(), out owner);
    return owner == processId;
  }
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

function Add-Check([string]$Name, [bool]$Passed) {
  $script:checks.Add(@{ name = $Name; passed = $Passed })
  if (!$Passed) { throw $Name }
}
function Wait-For([scriptblock]$Predicate, [string]$Name) {
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
function Invoke-Button([string]$Label) {
  $element = Wait-For { Find-Named $Label } ('button_' + $Label)
  # A SwiftCrossUI Button wraps a composed label; UIA may name its Text child.
  for ($depth = 0; $depth -lt 10 -and $element; $depth++) {
    if ($element.Current.ControlType -eq [Windows.Automation.ControlType]::Button) { break }
    $element = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
  }
  if (!$element -or $element.Current.ControlType -ne [Windows.Automation.ControlType]::Button) { throw ('button_ancestor_' + $Label) }
  $pattern = $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
  $pattern.Invoke()
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
    Invoke-Button 'Delete'
    Wait-For { (Find-Named 'Item deleted') -and (Find-Named '0 items') } 'delete_updates_list' | Out-Null
    Add-Check 'delete_updates_real_store' $true
    Invoke-Button 'All'
    Set-Search ''
    Wait-For { Find-Named '2 items' } 'remaining_history' | Out-Null
    $history = Get-Content -Raw -Encoding UTF8 (Join-Path $historyRoot 'history.json') | ConvertFrom-Json
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
          Wait-For { Find-Named '1 items' } ('capture_native_' + $fixture) | Out-Null
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
            Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $CopyRevision -and [PreviewNative]::OwnsClipboard([uint32]$application.Id) } 'copy_image_status' | Out-Null
            Add-Check 'image_copy_keeps_original_native_png' ([PreviewNative]::HasPngClipboard())
          } else {
            Invoke-Button 'Copy'
            Wait-For { (Find-Named 'Copied to clipboard') -and [PreviewNative]::GetClipboardSequenceNumber() -ne $CopyRevision -and [PreviewNative]::OwnsClipboard([uint32]$application.Id) } 'copy_files_status' | Out-Null
            Add-Check 'file_copy_keeps_both_native_paths' ([PreviewNative]::ClipboardFileCount() -eq 2)
          }
        } finally {
          $peer.StandardInput.Close()
          if (!$peer.WaitForExit(5000)) { $peer.Kill(); $peer.WaitForExit() }
          $peer.Dispose()
        }
      }
      if ($OCRFixture) {
        Invoke-Button 'Image'
        Wait-For { Find-Named '1 items' } 'image_for_ocr_replacement' | Out-Null
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
          Wait-For { (Find-Named '1 items') -and (Find-Named 'Recognize text') } 'ocr_image_captured' | Out-Null
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
    Invoke-Button 'Save behavior'
    $settingsFile = Join-Path $historyRoot 'desktop-settings.json'
    Wait-For { Test-Path $settingsFile } 'saved_settings_file' | Out-Null
    $saved = Get-Content -Raw -Encoding UTF8 $settingsFile | ConvertFrom-Json
    Add-Check 'behavior_saved_without_enabling_recording' (!$saved.recordingEnabled -and $saved.closeToTray)
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
  }
} catch {
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
} finally {
  if ($application -and !$application.HasExited) { Stop-Process -Id $application.Id -Force }
  $passed = $checks.Count -gt 0 -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $report = @{ platform = 'windows-gtk4-accesskit'; passed = $passed; checks = @($checks.ToArray());
    limitations = @('Native accessibility value/invoke operations only; no keyboard injection.',
      'Real Chinese IME and global hotkey focus transfer remain untested.') }
  $json = $report | ConvertTo-Json -Depth 6
  $json | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'results.json')
  Write-Output $json
}
if (!$passed) { exit 1 }
