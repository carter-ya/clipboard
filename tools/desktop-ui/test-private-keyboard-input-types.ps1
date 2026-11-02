$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'windows-keyboard-acceptance.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'keyboard_acceptance_syntax_failed' }
$chords = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member.Value -ceq 'Chord' -and $node.Expression.Extent.Text -ieq '$keyboardPeer'
}, $true))
if ($chords.Count -lt 20) { throw 'keyboard_acceptance_chords_missing' }
# Evaluate every actual argument expression without Windows, a desktop or input
# APIs. Windows PowerShell 5.1 must resolve the same UInt16[] used by C#.
$nativeWindowHandle = [IntPtr]1
$keyboardPeer = [PSCustomObject]@{ Handle = [IntPtr]2 }
$script:checkedKeyboardBatches = 0
$keyboardPeer | Add-Member ScriptMethod Chord {
  param([IntPtr]$Target, $Keys)
  if ($Target -ne [IntPtr]1 -and $Target -ne [IntPtr]2) { throw 'unexpected_keyboard_fixture_target' }
  if ($Keys.GetType() -ne [UInt16[]] -or !$Keys.Count -or $Keys.Count -gt 3) { throw 'keyboard_chord_native_type_mismatch' }
  foreach ($key in $Keys) { if ($key -gt 0xff) { throw 'keyboard_virtual_key_out_of_range' } }
  $script:checkedKeyboardBatches++
}
foreach ($chord in $chords) { Invoke-Expression $chord.Extent.Text }
if ($script:checkedKeyboardBatches -ne $chords.Count) { throw 'keyboard_argument_check_incomplete' }
Write-Host ('Actual keyboard input batches resolve correctly: ' + $script:checkedKeyboardBatches)
