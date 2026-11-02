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
  imeOpen = $false; compositionLength = 0; candidateCount = 0;
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
  Wait-Ime { $peer.CompositionLength -gt 0 -and $peer.CandidateCount -ge 2 } 'actual_pinyin_composition_and_candidates'
  $report.checks += 'actual_pinyin_composition_and_candidates'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x1b))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text.Length -eq 0 } 'escape_cancels_uncommitted_composition'
  $report.checks += 'escape_cancels_uncommitted_composition'
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionLength -gt 0 -and $peer.CandidateCount -ge 2 } 'pinyin_restarts_after_cancel'
  $first = $peer.CandidateAt(0)
  $expected = [string][char]0x4f60 + [char]0x597d
  if ($first -cne $expected) { throw 'fresh_pinyin_first_candidate_must_match_fixture' }
  $peer.Chord($peer.Handle, [UInt16[]]@(0x20))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text -ceq $expected } 'space_commits_actual_chinese_candidate'
  $report.checks += 'space_commits_actual_chinese_candidate'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x11, 0x41))
  Wait-Ime { $peer.SelectionLength -eq $peer.Text.Length } 'ime_select_existing_query'
  $peer.Chord($peer.Handle, [UInt16[]]@(0x08))
  Wait-Ime { $peer.Text.Length -eq 0 } 'ime_clear_owned_editor'
  $peer.TypeLatinKeys($peer.Handle, 'nihao')
  Wait-Ime { $peer.CompositionLength -gt 0 -and $peer.CandidateCount -ge 2 } 'pinyin_second_candidate_available'
  $second = $peer.CandidateAt(1)
  if (!$second -or $second -ceq $first) { throw 'distinct_second_candidate_required' }
  $peer.Chord($peer.Handle, [UInt16[]]@(0x32))
  Wait-Ime { $peer.CompositionLength -eq 0 -and $peer.Text -ceq $second } 'number_selects_second_native_candidate'
  $report.checks += 'number_selects_second_native_candidate'
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
      $report.candidateCount = $peer.CandidateCount
      $report.textLength = $peer.Text.Length
    } catch { }
    try { $peer.Dispose() } catch { $report.passed = $false; $report.errorType = $_.Exception.GetType().FullName }
  }
  $report | ConvertTo-Json -Depth 4 | Out-File -Encoding UTF8 -LiteralPath $Output
}
if (!$report.passed) { throw 'native_chinese_ime_not_verified_see_content_free_report' }
