param([Parameter(Mandatory=$true)][string]$Installer,
      [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') {
  throw 'capture_candidate_requires_owned_windows_actions'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'windows-no-console-process.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'windows-owned-tray.cs')
. (Join-Path $PSScriptRoot 'windows-tray-acceptance.ps1')
$Installer = [IO.Path]::GetFullPath($Installer)
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory($Output) | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('clipboard-capture-launch-' + [Guid]::NewGuid().ToString('N'))
$installed = Join-Path $root 'install space'
$profile = Join-Path $root 'synthetic-history'
$executable = Join-Path $installed 'bin/ClipboardDesktop.exe'
$originalPath = $env:Path
$owned = $null
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Passed) {
  $checks.Add(@{name=$Name; passed=$Passed})
  if (!$Passed) { throw $Name }
}
function Read-CandidateSnapshot([string]$Path) {
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try {
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
    finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
}
function Run-Installer([string]$Path, [string[]]$Arguments) {
  $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
  try {
    $null = $process.Handle
    if (!$process.WaitForExit(120000)) { $process.Kill(); throw 'candidate_installer_timeout' }
    return $process.ExitCode
  } finally { $process.Dispose() }
}
try {
  # This fixture never adopts an installed application or a normal profile.
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
  try { if ($key -and $null -ne $key.GetValue('com.clipboard.desktop', $null)) { throw 'existing_startup_registration' } }
  finally { if ($key) { $key.Dispose() } }
  Check 'private_profile_does_not_exist' (!(Test-Path $profile))
  $code = Run-Installer $Installer @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="' + $installed + '"'))
  Check 'private_per_user_install_succeeds' ($code -eq 0 -and (Test-Path $executable))
  [IO.Directory]::CreateDirectory($profile) | Out-Null
  [IO.File]::WriteAllText((Join-Path $profile 'desktop-settings.json'),
    '{"languageOverride":"en","recordingEnabled":false,"shortcutEnabled":false}', [Text.UTF8Encoding]::new($false))
  # Exclude SDK/build tools from child lookup. The main exe resolves its own
  # bundled DLLs; no developer runtime directory is added to this PATH.
  $env:Path = [Environment]::SystemDirectory + ';' + $env:WINDIR
  $arguments = '--smoke-root "' + $profile + '" --smoke-sensitive'
  $owned = [ClipboardNoConsoleProcess]::Start($executable, $arguments)
  Start-Sleep -Seconds 3
  Check 'installed_gui_survives_without_console_or_automation' (!$owned.HasExited)
  $deadline = [DateTime]::UtcNow.AddSeconds(40)
  $ready = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($owned.HasExited) { throw ('candidate_exited_0x' + $owned.ExitCode.ToString('x8')) }
    # Resolve only the PID created above, without adopting other windows.
    $process = [Diagnostics.Process]::GetProcessById($owned.Id)
    try { $process.Refresh(); $handle = $process.MainWindowHandle }
    finally { $process.Dispose() }
    try { if ($handle -ne [IntPtr]::Zero) {
      $window = [Windows.Automation.AutomationElement]::FromHandle($handle)
      if ($window.Current.ProcessId -ne $owned.Id) { throw 'candidate_window_owner_mismatch' }
      $readyCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'Ready')
      $countCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, '5 items')
      $ready = $null -ne $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $readyCondition) -and
        $null -ne $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $countCondition)
      if ($ready) { break }
    } } catch [Windows.Automation.ElementNotAvailableException] { }
    catch [Runtime.InteropServices.COMException] { }
    Start-Sleep -Milliseconds 150
  }
  Check 'all_five_builtin_text_and_png_inserts_finish_without_stderr' $ready
  $snapshot = Read-CandidateSnapshot (Join-Path $profile 'history.json')
  Check 'three_public_text_items_persist' (@($snapshot.items).Count -eq 3)
  Check 'sensitive_text_and_png_remain_memory_only' (@($snapshot.items | Where-Object {$_.sensitive}).Count -eq 0)
  Start-Sleep -Seconds 5
  Check 'installed_application_stays_alive_after_capture_store_refresh' (!$owned.HasExited)
  foreach ($check in @(Test-OwnedTrayActivation $owned $handle)) {
    $checks.Add($check)
  }
} catch {
  $diagnostic = $_.Exception.Message
  if ($diagnostic -notmatch '^[a-z0-9_]+$') { $diagnostic = 'candidate_probe_failed' }
  $checks.Add(@{name='capture_candidate_probe'; passed=$false; errorType=$_.Exception.GetType().FullName; detail=$diagnostic})
} finally {
  if ($owned) {
    try { $owned.Dispose() }
    catch { $checks.Add(@{name='owned_process_cleanup'; passed=$false}) }
  }
  $env:Path = $originalPath
  $uninstaller = Join-Path $installed 'unins000.exe'
  if (Test-Path $uninstaller) {
    try {
      $code = Run-Installer $uninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
      $checks.Add(@{name='owned_installation_uninstalls'; passed=($code -eq 0 -and !(Test-Path $executable))})
    } catch { $checks.Add(@{name='owned_installation_uninstalls'; passed=$false}) }
  }
  # Only this generated private fixture directory is eligible for cleanup.
  try { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
  catch { $checks.Add(@{name='owned_fixture_cleanup'; passed=$false}) }
  $passed = @($checks | Where-Object {!$_.passed}).Count -eq 0
  $report = @{passed=$passed; checks=@($checks.ToArray()); fullPlatformAcceptance=$false;
    scope='Installed GUI without inherited standard handles; synthetic text/PNG store, private history, owned tray callback activation and uninstall. No clipboard/keyboard mutation, model, browser, IME, upgrade or physical focus acceptance.'}
  $report | ConvertTo-Json -Depth 5 | Out-File -Encoding UTF8 (Join-Path $Output 'capture-launch.json')
  if (!$passed) { exit 1 }
}
