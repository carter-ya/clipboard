param([string]$Source = (Join-Path $PSScriptRoot 'probe-environment.ps1'))
$ErrorActionPreference = 'Stop'
# Execute actual preparation statements with private fake providers only.
# Hard-kill the retained child while a fake capability call is blocked: finally
# cannot rescue a receipt at this boundary. No desktop or native APIs are used.
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$executable = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-environment-receipt-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$completed = 0
try {
  foreach ($case in @('query', 'install', 'client-profile', 'server-profile-refused', 'profile-without-prepare-refused')) {
    $folder = Join-Path $root $case
    New-Item -ItemType Directory -Path $folder | Out-Null
    $output = Join-Path $folder 'receipt.json'
    $marker = Join-Path $folder 'blocked'
    $trace = Join-Path $folder 'trace.json'
    $code = @'
$ErrorActionPreference = 'Stop'
$SourcePath = '__SOURCE__'
$Output = '__OUTPUT__'
$Marker = '__MARKER__'
$Trace = '__TRACE__'
$Case = '__CASE__'
$Prepare = $Case -ne 'profile-without-prepare-refused'
$ProfileOnly = $Case -notin @('query', 'install')
$script:profileSetCalls = 0
$script:featureCalls = 0
Add-Type -TypeDefinition @"
using System;
using System.Globalization;
public static class ClipboardInputEnvironment {
  public static int GetSystemMetrics(int index) { return 1; }
  public static uint GetDpiForSystem() { return 96; }
}
namespace Windows.Forms {
  public class InputLanguage {
    public CultureInfo Culture;
    public static InputLanguage[] InstalledInputLanguages { get {
      return new[] { new InputLanguage { Culture = new CultureInfo("en-US") },
        new InputLanguage { Culture = new CultureInfo("zh-CN") } };
    } }
  }
}
"@
function Get-CimInstance {
  param($ClassName, $Property)
  $kind = if ($Case -in @('query', 'install', 'server-profile-refused')) { 3 } else { 1 }
  [PSCustomObject]@{ Caption = 'Synthetic Windows'; ProductType = $kind; OSArchitecture = 'fixture-64' }
}
function Get-WindowsCapability {
  param([switch]$Online, [string]$Name)
  $script:featureCalls++
  if ($Case -eq 'query') { [IO.File]::WriteAllText($Marker, 'query'); Start-Sleep -Seconds 300 }
  if ($Case -notin @('query', 'install')) { throw 'profile_only_must_not_query_features' }
  [PSCustomObject]@{ Name = $Name; State = 'NotPresent' }
}
function Add-WindowsCapability {
  param([switch]$Online, [string]$Name)
  $script:featureCalls++
  if ($Case -ne 'install') { throw 'unexpected_feature_install' }
  [IO.File]::WriteAllText($Marker, 'install'); Start-Sleep -Seconds 300
}
function Get-WinUserLanguageList {
  $list = New-Object 'System.Collections.Generic.List[object]'
  $list.Add([PSCustomObject]@{ LanguageTag = 'en-US'; InputMethodTips = @('0409:00000409') })
  if ($script:profileSetCalls) { $list.Add([PSCustomObject]@{ LanguageTag = 'zh-CN'; InputMethodTips = @('0804:fixture') }) }
  return ,$list
}
function Set-WinUserLanguageList { param($LanguageList, [switch]$Force); $script:profileSetCalls++ }
function Get-Service { [CmdletBinding()]param([string[]]$Name); return }
function Test-Path { param($LiteralPath, $PathType); return $false }
function Start-Process { throw 'fixture_must_not_start_a_native_broker' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'actual_probe_parse_failed' }
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
      $statement.Left.Extent.Text -in @('$report', '$report.inputServices', '$report.ctfMonitorRequested')) {
    Invoke-Expression $statement.Extent.Text
  }
  if ($statement -is [Management.Automation.Language.FunctionDefinitionAst] -and $statement.Name -eq 'Write-EnvironmentReceipt') {
    Invoke-Expression $statement.Extent.Text
  }
}
$try = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($try.Count -ne 1) { throw 'actual_probe_try_missing' }
Invoke-Expression $try[0].Extent.Text
@{ profileSetCalls = $script:profileSetCalls; featureCalls = $script:featureCalls } | ConvertTo-Json | Out-File -Encoding UTF8 -LiteralPath $Trace
'@
    foreach ($pair in @(@('__SOURCE__', $sourcePath), @('__OUTPUT__', $output), @('__MARKER__', $marker), @('__TRACE__', $trace), @('__CASE__', $case))) {
      $code = $code.Replace($pair[0], $pair[1].Replace("'", "''"))
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    $stdout = $child.StandardOutput.ReadToEndAsync(); $stderr = $child.StandardError.ReadToEndAsync()
    try {
      if ($case -in @('query', 'install')) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (!(Test-Path -LiteralPath $marker)) {
          if ($child.HasExited) { throw ('fake_provider_exited_' + $stderr.Result) }
          if ([DateTime]::UtcNow -ge $deadline) { throw 'fake_provider_marker_timeout' }
          Start-Sleep -Milliseconds 50
        }
        $child.Kill()
        if (!$child.WaitForExit(5000)) { throw 'owned_fake_provider_not_reaped' }
      } elseif (!$child.WaitForExit(15000)) { throw 'fake_profile_timeout' }
      if (!(Test-Path -LiteralPath $output)) { throw ('environment_timeout_loses_receipt_' + $case) }
      $data = Get-Content -Raw -LiteralPath $output | ConvertFrom-Json
      if ($data.provisioningComplete -or $data.imeCompositionPassed -or $data.candidateSelectionPassed) {
        throw ('receipt_must_not_claim_unverified_feature_or_input_' + $case)
      }
      if ($case -in @('query', 'install', 'client-profile') -and
          ($data.osCaption -cne 'Synthetic Windows' -or $data.osArchitecture -cne 'fixture-64')) { throw ('receipt_loses_read_OS_metadata_' + $case) }
      if ($case -in @('query', 'install')) {
        $expected = if ($case -eq 'query') { 'query_chinese_typing_capability' } else { 'install_chinese_typing_capability' }
        if ($data.stage -cne $expected) { throw ('blocked_stage_not_retained_' + $case) }
      } else {
        $calls = Get-Content -Raw -LiteralPath $trace | ConvertFrom-Json
        if ($calls.featureCalls -ne 0) { throw ('profile_only_touched_capability_provider_' + $case) }
        if ($case -eq 'client-profile') {
          if ($data.errorType -or !$data.profileConfigurationComplete -or $calls.profileSetCalls -ne 1 -or $data.stage -cne 'profile_only_complete') { throw 'client_profile_only_not_configured' }
        } elseif (!$data.errorType -or $calls.profileSetCalls -ne 0) { throw ('unsupported_profile_only_must_refuse_without_mutation_' + $case) }
      }
      $completed++
    } finally {
      if (!$child.HasExited) { $child.Kill(); $child.WaitForExit() }
      $child.Dispose()
    }
  }
} finally {
  Remove-Item -Recurse -Force -LiteralPath $root
}
Write-Host ('Actual environment preparation passes ' + $completed + ' private provider/termination cases without native APIs')
