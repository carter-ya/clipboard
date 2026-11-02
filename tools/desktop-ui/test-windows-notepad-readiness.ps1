# Execute the actual acceptance identity gate with fake retained processes.
# No process launch, clipboard, desktop, input APIs or sleeps are involved.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'windows-notepad-acceptance.ps1'
. $source
$expected = '/owned/System32/notepad.exe'
$script:waitCalls = 0
function Wait-For([scriptblock]$Predicate, [string]$Stage, [int]$Seconds) {
  if ($Seconds -ne 10) { throw 'identity_readiness_deadline_must_remain_bounded' }
  for ($i = 0; $i -lt 3; $i++) {
    $script:waitCalls++
    try { $value = & $Predicate; if ($value) { return $value } } catch { }
  }
  throw ('timeout_' + $Stage)
}
function New-FakeProcess([object[]]$Paths, [bool]$Exited = $false) {
  $process = [PSCustomObject]@{ Paths = $Paths; Observations = 0; HasExited = $Exited }
  $process | Add-Member ScriptMethod Refresh {
    $this.Observations++
    if ($this.Paths[0] -ceq 'throw') { throw 'synthetic_process_query_failure' }
  }
  $process | Add-Member ScriptProperty MainModule {
    $index = [Math]::Max(0, [Math]::Min($this.Paths.Count - 1, $this.Observations - 1))
    $path = $this.Paths[$index]
    if ($null -eq $path) { return $null }
    return [PSCustomObject]@{ FileName = $path }
  }
  return $process
}
function Invoke-ActualGate($Process) {
  if (Get-Command Wait-OwnedNotepadIdentity -ErrorAction SilentlyContinue) {
    Wait-OwnedNotepadIdentity $Process $expected
  } else {
    # Before-fix proof: execute the original guard, extracted from its AST.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    $guards = @($ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains("throw 'notepad_spawned_process_identity_mismatch'")
    }, $true))
    if ($errors.Count -or $guards.Count -ne 1) { throw 'actual_identity_gate_missing' }
    $notepad = $Process
    $notepadExecutable = $expected
    Invoke-Expression $guards[0].Extent.Text
  }
}
$script:checks = 0
function Assert-Gate([object[]]$Paths, [string]$Failure, [int]$Reads, [bool]$Exited = $false) {
  $script:waitCalls = 0
  $process = New-FakeProcess $Paths $Exited
  $actual = ''
  try { Invoke-ActualGate $process } catch { $actual = $_.Exception.Message }
  if ($actual -cne $Failure) { throw ('unexpected_identity_result_expected_' + $Failure + '_actual_' + $actual) }
  if ($script:waitCalls -ne $Reads) { throw 'identity_gate_must_not_retry_wrong_or_exited_processes' }
  $script:checks++
}
Assert-Gate @($null, $expected) $null 2
Assert-Gate @($expected) $null 1
Assert-Gate @($expected.ToUpperInvariant()) $null 1
Assert-Gate @('/unrelated/editor.exe', $expected) 'notepad_spawned_process_identity_mismatch' 1
Assert-Gate @($null) 'timeout_notepad_spawned_process_identity_ready' 3
Assert-Gate @('', $expected) $null 2
Assert-Gate @($expected) 'owned_notepad_exited_before_identity' 1 $true
Assert-Gate @('throw', $expected) 'owned_notepad_identity_unreadable' 1
Write-Host ('Actual owned Notepad identity gate passes ' + $script:checks + ' readiness/fail-closed checks')
