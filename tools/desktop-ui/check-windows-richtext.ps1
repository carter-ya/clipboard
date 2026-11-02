param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'richtext_probe_requires_windows_actions' }
. (Join-Path $PSScriptRoot 'windows-browser-functions.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'windows-richtext-fixture.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
if (!('ClipboardKeyboardFixture' -as [type])) {
  Add-Type -Path (Join-Path $PSScriptRoot 'windows-keyboard-fixture.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
}
$receiver = $null
$keys = $null
$failure = $null
$cleanupFailure = $null
$diagnostic = $null
$stage = 'startup'
$checks = [Collections.Generic.List[object]]::new()
function Add-RtfCheck([string]$Name, [bool]$Passed) {
  $checks.Add(@{ name = $Name; passed = $Passed })
  if (!$Passed) { throw $Name }
}
try {
  $receiver = [ClipboardOwnedRichText]::new()
  $keys = [ClipboardKeyboardFixture]::new([uint32]$PID)
  $receiver.Activate()
  Wait-BrowserCondition { $receiver.Read().Focused } 'owned_richtext_foreground_and_focus' | Out-Null
  Add-RtfCheck 'native_rtf_recipient_initially_empty' ($receiver.Read().Text -ceq '')
  $stage = 'source'
  $receiver.WriteFixture()
  Wait-BrowserCondition { $receiver.SourceMatches() } 'native_rtf_source_bytes' | Out-Null
  Add-RtfCheck 'independent_rtf_writer_has_exact_native_ascii_and_unicode_escape_bytes' $true
  Add-RtfCheck 'native_rtf_source_write_does_not_populate_receiver' ($receiver.Read().Text -ceq '')
  $revision = $receiver.ClipboardRevision
  $stage = 'paste'
  $keys.Chord($receiver.Handle, [UInt16[]]@(0x11, 0x56))
  $receipt = Wait-BrowserCondition {
    $value = $receiver.Read()
    if ($value.Text -ceq $receiver.ExpectedText -and $value.ScannedPasteKeys -eq 1) { $value }
  } 'native_rtf_actual_ctrl_v_preserves_complete_unicode_and_newline'
  Add-RtfCheck 'native_rtf_actual_ctrl_v_preserves_complete_unicode_emoji_and_newline' $true
  $stage = 'bold'
  # Select only through actual physical keys; observation never changes text,
  # selection, document styles or focus.
  $keys.Chord($receiver.Handle, [UInt16[]]@(0x11, 0x24))
  for ($index = 0; $index -lt 4; $index++) { $keys.Chord($receiver.Handle, [UInt16[]]@(0x27)) }
  for ($index = 0; $index -lt 7; $index++) { $keys.Chord($receiver.Handle, [UInt16[]]@(0x10, 0x27)) }
  $bold = Wait-BrowserCondition {
    $value = $receiver.Read()
    if ($value.SelectedText -ceq 'fixture' -and $value.SelectionStart -eq 4 -and $value.SelectionLength -eq 7) { $value }
  } 'native_rtf_actual_keys_select_bold_run'
  Add-RtfCheck 'native_rtf_default_paste_renders_bold_color_and_twelve_point_font' (
    $bold.HasSingleFont -and $bold.Bold -and !$bold.Italic -and $bold.Color -eq 0xdc143c -and [Math]::Abs($bold.Points - 12) -lt 0.01)
  $stage = 'italic'
  $keys.Chord($receiver.Handle, [UInt16[]]@(0x11, 0x23))
  $keys.Chord($receiver.Handle, [UInt16[]]@(0x10, 0x24))
  $italic = Wait-BrowserCondition {
    $value = $receiver.Read()
    if ($value.SelectedText -ceq 'second line') { $value }
  } 'native_rtf_actual_keys_select_italic_run'
  Add-RtfCheck 'native_rtf_default_paste_renders_distinct_italic_run_without_bold_bleed' (
    $italic.HasSingleFont -and $italic.Italic -and !$italic.Bold -and $italic.Text -ceq $receiver.ExpectedText)
  Add-RtfCheck 'native_rtf_paste_and_selection_never_write_clipboard' ($receiver.ClipboardRevision -eq $revision)
  $stage = 'close'
  $keys.Chord($receiver.Handle, [UInt16[]]@(0x12, 0x73))
  Wait-BrowserCondition { $receiver.Stopped } 'native_rtf_actual_alt_f4_closes_owned_recipient' | Out-Null
  Add-RtfCheck 'native_rtf_actual_alt_f4_closes_owned_recipient' $true
} catch {
  $failure = $_.Exception
  if ($receiver -and !$receiver.Stopped) {
    try {
      $value = $receiver.Read()
      $diagnostic = @{ textLength = $value.Text.Length; expectedLength = $receiver.ExpectedText.Length;
        textMatches = $value.Text -ceq $receiver.ExpectedText; focused = $value.Focused;
        scannedPasteKeys = $value.ScannedPasteKeys; nativePasteMessages = $value.PasteMessages;
        selectionStart = $value.SelectionStart; selectionLength = $value.SelectionLength;
        selectedBoldRun = $value.SelectedText -ceq 'fixture'; selectedItalicRun = $value.SelectedText -ceq 'second line';
        hasSingleFont = $value.HasSingleFont; bold = $value.Bold; italic = $value.Italic;
        points = $value.Points; color = $value.Color }
    } catch { $diagnostic = @{ unavailable = $true } }
  }
}
finally {
  try { if ($receiver) { $receiver.Dispose() } } catch { $cleanupFailure = $_.Exception }
  try { if ($keys) { $keys.Dispose() } } catch {
    $cleanupFailure = if ($cleanupFailure) { [AggregateException]::new($cleanupFailure, $_.Exception) } else { $_.Exception }
  }
  $clean = $receiver -and $receiver.CleanupComplete -and !$cleanupFailure
  $checks.Add(@{ name = 'native_rtf_owned_receiver_and_input_peer_cleanup'; passed = [bool]$clean })
  $passed = !$failure -and !$cleanupFailure -and $clean -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $Output = [IO.Path]::GetFullPath($Output)
  [IO.Directory]::CreateDirectory((Split-Path $Output)) | Out-Null
  @{ passed = [bool]$passed; checks = @($checks.ToArray()); stage = $stage; diagnostic = $diagnostic;
     failureType = if ($failure) { $failure.GetType().FullName } else { $null };
     cleanupFailureType = if ($cleanupFailure) { $cleanupFailure.GetType().FullName } else { $null };
     scope = 'Owned native Windows RichEdit reference only; application copy and other rich-text applications are separate gates.' } |
    ConvertTo-Json -Depth 6 | Out-File -Encoding UTF8 $Output
}
if (!$passed) { exit 1 }
