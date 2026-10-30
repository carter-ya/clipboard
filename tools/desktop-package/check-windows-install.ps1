param([Parameter(Mandatory=$true)][string]$Installer,
      [Parameter(Mandatory=$true)][string]$Output,
      [Parameter(Mandatory=$true)][string]$Probe,
      [Parameter(Mandatory=$true)][string]$ClipboardPeer,
      [Parameter(Mandatory=$true)][string]$OCRFixture)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CLIPBOARD_PRIVATE_INSTALL_TEST -ne '1') {
  throw 'Installer integration tests require an isolated GitHub Actions desktop'
}
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory($Output) | Out-Null
$Installer = [IO.Path]::GetFullPath($Installer)
$Root = Join-Path $env:RUNNER_TEMP ('clipboard-install-' + [Guid]::NewGuid().ToString('N'))
$Installed = Join-Path $Root 'install 中文 space'
$Executable = Join-Path $Installed 'bin/ClipboardDesktop.exe'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'com.clipboard.desktop'
$OriginalRun = Get-ItemPropertyValue -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
if ($null -ne $OriginalRun) { throw 'Refusing an existing Clipboard startup registration' }
$Checks = [Collections.Generic.List[object]]::new()
$App = $null
$Completed = $false
$OriginalPath = $env:Path
function Check([string]$Name, [bool]$Passed) {
  $Checks.Add(@{ name=$Name; passed=$Passed })
  Write-Host ($Name + ': ' + $Passed)
  if (!$Passed) { throw $Name }
}
function Install-Package {
  $Command = Start-Process -FilePath $Installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="' + $Installed + '"')) -PassThru
  if (!$Command.WaitForExit(120000)) { $Command.Kill(); throw 'Installer timeout' }
  return $Command.ExitCode
}
try {
  Check 'per_user_installer_succeeds' ((Install-Package) -eq 0 -and (Test-Path $Executable))
  # Exclude Swift and GTK development paths. Every application/peer DLL must
  # resolve from the installed bin directory or standard Windows system folders.
  $env:Path = (Join-Path $Installed 'bin') + ';' + $env:SystemRoot + '\System32;' + $env:SystemRoot + '\System32\WindowsPowerShell\v1.0'
  $App = Start-Process -FilePath $Executable -ArgumentList @('--data-root', ('"' + (Join-Path $Root 'running-profile') + '"'), '--background') -PassThru
  $null = $App.Handle
  $Deadline = [DateTime]::UtcNow.AddSeconds(20)
  $Running = $false
  while ([DateTime]::UtcNow -lt $Deadline -and !$App.HasExited) {
    try {
      $Mutex = [Threading.Mutex]::OpenExisting('Local\ClipboardDesktop.Running')
      $Mutex.Dispose()
      $Running = $true
      break
    } catch { Start-Sleep -Milliseconds 100 }
  }
  Check 'installed_application_holds_upgrade_mutex' $Running
  Check 'running_application_blocks_silent_upgrade' ((Install-Package) -ne 0)
  # This process owns only an empty synthetic profile. Force exit verifies that
  # OS handle cleanup releases the installation mutex after an abrupt owner loss.
  $App.Kill()
  $App.WaitForExit()
  $App = $null
  & powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File $Probe -Executable $Executable `
    -ClipboardPeer $ClipboardPeer -OCRFixture $OCRFixture -OutputDirectory (Join-Path $Output 'ui')
  Check 'installed_gui_and_services_pass_with_bundled_runtime' ($LASTEXITCODE -eq 0)
  $Histories = @(Get-ChildItem (Join-Path $Output 'ui') -Recurse -Filter history.json)
  Check 'installed_probe_persists_private_history' ($Histories.Count -gt 0)
  $HistoryHashes = @{}
  foreach ($File in $Histories) { $HistoryHashes[$File.FullName] = (Get-FileHash -Algorithm SHA256 $File.FullName).Hash }
  New-Item -Path $RunKey -Force | Out-Null
  $StartupCommand = '"' + $Executable + '" --background'
  New-ItemProperty -Path $RunKey -Name $RunName -Value $StartupCommand -PropertyType String -Force | Out-Null
  Check 'upgrade_preserves_runtime_and_startup_preference' ((Install-Package) -eq 0 -and (Get-ItemPropertyValue -Path $RunKey -Name $RunName) -eq $StartupCommand)
  $Uninstaller = Join-Path $Installed 'unins000.exe'
  $Uninstall = Start-Process -FilePath $Uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -PassThru
  if (!$Uninstall.WaitForExit(120000)) { $Uninstall.Kill(); throw 'Uninstaller timeout' }
  Check 'uninstall_removes_application_and_matching_startup' ($Uninstall.ExitCode -eq 0 -and !(Test-Path $Executable) -and
    $null -eq (Get-ItemPropertyValue -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue))
  $Preserved = $true
  foreach ($File in $Histories) { if ((Get-FileHash -Algorithm SHA256 $File.FullName).Hash -ne $HistoryHashes[$File.FullName]) { $Preserved = $false } }
  Check 'upgrade_and_uninstall_preserve_private_history' $Preserved
  $Completed = $true
} finally {
  $env:Path = $OriginalPath
  if ($App -and !$App.HasExited) { $App.Kill(); $App.WaitForExit() }
  # Retain logs and private profiles on failure; never remove user history or OS credentials.
  @{ passed=($Completed -and @($Checks | Where-Object { !$_.passed }).Count -eq 0); checks=$Checks } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $Output 'results.json')
}
