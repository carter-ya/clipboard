param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'native_ime_requires_owned_windows_actions_runner' }
Add-Type -Path (Join-Path $PSScriptRoot '../desktop-ui/windows-keyboard-fixture.cs') `
  -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
$report = [ordered]@{ passed = $false; stage = 'starting'; checks = @();
  errorType = $null; errorCode = $null; activationResult = $null; inputLayout = $null;
  keyMessages = 0; scannedKeyMessages = 0; imeMessages = 0;
  conversionBeforeInput = $null; conversionAfterInput = $null;
  modeShortcutSent = $false;
  imeOpen = $false; compositionLength = 0; compositionMatchesInput = $false;
  textLength = 0; limitations = @('Actual Windows input method in an owned native editor; GTK application integration is a separate gate.') }
$peer = $null
function Wait-Ime([scriptblock]$Predicate, [string]$Stage) {
  $script:report.stage = $Stage
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (& $Predicate) { return }
    Start-Sleep -Milliseconds 100
  }
  throw $Stage
}
try {
  $peer = [ClipboardKeyboardFixture]::new([uint32]$PID)
  $peer.Activate()
  Wait-Ime { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $peer.Handle } 'owned_ime_target_foreground'
  $peer.TypeAscii($peer.Handle, 'a')
  Wait-Ime { $peer.Text -ceq 'a' } 'native_ascii_input_before_switching_ime'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x11, 0x41))
  $peer.Chord($peer.Handle, [UInt16[]]@(0x08))
  Wait-Ime { $peer.Text.Length -eq 0 } 'native_editor_empty_before_ime'
  $report.stage = 'activate_native_chinese_profile'
  $peer.UseChineseIme()
  # Microsoft Pinyin's documented Shift key selects Chinese/English mode.
  # Setting a legacy IMM flag can be replaced by the provider on the first key.
  if (!$peer.ImeOpen -or ($peer.ImeConversionMode -band 1) -eq 0) {
    $peer.Chord($peer.Handle, [UInt16[]]@(0x10))
    $report.modeShortcutSent = $true
  }
  Wait-Ime { $peer.ImeOpen -and ($peer.ImeConversionMode -band 1) -ne 0 } 'native_chinese_ime_open'
  $report.conversionBeforeInput = $peer.ImeConversionMode
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionIsNihao -and $peer.Text.Length -eq 0 } 'actual_pinyin_preedit_without_committing_text'
  $report.checks += 'actual_pinyin_preedit_without_committing_text'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x1b))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text.Length -eq 0 } 'escape_cancels_uncommitted_composition'
  $report.checks += 'escape_cancels_uncommitted_composition'
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionIsNihao -and $peer.Text.Length -eq 0 } 'pinyin_restarts_after_cancel'
  # The pinned fresh Windows Server/Pinyin dictionary has these exact results.
  # Verify actual key selection via committed native text; this provider closes
  # TSF UI-element handles while continuing to show its own candidate window.
  $expected = [string][char]0x4f60 + [char]0x597d
  $peer.Chord($peer.Handle, [UInt16[]]@(0x20))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text -ceq $expected } 'space_commits_actual_chinese_candidate'
  $report.checks += 'space_commits_actual_chinese_candidate'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x11, 0x41))
  Wait-Ime { $peer.SelectionLength -eq $peer.Text.Length } 'ime_select_existing_query'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x08))
  Wait-Ime { $peer.Text.Length -eq 0 } 'ime_clear_owned_editor'
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionIsNihao -and $peer.Text.Length -eq 0 } 'pinyin_second_candidate_available'
  $second = [string][char]0x4f60 + [char]0x53f7
  $peer.Chord($peer.Handle, [UInt16[]]@(0x32))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text -ceq $second } 'number_selects_second_native_candidate'
  $report.checks += 'number_selects_second_native_candidate'
  # Establish the insertion point using the same actual keys as GTK after
  # refocus. This independent editor is the native IME reference for appending.
  $peer.Chord($peer.Handle, [UInt16[]]@(0x11, 0x41))
  $peer.Chord($peer.Handle, [UInt16[]]@(0x27))
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionIsNihao } 'native_pinyin_preedit_at_established_end'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x20))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text -ceq ($second + $expected) } 'native_pinyin_appends_after_select_all_right'
  $report.checks += 'native_pinyin_appends_after_select_all_right'
  if (!$peer.TargetChineseMode($peer.Handle)) { throw 'native_ime_window_status_must_match_real_conversion_mode' }
  $peer.Chord($peer.Handle, [UInt16[]]@(0x5b, 0x20))
  Wait-Ime { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $peer.Handle -and
    $peer.TargetInputLanguage($peer.Handle) -eq 0x0409 } 'native_win_space_returns_to_english'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x5b, 0x20))
  Wait-Ime { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $peer.Handle -and
    $peer.TargetInputLanguage($peer.Handle) -eq 0x0804 } 'native_win_space_selects_chinese'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x5b, 0x20))
  Wait-Ime { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $peer.Handle -and
    $peer.TargetInputLanguage($peer.Handle) -eq 0x0409 } 'native_preflight_restores_english_before_other_tests'
  $report.checks += 'native_input_status_and_real_language_shortcut'
  if ($peer.PasteCount -ne 0) { throw 'ime_test_must_never_paste' }
  $report.checks += 'ime_test_uses_no_clipboard_or_unicode_packets'
  $report.passed = $true
} catch {
  $failure = $_.Exception
  while ($failure.InnerException) { $failure = $failure.InnerException }
  $report.errorType = $failure.GetType().FullName
  $report.errorCode = $failure.HResult
} finally {
  if ($peer) {
    if (!$report.passed) {
      try { [IO.File]::WriteAllBytes([IO.Path]::ChangeExtension($Output, 'png'), $peer.CaptureOwnedForegroundWindow()) } catch { }
    }
    try {
      $report.imeOpen = $peer.ImeOpen
      $report.activationResult = $peer.ImeActivationResult
      $report.inputLayout = $peer.InputLayout
      $report.keyMessages = $peer.KeyMessageCount
      $report.scannedKeyMessages = $peer.ScannedKeyMessageCount
      $report.imeMessages = $peer.ImeMessageCount
      $report.conversionAfterInput = $peer.ImeConversionMode
      $report.compositionLength = $peer.CompositionLength
      $report.compositionMatchesInput = $peer.CompositionIsNihao
      $report.textLength = $peer.Text.Length
    } catch { }
    try { $peer.Dispose() } catch { $report.passed = $false; $report.errorType = $_.Exception.GetType().FullName }
  }
  $report | ConvertTo-Json -Depth 4 | Out-File -Encoding UTF8 -LiteralPath $Output
}
if (!$report.passed) { throw 'native_chinese_ime_not_verified_see_content_free_report' }
