$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'smoke-windows.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'native_probe_syntax_failed' }
$definitions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($definition in $ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
  $null = $definitions.Add($definition.Name)
}
$calls = 0
$localTextCalls = 0
$modelOperationCalls = 0
foreach ($command in $ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.CommandAst]
}, $true)) {
  $name = $command.GetCommandName()
  if ($name -and $name -like '*-LocalText*') {
    $localTextCalls++
    if (!$definitions.Contains($name)) { throw 'local_text_probe_helper_missing' }
  }
  if ($name -and $name -like '*-ModelOperation*') {
    $modelOperationCalls++
    if (!$definitions.Contains($name)) { throw 'model_operation_probe_helper_missing' }
  }
  if ($name -and $name.StartsWith('Invoke-Visible', [StringComparison]::OrdinalIgnoreCase)) {
    $calls++
    if (!$definitions.Contains($name)) { throw 'public_control_helper_missing' }
  }
}
if ($calls -lt 7) { throw 'public_control_fixture_calls_missing' }
Write-Host 'Every public visible-control call resolves to an actual probe helper'

if ($localTextCalls -lt 20) { throw 'local_text_fixture_calls_missing' }
Write-Host 'Every local text fixture call resolves to an actual probe helper'
if ($modelOperationCalls -lt 10) { throw 'model_operation_fixture_calls_missing' }
Write-Host 'Every model operation fixture call resolves to an actual probe helper'
