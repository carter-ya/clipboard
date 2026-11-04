param([Parameter(Mandatory=$true)][string]$Executable,
      [Parameter(Mandatory=$true)][string]$Fixtures,
      [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'MTA') { throw 'preview_probe_requires_mta' }
$profile = Join-Path $env:TEMP ('clipboard-preview-private-' + [Guid]::NewGuid().ToString('N'))
$child = $null
$checks = [Collections.Generic.List[object]]::new()
$timings = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Passed) {
  $checks.Add(@{name=$Name; passed=$Passed})
  if (!$Passed) { throw $Name }
}
function Named([string]$Name) {
  $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name)
  return $script:previewWindow.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Await-Name([string]$Name) {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($child.HasExited) { throw 'preview_child_exited' }
    $element = Named $Name
    if ($element) { return $element }
    Start-Sleep -Milliseconds 20
  }
  throw 'preview_expected_control_missing'
}
function Await-PreviewBytes([long]$Bytes) {
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
  $suffix = ' ' + [char]0x00b7 + ' ' + $Bytes + ' bytes'
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($child.HasExited) { throw 'preview_child_exited' }
    foreach ($label in $script:previewWindow.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
      # AccessKit may retire a text node between enumeration and property read.
      # Only compare available names; the next iteration still needs the exact byte count.
      try { $candidate = [string]$label.Current.Name }
      catch [Windows.Automation.ElementNotAvailableException] { continue }
      if ($candidate.EndsWith($suffix, [StringComparison]::Ordinal)) { return }
    }
    Start-Sleep -Milliseconds 20
  }
  throw 'preview_selected_metadata_missing'
}
function Invoke-PreviewButton([string]$Name) {
  $control = Await-Name $Name
  for ($depth = 0; $depth -lt 10 -and $control -and
       $control.Current.ControlType -ne [Windows.Automation.ControlType]::Button; $depth++) {
    $control = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($control)
  }
  if (!$control -or !$control.Current.IsEnabled) { throw 'preview_button_unavailable' }
  $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Measure-Action([string]$Name, [string]$Expected) {
  $control = Named $Name
  if (!$control) { throw 'preview_action_missing' }
  $invoke = $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $invoke.Invoke() # One native mutation; only its result is observed below.
  $null = Await-Name $Expected
  $watch.Stop()
  $timings.Add(@{action=$Name; milliseconds=$watch.Elapsed.TotalMilliseconds})
}
try {
  # Accept only this generated public fixture shape, never a production profile.
  $settings = Get-Content -Raw (Join-Path $Fixtures 'desktop-settings.json') | ConvertFrom-Json
  if ($settings.recordingEnabled -ne $false -or $settings.shortcutEnabled -ne $false -or
      $settings.languageOverride -ne 'en') { throw 'preview_fixture_settings_invalid' }
  $history = Get-Content -Raw (Join-Path $Fixtures 'history.json') | ConvertFrom-Json
  if (@($history.items).Count -ne 100 -or @($history.items | Where-Object {$_.sensitive}).Count -ne 0) {
    throw 'preview_fixture_history_invalid'
  }
  [IO.Directory]::CreateDirectory($profile) | Out-Null
  Copy-Item (Join-Path $Fixtures 'history.json') $profile
  Copy-Item (Join-Path $Fixtures 'desktop-settings.json') $profile
  $start = [Diagnostics.ProcessStartInfo]::new($Executable, ('--data-root "' + $profile + '"'))
  $start.UseShellExecute = $true
  $start.WorkingDirectory = Split-Path $Executable
  $child = [Diagnostics.Process]::Start($start)
  $null = $child.Handle
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  $handle = [IntPtr]::Zero
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($child.HasExited) { throw 'preview_child_exited' }
    $child.Refresh(); $handle = $child.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 100
  }
  if ($handle -eq [IntPtr]::Zero) { throw 'preview_window_missing' }
  $script:previewWindow = [Windows.Automation.AutomationElement]::FromHandle($handle)
  Check 'preview_window_owned' ($previewWindow.Current.ProcessId -eq $child.Id)
  $null = Await-Name 'Ready'; $null = Await-Name '100 items'
  $editCondition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
  $editor = $previewWindow.FindFirst([Windows.Automation.TreeScope]::Descendants, $editCondition)
  $value = $editor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
  foreach ($kind in @('PNG','BMP24','BMP32','BMPV5opaque','BMPV5zero')) {
    $item = @($history.items | Where-Object {$_.preview -eq ('Fixture ' + $kind)})
    if ($item.Count -ne 1) { throw 'preview_image_fixture_missing' }
    $value.SetValue('Fixture ' + $kind)
    $null = Await-Name '1 items'
    # Two bitmap variants can have the same byte length. Wait for the exact
    # filtered row too, so the preceding picture cannot satisfy this check.
    $null = Await-Name ('Fixture ' + $kind)
    Await-PreviewBytes $item[0].sizeBytes
    $picture = Await-Name 'Image preview'
    Check ($kind + '_native_preview_present') ($null -ne $picture -and $picture.Current.ControlType -eq [Windows.Automation.ControlType]::Image)
    $box = $picture.Current.BoundingRectangle
    Check ($kind + '_native_preview_visible') (!$picture.Current.IsOffscreen -and $box.Width -gt 0 -and $box.Height -gt 0)
    $windowBox = $previewWindow.Current.BoundingRectangle
    Check ($kind + '_native_preview_fits_window') ($box.Left -ge $windowBox.Left -and
      $box.Top -ge $windowBox.Top -and $box.Right -le $windowBox.Right -and $box.Bottom -le $windowBox.Bottom)
  }
  $value.SetValue(''); $null = Await-Name '100 items'
  foreach ($round in 1..3) {
    Measure-Action 'Image' '5 items'
    Measure-Action 'Text' '95 items'
    Measure-Action 'Pinned' '10 items'
    Measure-Action 'All' '100 items'
  }
  Measure-Action 'Settings' 'Preferences'
  Check 'all_measured_transitions_complete' ($timings.Count -eq 13)
  $null = Await-Name 'Appearance'
  $draftEditor = $previewWindow.FindFirst([Windows.Automation.TreeScope]::Descendants, $editCondition)
  $draftID = $draftEditor.GetRuntimeId() -join ','
  $draftEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('321')
  foreach ($page in @(@{name='Privacy'; expected='Maximum clipboard item (MiB)'},
                      @{name='Shortcuts'; expected='Enable global shortcut'},
                      @{name='AI'; expected='Local text models'},
                      @{name='Data'; expected='Export history'})) {
    $navigation = Await-Name $page.name
    $rect = $navigation.Current.BoundingRectangle
    $windowRect = $previewWindow.Current.BoundingRectangle
    Check ('settings_' + $page.name + '_navigation_visible') (!$navigation.Current.IsOffscreen -and
      $rect.Width -gt 0 -and $rect.Height -gt 0 -and $rect.Left -ge $windowRect.Left -and
      $rect.Right -le $windowRect.Right -and $rect.Top -ge $windowRect.Top -and $rect.Bottom -le $windowRect.Bottom)
    Invoke-PreviewButton $page.name
    $null = Await-Name $page.expected
  }
  Invoke-PreviewButton 'General'
  $null = Await-Name 'Appearance'
  $restoredEditor = $previewWindow.FindFirst([Windows.Automation.TreeScope]::Descendants, $editCondition)
  Check 'settings_pages_preserve_native_editor_and_unsaved_draft' (
    ($restoredEditor.GetRuntimeId() -join ',') -ceq $draftID -and
    $restoredEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -ceq '321')
  Invoke-PreviewButton 'Back to history'
  $null = Await-Name 'All types'
  $null = Await-Name '100 items'
  Invoke-PreviewButton 'Filters'
  $null = Await-Name 'Hide filters'
  Check 'source_filter_remains_available' ($previewWindow.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition).Count -eq 2)
  Invoke-PreviewButton 'Hide filters'
  $null = Await-Name 'Filters'
  Check 'source_filter_closes_without_removing_search' ($previewWindow.FindAll([Windows.Automation.TreeScope]::Descendants, $editCondition).Count -eq 1)
  Check 'owned_process_survives_preview_and_navigation' (!$child.HasExited)
} catch {
  $detail = $_.Exception.Message
  if ($detail -notmatch '^[a-zA-Z0-9_]+$') { $detail = 'preview_probe_failed' }
  $checks.Add(@{name='preview_probe'; passed=$false; detail=$detail; errorType=$_.Exception.GetType().FullName; scriptLine=$_.InvocationInfo.ScriptLineNumber})
} finally {
  if ($child) {
    if (!$child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
    $child.Dispose()
  }
  if (Test-Path $profile) { Remove-Item -LiteralPath $profile -Recurse -Force }
  $passed = @($checks | Where-Object {!$_.passed}).Count -eq 0
  $report = @{passed=$passed; checks=$checks.ToArray(); timings=$timings.ToArray();
    executableSHA256=(Get-FileHash $Executable).Hash.ToLowerInvariant();
    scope='100 synthetic public records; owned UIA actions to accessible result publication. Recording/shortcuts off; no clipboard, keyboard, real history, physical-frame or IME claim.'}
  $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $Output
}
if (!$passed) { throw 'preview_regression_failed' }
