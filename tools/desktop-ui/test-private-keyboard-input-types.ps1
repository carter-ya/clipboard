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

# GtkEntry selects its text on refocus. Execute the real post-refocus input
# statements against that selection state, rather than assuming a trailing caret.
$definitions = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-WindowsKeyboardAcceptance'
}, $true))
if ($definitions.Count -ne 1) { throw 'keyboard_acceptance_function_not_unique' }
$nativeTry = @($definitions[0].Body.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.TryStatementAst]
})
if ($nativeTry.Count -ne 1) { throw 'keyboard_acceptance_body_not_unique' }
$keyboardPeer | Add-Member NoteProperty Query ''
$keyboardPeer | Add-Member NoteProperty Selected $true
$keyboardPeer | Add-Member NoteProperty Caret 0
$keyboardPeer | Add-Member -Force ScriptMethod Chord {
  param([IntPtr]$Target, $Keys)
  if ($Target -ne [IntPtr]1 -or $Keys.GetType() -ne [UInt16[]] -or $Keys.Count -ne 1) { throw 'unexpected_refocus_input' }
  switch ($Keys[0]) {
    0x23 { $this.Caret = $this.Query.Length; $this.Selected = $false }
    0x08 {
      if ($this.Selected) { $this.Query = ''; $this.Caret = 0; $this.Selected = $false }
      elseif ($this.Caret -gt 0) { $this.Query = $this.Query.Remove($this.Caret - 1, 1); $this.Caret-- }
    }
    default { throw 'unexpected_refocus_key' }
  }
}
$keyboardPeer | Add-Member ScriptMethod TypeAscii {
  param([IntPtr]$Target, [string]$Text)
  if ($Target -ne [IntPtr]1) { throw 'unexpected_refocus_text_target' }
  if ($this.Selected) { $this.Query = $Text; $this.Caret = $Text.Length; $this.Selected = $false }
  else { $this.Query = $this.Query.Insert($this.Caret, $Text); $this.Caret += $Text.Length }
}
foreach ($case in @(
  @{ start = 'keyboard_settings_returns_search_focus'; end = 'keyboard_input_after_settings'; expected = ([string][char]0x4e2d + [char]0x6587 + 'a') },
  @{ start = 'keyboard_alt_f4_hotkey_restores_focus'; end = 'keyboard_edit_after_close_reopen'; expected = [string][char]0x4e2d }
)) {
  $keyboardPeer.Query = [string][char]0x4e2d + [char]0x6587
  $keyboardPeer.Caret = 0
  $keyboardPeer.Selected = $true
  $statements = $nativeTry[0].Body.Statements
  $start = -1; $end = -1
  for ($position = 0; $position -lt $statements.Count; $position++) {
    if ($statements[$position].Extent.Text.Contains($case.start)) { $start = $position }
    if ($statements[$position].Extent.Text.Contains($case.end)) { $end = $position }
  }
  if ($start -lt 0 -or $end -le $start + 1) { throw 'post_refocus_input_not_found' }
  for ($position = $start + 1; $position -lt $end; $position++) {
    Invoke-Expression $statements[$position].Extent.Text
  }
  if ($keyboardPeer.Query -cne $case.expected) { throw ('post_refocus_edit_replaced_selection_' + $case.start) }
}
Write-Host 'Actual post-refocus input establishes its caret before append/delete checks'
