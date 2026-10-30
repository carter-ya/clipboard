param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PreviewNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
  [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
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
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$Executable = [IO.Path]::GetFullPath($Executable)
$checks = [Collections.Generic.List[object]]::new()
$application = $null
$window = $null

function Add-Check([string]$Name, [bool]$Passed) {
  $script:checks.Add(@{ name = $Name; passed = $Passed })
  if (!$Passed) { throw $Name }
}
function Wait-For([scriptblock]$Predicate, [string]$Name) {
  $deadline = [DateTime]::UtcNow.AddSeconds(40)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($script:application -and $script:application.HasExited) { throw 'application_exited' }
    try { $value = & $Predicate; if ($value) { return $value } } catch { }
    Start-Sleep -Milliseconds 150
  }
  throw $Name
}
function Get-Window {
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$script:application.Id)
  return [Windows.Automation.AutomationElement]::RootElement.FindFirst(
    [Windows.Automation.TreeScope]::Children, $condition)
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
function Save-Screenshot([string]$Name) {
  $rect = New-Object PreviewNative+Rect
  $handle = [IntPtr]$script:window.Current.NativeWindowHandle
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
  $application = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) `
    -ArgumentList @('--smoke-root', ('"' + $historyRoot + '"')) -PassThru `
    -RedirectStandardOutput (Join-Path $OutputDirectory 'application.stdout.log') `
    -RedirectStandardError (Join-Path $OutputDirectory 'application.stderr.log')
  $window = Wait-For { Get-Window } 'native_window'
  [PreviewNative]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle) | Out-Null
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
  $value = (Get-Editor).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
  Add-Check 'settings_round_trip_preserves_search' ($value -eq '中文')
  Invoke-Button 'Delete'
  Wait-For { (Find-Named 'Item deleted') -and (Find-Named '0 items') } 'delete_updates_list' | Out-Null
  Add-Check 'delete_updates_real_store' $true
  Invoke-Button 'All'
  Set-Search ''
  Wait-For { Find-Named '2 items' } 'remaining_history' | Out-Null
  $history = Get-Content -Raw -Encoding UTF8 (Join-Path $historyRoot 'history.json') | ConvertFrom-Json
  Add-Check 'store_persistence_matches_ui' ($history.items.Count -eq 2)
} catch {
  $checks.Add(@{ name = 'ui_probe'; passed = $false; detail = $_.Exception.Message })
  try { if ($window) { Save-Screenshot 'failure.png' } } catch { }
} finally {
  if ($application -and !$application.HasExited) { Stop-Process -Id $application.Id -Force }
  $passed = $checks.Count -gt 0 -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $report = @{ platform = 'windows-winui'; passed = $passed; checks = @($checks.ToArray());
    limitations = @('Native accessibility value/invoke operations only; no keyboard injection.',
      'Real Chinese IME and global hotkey focus transfer remain untested.') }
  $json = $report | ConvertTo-Json -Depth 6
  $json | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'results.json')
  Write-Output $json
}
if (!$passed) { exit 1 }
