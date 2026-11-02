# Real product capture and copy, followed by actual Ctrl+V into the owned RichEdit.
function Invoke-WindowsRichTextAcceptance($AppKeys) {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$KeyboardOnly -or !$RtfPaste -or
      !$application -or $application.HasExited -or !$AppKeys -or !$historyRoot -or
      [IO.Path]::GetFullPath($historyRoot) -eq [IO.Path]::GetFullPath($env:APPDATA)) {
    throw 'rtf_app_acceptance_requires_owned_private_keyboard_profile'
  }
  Initialize-WindowsRichTextFixture
  $receiver = $null
  $rtfKeys = $null
  $failure = $null
  $cleanupFailure = $null
  $keysDisposed = $false
  $stage = 'startup'
  $rtfOutput = Join-Path $OutputDirectory 'richtext'
  [IO.Directory]::CreateDirectory($rtfOutput) | Out-Null
  try {
    $receiver = [ClipboardOwnedRichText]::new()
    $rtfKeys = [ClipboardKeyboardFixture]::new([uint32]$PID)
    $query = 'RTF fixture'
    [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle } 'rtf_app_setup_foreground' | Out-Null
    Set-Search $query
    Wait-For { Get-EditorWithValue $query } 'rtf_app_capture_query' | Out-Null
    $beforeIDs = @((Get-LocalTextRecords).id)
    $stage = 'capture'
    Invoke-Button 'Start recording'
    Wait-For { Find-Named 'Recording clipboard' } 'rtf_app_recording' | Out-Null
    $receiver.WriteFixture()
    Wait-BrowserCondition { $receiver.SourceMatches() } 'rtf_app_independent_native_source_bytes' | Out-Null
    Add-Check 'rtf_app_independent_writer_has_exact_native_original' $true
    $record = Wait-For {
      $matches = @(Get-LocalTextRecords | Where-Object {
        $_.id -notin $beforeIDs -and $_.kind -ceq 'rtf' -and $_.preview -ceq $receiver.ExpectedText -and !$_.sensitive
      })
      if ($matches.Count -eq 1) { $matches[0] }
    } 'rtf_app_persists_captured_original'
    Wait-For { (Get-EditorWithValue $query) -and (Find-Named '1 items') } 'rtf_app_unique_captured_selection' | Out-Null
    Invoke-Button 'Pause recording'
    Wait-For { (Find-Named 'Recording paused') -and (Find-Named 'Start recording') } 'rtf_app_capture_paused' | Out-Null
    Add-Check 'rtf_app_captures_and_uniquely_selects_original_unicode_preview' $true
    $stage = 'copy'
    Invoke-Button 'Hide'
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'rtf_app_hidden_before_hotkey' | Out-Null
    $receiver.Activate()
    Wait-BrowserCondition { $receiver.Read().Focused } 'rtf_owned_recipient_foreground' | Out-Null
    if ($receiver.Read().Text -cne '') { throw 'rtf_recipient_not_initially_empty' }
    $copyRevision = $receiver.ClipboardRevision
    $rtfKeys.Chord($receiver.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
      (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue $query) -and (Find-Named '1 items') } 'rtf_actual_hotkey_focuses_captured_record' | Out-Null
    $AppKeys.Chord($nativeWindowHandle, [UInt16[]]@(0x0d))
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) -and
      $receiver.ClipboardRevision -ne $copyRevision -and
      (Get-LocalTextRecords)[0].id -ieq $record.id } 'rtf_app_enter_copies_and_promotes_original' | Out-Null
    Add-Check 'rtf_app_enter_publishes_exact_original_native_format_bytes' ($receiver.SourceMatches())
    $empty = $receiver.Read()
    Add-Check 'rtf_app_copy_never_automatically_pastes' ($empty.Text -ceq '' -and $empty.ScannedPasteKeys -eq 0 -and $empty.PasteMessages -eq 0)
    $stage = 'paste'
    $receiver.Activate()
    Wait-BrowserCondition { $receiver.Read().Focused } 'rtf_recipient_focus_before_explicit_paste' | Out-Null
    $pasteRevision = $receiver.ClipboardRevision
    $rtfKeys.Chord($receiver.Handle, [UInt16[]]@(0x11, 0x56))
    $receipt = Assert-WindowsRichTextPaste $receiver $rtfKeys
    Add-Check 'rtf_app_actual_ctrl_v_preserves_full_unicode_emoji_and_newline' $receipt.unicode
    Add-Check 'rtf_app_actual_ctrl_v_renders_original_bold_color_and_size' $receipt.boldColorSize
    Add-Check 'rtf_app_actual_ctrl_v_renders_distinct_original_italic_run' $receipt.distinctItalic
    Add-Check 'rtf_app_paste_and_native_selection_do_not_write_clipboard' ($receiver.ClipboardRevision -eq $pasteRevision)
    $stage = 'close'
    $rtfKeys.Chord($receiver.Handle, [UInt16[]]@(0x12, 0x73))
    Wait-BrowserCondition { $receiver.Stopped } 'rtf_app_actual_alt_f4_closes_recipient' | Out-Null
    Add-Check 'rtf_app_actual_alt_f4_closes_owned_recipient' $true
    $rtfKeys.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $rtfKeys.Handle } 'rtf_input_peer_after_recipient_close' | Out-Null
    $rtfKeys.Chord($rtfKeys.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
      (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue $query) -and
      (Get-LocalTextRecords)[0].id -ieq $record.id } 'rtf_app_returns_to_same_captured_record' | Out-Null
    Add-Check 'rtf_app_shortcut_returns_to_same_record_and_query_after_paste' $true
    @{ scope = 'Real private application RTF capture, actual shortcut/Enter copy and native RichEdit Ctrl+V';
       receipt = $receipt; otherApplications = 'not_verified'; physicalClient = 'not_verified' } |
      ConvertTo-Json -Depth 6 | Out-File -Encoding UTF8 (Join-Path $rtfOutput 'receipt.json')
  } catch {
    $failure = $_.Exception
    try { $diagnostic = Get-WindowsRichTextDiagnostic $receiver } catch { $diagnostic = @{ unavailable = $true } }
    @{ stage = $stage; failureType = $failure.GetType().FullName; diagnostic = $diagnostic } |
      ConvertTo-Json -Depth 6 | Out-File -Encoding UTF8 (Join-Path $rtfOutput 'failure.json')
  } finally {
    try { if ($receiver) { $receiver.Dispose() } } catch { $cleanupFailure = $_.Exception }
    try { if ($rtfKeys) { $rtfKeys.Dispose(); $keysDisposed = $true } } catch {
      $cleanupFailure = if ($cleanupFailure) { [AggregateException]::new($cleanupFailure, $_.Exception) } else { $_.Exception }
    }
    $script:checks.Add(@{ name = 'rtf_app_owned_receiver_and_input_peer_cleanup';
      passed = [bool]($receiver -and $receiver.CleanupComplete -and $keysDisposed -and !$cleanupFailure) })
  }
  if ($failure -and $cleanupFailure) { throw [AggregateException]::new('rtf_app_and_cleanup_failed', [Exception[]]@($failure, $cleanupFailure)) }
  if ($cleanupFailure) { throw $cleanupFailure }
  if ($failure) { throw $failure }
}
