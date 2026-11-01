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
$fixturePdfDirectory = Join-Path ([IO.Path]::GetTempPath()) ('private pdf fixture-' + [Guid]::NewGuid().ToString('N'))
$fixtureOwnsPdfDirectory = $false
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
  # Execute the actual PDF invocation from the native probe, rather than a
  # second copy which could accidentally use a different interpreter path.
  $tokens = $null
  $errors = $null
  $probeAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'smoke-windows.ps1'), [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw 'native_pdf_fixture_source_invalid' }
  $pdfCalls = @($probeAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
      $node.Extent.Text -match 'pdf_fixture\.py' -and
      $node.Extent.Text -match '--private-summary-fixture'
  }, $true))
  if ($pdfCalls.Count -ne 1) { throw 'native_pdf_fixture_invocation_missing_or_ambiguous' }
  if ([IO.Directory]::Exists($fixturePdfDirectory)) { throw 'private_pdf_fixture_directory_exists' }
  [IO.Directory]::CreateDirectory($fixturePdfDirectory) | Out-Null
  $fixtureOwnsPdfDirectory = $true
  $pdf = Join-Path $fixturePdfDirectory ('summary ' + [char]0x4e2d + [char]0x6587 + '.pdf')
  $rootLiteral = "'" + $PSScriptRoot.Replace("'", "''") + "'"
  $pdfInvocation = $pdfCalls[0].Extent.Text.Replace('$PSScriptRoot', $rootLiteral)
  $pdfCommand = [scriptblock]::Create($pdfInvocation + "`nif (`$LASTEXITCODE -ne 0) { throw 'private_pdf_fixture_runtime_exit_failed' }")
  & $pdfCommand
  if (![IO.File]::Exists($pdf) -or (Get-Item -LiteralPath $pdf).Length -gt 65536) { throw 'private_pdf_fixture_not_created' }
  $pdfBytes = [IO.File]::ReadAllBytes($pdf)
  if ($pdfBytes.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($pdfBytes, 0, 5) -cne '%PDF-' -or
      $env:PATH -cne $fixtureIsolatedPath) { throw 'private_pdf_fixture_audit_failed' }
  Write-Host 'Actual native PDF fixture runs with the supplied interpreter and isolated PATH'
} finally {
  if ($fixtureProcess) {
    if (!$fixtureProcess.HasExited) { $fixtureProcess.Kill(); $fixtureProcess.WaitForExit() }
    $fixtureProcess.Dispose()
  }
  if ($fixtureOwnsPdfDirectory) { [IO.Directory]::Delete($fixturePdfDirectory, $true) }
  $env:PATH = $fixtureSavedPath
}
