param([Parameter(Mandatory=$true)][string]$FixturePython)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private-fixture-python.ps1')
# Command discovery can return one match per PATH entry on Linux. Keep the
# executable chosen by normal PATH precedence, rather than returning an array.
function Get-Command {
  [CmdletBinding()]
  param([string]$Name, [string]$CommandType)
  [pscustomobject]@{ Source = $FixturePython }
  [pscustomobject]@{ Source = $FixturePython }
}
try {
  $discovered = Resolve-PrivateFixturePython ''
  if ($discovered -isnot [string] -or $discovered -cne [IO.Path]::GetFullPath($FixturePython)) {
    throw 'multiple_fixture_matches_were_not_reduced_to_first'
  }
} finally { Remove-Item Function:Get-Command }
$fixtureSavedPath = $env:PATH
$fixtureIsolatedPath = Join-Path ([IO.Path]::GetTempPath()) ('no-fixture-tools-' + [Guid]::NewGuid().ToString('N'))
$fixtureProcess = $null
try {
  # A nonexistent PATH entry cannot supply development DLLs or interpreters.
  $env:PATH = $fixtureIsolatedPath
  $resolved = Resolve-PrivateFixturePython $FixturePython
  $missingRejected = $false
  try { $null = Resolve-PrivateFixturePython 'missing-relative-fixture-python' }
  catch { $missingRejected = $true }
  if (!$missingRejected) { throw 'relative_fixture_runtime_was_accepted' }
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = $resolved
  $info.Arguments = '"' + (Join-Path $PSScriptRoot 'ai-probe-server.py') + '"'
  $info.UseShellExecute = $false
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.EnvironmentVariables['CLIPBOARD_PRIVATE_AI_TEST'] = '1'
  $info.EnvironmentVariables['CLIPBOARD_PRIVATE_AI_MODE'] = ''
  $fixtureProcess = [Diagnostics.Process]::Start($info)
  $fixtureErrorDrain = $fixtureProcess.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
  $ready = $fixtureProcess.StandardOutput.ReadLineAsync()
  if (!$ready.Wait(10000) -or $ready.Result -notmatch '^ready:[0-9]+$') { throw 'isolated_fixture_runtime_not_ready' }
  $fixtureProcess.StandardInput.Close()
  if (!$fixtureProcess.WaitForExit(10000)) { throw 'isolated_fixture_runtime_quit_timeout' }
  $report = $fixtureProcess.StandardOutput.ReadLineAsync()
  if (!$report.Wait(5000)) { throw 'isolated_fixture_runtime_report_timeout' }
  $audit = $report.Result | ConvertFrom-Json
  if ($fixtureProcess.ExitCode -ne 0 -or $audit.requests -ne 0 -or !$audit.fixedTestsOnly -or
      !$audit.noAuthorization -or !$audit.noCookies -or $env:PATH -cne $fixtureIsolatedPath) {
    throw 'isolated_fixture_runtime_audit_failed'
  }
  Write-Host 'Private fixture runs with an isolated PATH'
} finally {
  if ($fixtureProcess) {
    if (!$fixtureProcess.HasExited) { $fixtureProcess.Kill(); $fixtureProcess.WaitForExit() }
    $fixtureProcess.Dispose()
  }
  $env:PATH = $fixtureSavedPath
}
