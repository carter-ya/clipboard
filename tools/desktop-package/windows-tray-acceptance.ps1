# Called only with the child process and window created by the private fixture.
function Test-OwnedTrayActivation($Owned, [IntPtr]$Handle) {
  $window = [Windows.Automation.AutomationElement]::FromHandle($Handle)
  if ($window.Current.ProcessId -ne $Owned.Id) { throw 'tray_window_owner_mismatch' }
  $tray = [ClipboardOwnedTray]::new($Owned.Id, $Handle)
  $hideCondition = [Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'Hide'),
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
  $hide = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $hideCondition)
  if ($null -eq $hide) { throw 'tray_hide_control_missing' }
  # Invoke once through the real GTK action, preserving GTK's visibility state.
  $hide.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ($tray.Visible -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
  if ($Owned.HasExited -or $tray.Visible) { throw 'tray_initial_hide_failed' }
  $checks = [Collections.Generic.List[object]]::new()
  $checks.Add(@{name='tray_private_window_hidden_by_native_control'; passed=$true})
  # Legacy release + v4 selection, including a repeated activation, must be
  # idempotent. Submit each once, then only observe; no input retries.
  $tray.Notify(0x202)
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while (!$tray.Visible -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
  if ($Owned.HasExited -or !$tray.Visible) { throw 'tray_release_does_not_show_history' }
  $checks.Add(@{name='tray_release_shows_hidden_history'; passed=$true})
  foreach ($notification in @(0x400, 0x202, 0x400, 0x401)) {
    $tray.Notify($notification)
    $deadline = [DateTime]::UtcNow.AddSeconds(1)
    while ([DateTime]::UtcNow -lt $deadline) {
      if ($Owned.HasExited -or !$tray.Visible) { throw 'tray_repeat_activation_hides_window' }
      Start-Sleep -Milliseconds 50
    }
  }
  $checks.Add(@{name='tray_repeated_mouse_and_keyboard_activation_stays_visible'; passed=$true})
  return $checks.ToArray()
}
