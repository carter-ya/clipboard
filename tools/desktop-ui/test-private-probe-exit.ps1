param([string]$ProbePath = (Join-Path $PSScriptRoot 'smoke-windows.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$source = [IO.File]::ReadAllText($ProbePath)
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'native_probe_source_invalid' }
$outer = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally -and
    $_.Finally.Extent.Text.Contains('private_model_fixture_cleanup_complete')
})
if ($outer.Count -ne 1) { throw 'native_probe_cleanup_missing_or_ambiguous' }
$tail = $source.Substring($outer[0].Extent.EndOffset)
$modeReturns = @{}
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($mode in @('ModelSettingsOnly', 'KeyboardOnly', 'LocalTextOnly', 'ModelOperationsOnly', 'LocalFileModelsOnly')) {
  if ($mode -notin $parameters) { continue }
  $branches = @($outer[0].Body.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst]
  }, $true))
  $returns = @(
    foreach ($branch in $branches) {
      foreach ($clause in $branch.Clauses) {
        if ($clause.Item1.Extent.Text.Trim() -ceq ('$' + $mode) -and
            $clause.Item2.Statements.Count -gt 0 -and
            $clause.Item2.Statements[-1] -is [Management.Automation.Language.ReturnStatementAst]) {
          $clause.Item2.Statements[-1].Extent.Text
        }
      }
    }
  )
  if ($returns.Count -ne 1) { throw 'native_probe_mode_return_missing_or_ambiguous' }
  $modeReturns[$mode] = $returns[0]
}
if (!$modeReturns.ContainsKey('LocalTextOnly')) { throw 'native_local_text_return_missing' }
$ownedRoot = Join-Path ([IO.Path]::GetTempPath()) ('private-probe-exit-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $ownedRoot) { throw 'private_probe_exit_root_exists' }
[IO.Directory]::CreateDirectory($ownedRoot) | Out-Null
$results = New-Object 'System.Collections.Generic.List[object]'
$child = $null
try {
  foreach ($mode in ($modeReturns.Keys | Sort-Object)) {
    foreach ($failCleanup in @($false, $true)) {
      $caseRoot = Join-Path $ownedRoot ($mode + '-' + [int]$failCleanup)
      $fixtureRoot = Join-Path $caseRoot 'fixture'
      $reportDirectory = Join-Path $caseRoot 'report'
      [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
      [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
      [IO.File]::WriteAllText((Join-Path $fixtureRoot 'synthetic.txt'), 'Public synthetic cleanup fixture')
      $prefix = @'
param([string]$FixtureRoot, [string]$ReportDirectory, [switch]$FailCleanup)
$ErrorActionPreference = 'Stop'
$checks = New-Object 'System.Collections.Generic.List[object]'
$checks.Add(@{ name = 'synthetic_mode_completed'; passed = $true })
$application = $null
$OutputDirectory = $ReportDirectory
$ownsPrivateTextRoot = $true
$privateTextRoot = $FixtureRoot
if ($FailCleanup) {
  function Remove-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    if ($LiteralPath -cne $privateTextRoot) { throw 'unexpected_cleanup_target' }
    throw 'synthetic_owned_cleanup_failure'
  }
}
'@
      # Execute the real mode return, full cleanup/report block and script tail.
      # Only native UI setup is replaced; no copy of the exit decision is tested.
      $caseSource = $prefix + "`ntry {`n" + $modeReturns[$mode] + "`n} finally " +
        $outer[0].Finally.Extent.Text + "`n" + $tail
      $caseScript = Join-Path $caseRoot 'probe-exit.ps1'
      [IO.File]::WriteAllText($caseScript, $caseSource, [Text.UTF8Encoding]::new($false))
      $info = New-Object Diagnostics.ProcessStartInfo
      $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
      $info.Arguments = '-NoProfile -File "' + $caseScript + '" -FixtureRoot "' + $fixtureRoot +
        '" -ReportDirectory "' + $reportDirectory + '"'
      if ($failCleanup) { $info.Arguments += ' -FailCleanup' }
      $info.UseShellExecute = $false
      $info.RedirectStandardOutput = $true
      $info.RedirectStandardError = $true
      $child = [Diagnostics.Process]::Start($info)
      $stdout = $child.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
      $stderr = $child.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
      if (!$child.WaitForExit(30000)) { throw 'private_probe_exit_child_timeout' }
      $child.WaitForExit()
      if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw 'private_probe_exit_output_timeout' }
      $report = [IO.File]::ReadAllText((Join-Path $reportDirectory 'results.json')) | ConvertFrom-Json
      $cleanup = @($report.checks | Where-Object { $_.name -ceq 'private_model_fixture_cleanup_complete' })
      $expectedExit = [int]$failCleanup
      $valid = $cleanup.Count -eq 1 -and $cleanup[0].passed -eq (!$failCleanup) -and
        $report.passed -eq (!$failCleanup) -and $child.ExitCode -eq $expectedExit -and
        (Test-Path -LiteralPath $fixtureRoot) -eq $failCleanup
      $results.Add(@{ mode = $mode; cleanupFailure = $failCleanup; exitCode = $child.ExitCode;
        reportPassed = $report.passed; passed = [bool]$valid })
      $child.Dispose()
      $child = $null
    }
  }
  $results.ToArray() | ConvertTo-Json -Depth 3 | Write-Output
  if (@($results | Where-Object { !$_.passed }).Count) { throw 'private_probe_exit_contract_failed' }
} finally {
  if ($child) {
    if (!$child.HasExited) { $child.Kill(); $child.WaitForExit() }
    $child.Dispose()
  }
  # The injected failure belongs only to the child; remove our exact owned root.
  Remove-Item -LiteralPath $ownedRoot -Recurse -Force
}
