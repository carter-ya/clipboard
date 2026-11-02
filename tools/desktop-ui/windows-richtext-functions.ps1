# Shared native reference and product receiver assertions; never populate a document.
. (Join-Path $PSScriptRoot 'windows-browser-functions.ps1')
function Initialize-WindowsRichTextFixture {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'richtext_fixture_requires_windows_actions' }
  Add-Type -AssemblyName System.Windows.Forms
  if (!('ClipboardOwnedRichText' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'windows-richtext-fixture.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
  }
  if (!('ClipboardKeyboardFixture' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'windows-keyboard-fixture.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
  }
}
function Assert-WindowsRichTextPaste($Receiver, $Keys) {
  Wait-BrowserCondition {
    $value = $Receiver.Read()
    if ($value.Text -ceq $Receiver.ExpectedText -and $value.ScannedPasteKeys -eq 1) { $value }
  } 'native_rtf_actual_ctrl_v_preserves_complete_unicode_and_newline' | Out-Null
  # Selection is established only by actual keys. Native observations never
  # change the document, selection, styles or focus.
  $Keys.Chord($Receiver.Handle, [UInt16[]]@(0x11, 0x24))
  for ($index = 0; $index -lt 4; $index++) { $Keys.Chord($Receiver.Handle, [UInt16[]]@(0x27)) }
  for ($index = 0; $index -lt 7; $index++) { $Keys.Chord($Receiver.Handle, [UInt16[]]@(0x10, 0x27)) }
  $bold = Wait-BrowserCondition {
    $value = $Receiver.Read()
    if ($value.SelectedText -ceq 'fixture' -and $value.SelectionStart -eq 4 -and $value.SelectionLength -eq 7) { $value }
  } 'native_rtf_actual_keys_select_bold_run'
  if (!$bold.HasSingleFont -or !$bold.Bold -or $bold.Italic -or $bold.Color -ne 0xdc143c -or
      !([Math]::Abs($bold.Points - 12) -lt 0.01)) { throw 'native_rtf_bold_color_or_size_mismatch' }
  $Keys.Chord($Receiver.Handle, [UInt16[]]@(0x11, 0x23))
  $Keys.Chord($Receiver.Handle, [UInt16[]]@(0x10, 0x24))
  $italic = Wait-BrowserCondition {
    $value = $Receiver.Read()
    if ($value.SelectedText -ceq 'second line') { $value }
  } 'native_rtf_actual_keys_select_italic_run'
  if (!$italic.HasSingleFont -or !$italic.Italic -or $italic.Bold -or $italic.Text -cne $Receiver.ExpectedText) {
    throw 'native_rtf_distinct_italic_run_or_original_text_mismatch'
  }
  return @{ unicode = $true; boldColorSize = $true; distinctItalic = $true; scannedPasteKeys = $italic.ScannedPasteKeys }
}
function Get-WindowsRichTextDiagnostic($Receiver) {
  if (!$Receiver -or $Receiver.Stopped) { return @{ unavailable = $true } }
  $value = $Receiver.Read()
  return @{ textLength = $value.Text.Length; expectedLength = $Receiver.ExpectedText.Length;
    textMatches = $value.Text -ceq $Receiver.ExpectedText; focused = $value.Focused;
    scannedPasteKeys = $value.ScannedPasteKeys; nativePasteMessages = $value.PasteMessages;
    selectionStart = $value.SelectionStart; selectionLength = $value.SelectionLength;
    selectedBoldRun = $value.SelectedText -ceq 'fixture'; selectedItalicRun = $value.SelectedText -ceq 'second line';
    hasSingleFont = $value.HasSingleFont; bold = $value.Bold; italic = $value.Italic;
    points = $value.Points; color = $value.Color }
}
