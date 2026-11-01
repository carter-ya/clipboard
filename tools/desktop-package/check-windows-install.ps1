param([Parameter(Mandatory=$true)][string]$Installer,
      [Parameter(Mandatory=$true)][string]$Output,
      [Parameter(Mandatory=$true)][string]$Probe,
      [Parameter(Mandatory=$true)][string]$ClipboardPeer,
      [Parameter(Mandatory=$true)][string]$OCRFixture,
      [string]$SummaryModel,
      [string]$EntityModel,
      [string]$ModelDefinitions)
$ErrorActionPreference = 'Stop'
if (($SummaryModel -or $EntityModel -or $ModelDefinitions) -and !($SummaryModel -and $EntityModel -and $ModelDefinitions)) {
  throw 'All actual-model fixture paths are required together'
}
if ($SummaryModel) {
  $SummaryModel = [IO.Path]::GetFullPath($SummaryModel)
  $EntityModel = [IO.Path]::GetFullPath($EntityModel)
  $ModelDefinitions = [IO.Path]::GetFullPath($ModelDefinitions)
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:CLIPBOARD_PRIVATE_INSTALL_TEST -ne '1') {
  throw 'Installer integration tests require an isolated GitHub Actions desktop'
}
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory($Output) | Out-Null
$Installer = [IO.Path]::GetFullPath($Installer)
$Root = Join-Path $env:RUNNER_TEMP ('clipboard-install-' + [Guid]::NewGuid().ToString('N'))
$Installed = Join-Path $Root 'install 中文 space'
$Executable = Join-Path $Installed 'bin/ClipboardDesktop.exe'
$RunSubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$RunKey = 'HKCU:\' + $RunSubKey
$RunName = 'com.clipboard.desktop'
function Read-StartupCommand {
  # The registry API returns null for an absent value. Get-ItemPropertyValue
  # can throw a terminating provider error even with SilentlyContinue.
  $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunSubKey)
  if ($null -eq $Key) { return $null }
  try { return $Key.GetValue($RunName, $null) }
  finally { $Key.Dispose() }
}
$OriginalRun = Read-StartupCommand
if ($null -ne $OriginalRun) { throw 'Refusing an existing Clipboard startup registration' }
$Checks = [Collections.Generic.List[object]]::new()
$App = $null
$Completed = $false
$OriginalPath = $env:Path
# Resolve the test-only interpreter before excluding development paths. Pass it
# directly to the fixture; never add its directory to the application PATH.
$FixturePython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
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
  & $FixturePython (Join-Path (Split-Path ([IO.Path]::GetFullPath($Probe))) 'check-local-model-runtime.py') --directory (Join-Path $Installed 'bin')
  Check 'installed_local_text_workers_and_offline_notices_without_optional_weights' ($LASTEXITCODE -eq 0)
  $ImageInfo = New-Object Diagnostics.ProcessStartInfo
  $ImageInfo.FileName = Join-Path $Installed 'bin/clipboard-image-worker.exe'
  $ImageInfo.UseShellExecute = $false
  $ImageInfo.CreateNoWindow = $true
  $ImageInfo.RedirectStandardInput = $true
  $ImageInfo.RedirectStandardOutput = $true
  $ImageInfo.RedirectStandardError = $true
  $ImageProcess = [Diagnostics.Process]::Start($ImageInfo)
  try {
    $ImageErrorDrain = $ImageProcess.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $ImageBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGPQyLvznxLMMGrAqAGjBgwXAwBc3HEfVZuzFAAAAABJRU5ErkJggg==')
    $ImageProcess.StandardInput.BaseStream.Write($ImageBytes, 0, $ImageBytes.Length)
    $ImageProcess.StandardInput.BaseStream.Close()
    if (!$ImageProcess.WaitForExit(15000)) { $ImageProcess.Kill(); throw 'installed_image_worker_timeout' }
    $ImageOutput = $ImageProcess.StandardOutput.ReadToEnd()
    $ImageMetadata = $null
    if ([Text.Encoding]::UTF8.GetByteCount($ImageOutput) -le 4096) {
      try { $ImageMetadata = $ImageOutput | ConvertFrom-Json } catch { $ImageMetadata = $null }
    }
    Check 'installed_image_classifier_works_with_bundled_runtime' ($ImageProcess.ExitCode -eq 0 -and
      $null -ne $ImageMetadata -and $ImageMetadata.width -eq 16 -and $ImageMetadata.height -eq 16 -and
      $ImageMetadata.labels -is [Array] -and @($ImageMetadata.labels).Count -le 3)
  } finally {
    if (!$ImageProcess.HasExited) { $ImageProcess.Kill(); $ImageProcess.WaitForExit() }
    $ImageProcess.Dispose()
  }
  $ImageNotices = Join-Path $Installed 'share/licenses/image-model'
  $ImageProvenance = Get-Content -Raw (Join-Path $ImageNotices 'provenance.json') | ConvertFrom-Json
  $MissingImageNotices = @('onnxruntime-LICENSE','onnxruntime-ThirdPartyNotices.txt','MODELS-LICENSE','MODEL-README.md','synset.txt') |
    Where-Object { !(Test-Path (Join-Path $ImageNotices $_)) }
  Check 'installed_image_model_keeps_verified_provenance_and_notices' ($ImageProvenance.cpu_only -and
    $ImageProvenance.model_embedded -and $ImageProvenance.reference_tensor_verified -and
    $ImageProvenance.preprocessing_reference_verified -and @($MissingImageNotices).Count -eq 0)
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
  $RunningUninstaller = Start-Process -FilePath (Join-Path $Installed 'unins000.exe') `
    -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -PassThru
  if (!$RunningUninstaller.WaitForExit(30000)) { $RunningUninstaller.Kill(); throw 'Running-app uninstall guard timeout' }
  Check 'running_application_blocks_silent_uninstall' ($RunningUninstaller.ExitCode -ne 0 -and !$App.HasExited -and (Test-Path $Executable))
  # This process owns only an empty synthetic profile. Force exit verifies that
  # OS handle cleanup releases the installation mutex after an abrupt owner loss.
  $App.Kill()
  $App.WaitForExit()
  $App = $null
  # SwiftPM embeds a build-directory fallback. Hide only this CI build's own
  # resource bundles so an omitted installed OCR script cannot pass by accident.
  $HiddenResources = @{}
  try {
    Get-ChildItem (Split-Path ([IO.Path]::GetFullPath($ClipboardPeer))) -Directory | Where-Object {
      $_.Name.EndsWith('.resources') -or $_.Name.EndsWith('.bundle')
    } | ForEach-Object {
      $Hidden = $_.FullName + '.fixture-hidden-' + [Guid]::NewGuid().ToString('N')
      Move-Item -LiteralPath $_.FullName -Destination $Hidden
      $HiddenResources[$Hidden] = $_.FullName
    }
    & powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File $Probe -Executable $Executable `
      -ClipboardPeer $ClipboardPeer -OCRFixture $OCRFixture -FixturePython $FixturePython -LifecycleCycles 20 -OutputDirectory (Join-Path $Output 'ui')
    Check 'installed_gui_and_services_pass_with_bundled_runtime' ($LASTEXITCODE -eq 0)
    & powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File $Probe -Executable $Executable `
      -ModelSettingsOnly -OutputDirectory (Join-Path $Output 'model-settings')
    Check 'installed_model_settings_pass_native_consent_and_cancel_controls' ($LASTEXITCODE -eq 0)
    if ($SummaryModel) {
      & powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File $Probe -Executable $Executable `
        -ClipboardPeer $ClipboardPeer -LocalTextOnly -SummaryModel $SummaryModel -EntityModel $EntityModel `
        -ModelDefinitions $ModelDefinitions -OutputDirectory (Join-Path $Output 'local-text')
      Check 'installed_actual_local_models_pass_analysis_revocation_and_removal' ($LASTEXITCODE -eq 0)
    }
  } finally {
    foreach ($Hidden in $HiddenResources.Keys) {
      Move-Item -LiteralPath $Hidden -Destination $HiddenResources[$Hidden]
    }
  }
  $Histories = @(Get-ChildItem (Join-Path $Output 'ui') -Recurse -Filter history.json)
  Check 'installed_probe_persists_private_history' ($Histories.Count -gt 0)
  $HistoryHashes = @{}
  foreach ($File in $Histories) { $HistoryHashes[$File.FullName] = (Get-FileHash -Algorithm SHA256 $File.FullName).Hash }
  New-Item -Path $RunKey -Force | Out-Null
  $StartupCommand = '"' + $Executable + '" --background'
  New-ItemProperty -Path $RunKey -Name $RunName -Value $StartupCommand -PropertyType String -Force | Out-Null
  Check 'upgrade_preserves_runtime_and_startup_preference' ((Install-Package) -eq 0 -and (Read-StartupCommand) -eq $StartupCommand)
  $Uninstaller = Join-Path $Installed 'unins000.exe'
  $Uninstall = Start-Process -FilePath $Uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -PassThru
  if (!$Uninstall.WaitForExit(120000)) { $Uninstall.Kill(); throw 'Uninstaller timeout' }
  Check 'uninstall_removes_application_and_matching_startup' ($Uninstall.ExitCode -eq 0 -and !(Test-Path $Executable) -and
    $null -eq (Read-StartupCommand))
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
