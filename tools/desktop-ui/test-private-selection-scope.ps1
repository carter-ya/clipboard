$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'smoke-windows.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'native_probe_syntax_failed' }
foreach ($functionName in @('Wait-For', 'Select-ThroughQuery', 'Set-LocalTextSearch')) {
  $definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
  }, $true))
  if ($definitions.Count -ne 1) { throw 'native_probe_function_not_unique' }
  Invoke-Expression $definitions[0].Extent.Text
}
# Execute the actual helpers with private control substitutes. No Windows APIs,
# real clipboard or input events are used. Any missed predicate fails immediately.
$script:application = $null
$script:sensitiveProbe = $false
$script:fixtureQuery = ''
function Set-Search([string]$Query) { $script:fixtureQuery = $Query }
function Find-Named([string]$ControlName) {
  if ($script:fixtureQuery) {
    return $ControlName -ceq '1 items' -or $ControlName -ceq $script:fixtureQuery
  }
  return $ControlName -ceq '6 items'
}
function Start-Sleep { throw 'query_predicate_missed_expected_control' }
Select-ThroughQuery 'Selection E' 6
if ($script:fixtureQuery -cne '') { throw 'query_was_not_cleared' }
Select-ThroughQuery 'Selection C' 6
if ($script:fixtureQuery -cne '') { throw 'second_query_was_not_cleared' }
Write-Host 'Actual selection predicates retain their caller values across the wait helper'

# Both old and new queries have one result. ValuePattern acknowledges the edit
# before the asynchronous history refresh publishes its selected preview.
$script:selectionRefreshes = 0
$script:expectedPreview = 'Other synthetic item for checking per-item progress.'
function Get-EditorWithValue([string]$Value) { return $Value -ceq $script:fixtureQuery }
function Find-Named([string]$ControlName) {
  return $ControlName -ceq '1 items' -or
    ($ControlName -ceq $script:expectedPreview -and $script:selectionRefreshes -ge 2)
}
function Start-Sleep { $script:selectionRefreshes++ }
Set-LocalTextSearch 'Other synthetic item' $script:expectedPreview
if ($script:selectionRefreshes -ne 2) { throw 'local_text_query_returned_before_selected_preview' }

# The return trip to the running item must establish its own selection too.
$script:selectionRefreshes = 0
$script:expectedPreview = 'Synthetic original item with a held generation request.'
Set-LocalTextSearch 'Synthetic original item' $script:expectedPreview
if ($script:selectionRefreshes -ne 2) { throw 'local_text_return_query_reused_stale_selection' }
Write-Host 'Local text queries wait for the selected native preview when counts stay unchanged'
