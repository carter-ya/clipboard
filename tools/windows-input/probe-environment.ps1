param([switch]$Prepare, [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') {
  throw 'input_environment_requires_owned_windows_actions_runner'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipboardInputEnvironment {
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
'@
$report = [ordered]@{
  mode = $(if ($Prepare) { 'prepare' } else { 'inspect' });
  osBuild = [Environment]::OSVersion.Version.ToString();
  monitorCount = [ClipboardInputEnvironment]::GetSystemMetrics(80);
  primaryWidth = [ClipboardInputEnvironment]::GetSystemMetrics(0);
  primaryHeight = [ClipboardInputEnvironment]::GetSystemMetrics(1);
  systemDpi = [ClipboardInputEnvironment]::GetDpiForSystem();
  remoteSession = [ClipboardInputEnvironment]::GetSystemMetrics(0x1000) -ne 0;
  basicTypingStateBefore = 'unknown'; basicTypingStateAfter = 'unknown'; restartNeeded = $false;
  chineseInputProfileCount = 0; inputLanguages = @(); provisioningComplete = $false;
  imeCompositionPassed = $false; candidateSelectionPassed = $false;
  notes = @('Environment inventory/provisioning is not an IME composition or candidate test.',
    'This inventory/provisioning step does not send keys, access clipboard, sleep, change displays or restart.');
  errorType = $null; errorCode = $null
}
$report.inputServices = @()
$report.ctfMonitorRequested = $false
try {
  $capabilityName = 'Language.Basic~~~zh-CN~0.0.1.0'
  $capability = Get-WindowsCapability -Online -Name $capabilityName
  if (!$capability -or $capability.Name -cne $capabilityName) { throw 'chinese_basic_typing_capability_unavailable' }
  $report.basicTypingStateBefore = [string]$capability.State
  if ($Prepare -and $capability.State -ne 'Installed') {
    # This modifies only this disposable Actions VM. Never restart the runner.
    # Server Chinese dictionaries require the basic typing FOD:
    # https://learn.microsoft.com/en-us/troubleshoot/windows-server/setup-upgrade-and-drivers/chinese-ime-dictionaries-not-ready
    $installation = Add-WindowsCapability -Online -Name $capabilityName
    $report.restartNeeded = [bool]$installation.RestartNeeded
  }
  $report.basicTypingStateAfter = [string](Get-WindowsCapability -Online -Name $capabilityName).State
  if ($Prepare -and $report.basicTypingStateAfter -eq 'Installed' -and !$report.restartNeeded) {
    $languages = Get-WinUserLanguageList
    if (!($languages | Where-Object { $_.LanguageTag -eq 'zh-CN' })) {
      $languages.Add('zh-CN')
      Set-WinUserLanguageList -LanguageList $languages -Force
    }
    foreach ($name in @('TextInputManagementService', 'TabletInputService')) {
      $service = Get-Service -Name $name -ErrorAction SilentlyContinue
      if ($service) {
        if ($service.StartType -eq 'Disabled') { Set-Service -Name $name -StartupType Manual }
        if ($service.Status -ne 'Running') { Start-Service -Name $name }
      }
    }
    $brokerPath = Join-Path ([Environment]::GetFolderPath('System')) 'ctfmon.exe'
    if (Test-Path -LiteralPath $brokerPath -PathType Leaf) {
      $broker = Start-Process -FilePath $brokerPath -PassThru
      $report.ctfMonitorRequested = $true
      $broker.Dispose()
    }
  }
  $languages = @(Get-WinUserLanguageList)
  $report.chineseInputProfileCount = @($languages | Where-Object {
    $_.LanguageTag -like 'zh-*' -and $_.InputMethodTips.Count -gt 0
  }).Count
  $report.inputLanguages = @([Windows.Forms.InputLanguage]::InstalledInputLanguages | ForEach-Object {
    $_.Culture.Name
  } | Sort-Object -Unique)
  $report.inputServices = @(Get-Service -Name 'TextInputManagementService', 'TabletInputService' -ErrorAction SilentlyContinue |
    ForEach-Object { @{ name = $_.Name; state = [string]$_.Status; startup = [string]$_.StartType } })
  $report.provisioningComplete = $report.basicTypingStateAfter -eq 'Installed' -and
    !$report.restartNeeded -and $report.chineseInputProfileCount -gt 0
} catch {
  $report.errorType = $_.Exception.GetType().FullName
  $report.errorCode = $_.Exception.HResult
} finally {
  $report | ConvertTo-Json -Depth 4 | Out-File -Encoding UTF8 -LiteralPath $Output
}
if ($report.errorType -or ($Prepare -and !$report.provisioningComplete)) {
  throw 'windows_input_environment_not_ready_see_content_free_report'
}
