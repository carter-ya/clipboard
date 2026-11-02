# Dot-sourced only by the synthetic Windows smoke profile, after UIA setup.
function Invoke-WindowsKeyboardAcceptance {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$KeyboardOnly -or
      !$application -or $application.HasExited -or !$historyRoot -or
      [IO.Path]::GetFullPath($historyRoot) -eq [IO.Path]::GetFullPath($env:APPDATA)) {
    throw 'keyboard_acceptance_requires_owned_windows_actions_profile'
  }
  $keyboardPeer = $null
  try {
    $keyboardPeer = [ClipboardKeyboardFixture]::new([uint32]$application.Id)
    @{ input = 'SendInput'; recipient = 'owned native WinForms editor';
       installedChineseLegacyImeCount = $keyboardPeer.InstalledChineseImeCount();
       chineseComposition = $(if ($ChineseIme) { 'required_see_actual_ime_checks' } else { 'not_verified' });
       mixedMonitorDpi = 'not_verified'; suspendResume = 'not_verified' } |
      ConvertTo-Json | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'keyboard-capabilities.json')

    # Set up the hidden app once. Reopening and search focus below must come
    # from the actual registered shortcut, never IPC, SetFocus or WM_HOTKEY.
    [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
    Invoke-Button 'Hide'
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'keyboard_initial_hide' | Out-Null
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_peer_foreground' | Out-Null
    $beforeKeyboardRevision = [PreviewNative]::GetClipboardSequenceNumber()
    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For {
      [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
        [PreviewNative]::IsWindowVisible($nativeWindowHandle) -and (Get-Editor).Current.HasKeyboardFocus
    } 'actual_global_hotkey_focuses_search_from_other_window' | Out-Null
    Add-Check 'actual_global_hotkey_focuses_search_from_other_window' $true

    # The separate IME preflight can change the runner's last active profile.
    # Establish the English baseline by an actual OS shortcut on this app.
    if ($keyboardPeer.TargetInputLanguage($nativeWindowHandle) -eq 0x0804) {
      $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x5b, 0x20))
      Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
        $keyboardPeer.TargetInputLanguage($nativeWindowHandle) -eq 0x0409 } 'keyboard_establishes_english_baseline' | Out-Null
    }

    $keyboardPeer.TypeAscii($nativeWindowHandle, 'welcomex')
    Wait-For { (Get-EditorWithValue 'welcomex') -and (Find-Named '0 items') } 'keyboard_ascii_filters_history' | Out-Null
    Add-Check 'keyboard_events_edit_the_actual_search' $true
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x08))
    Wait-For { (Get-EditorWithValue 'welcome') -and (Find-Named 'Welcome to Clipboard Preview') -and (Find-Named '1 items') } 'keyboard_backspace_filters_history' | Out-Null
    Add-Check 'keyboard_backspace_refreshes_selected_history' $true
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x24))
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x2e))
    Wait-For { (Get-EditorWithValue 'elcome') -and (Find-Named '1 items') } 'keyboard_home_delete_edit' | Out-Null
    Add-Check 'keyboard_home_delete_preserves_native_editing' $true
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
    $keyboardPeer.TypeUnicode($nativeWindowHandle, '中文')
    Wait-For { (Get-EditorWithValue '中文') -and (Find-Named '中文笔记 · 设计评审与输入测试') -and (Find-Named '1 items') } 'keyboard_unicode_query' | Out-Null
    Add-Check 'unicode_input_packets_reach_actual_search_without_claiming_ime_composition' $true
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x09))
    Wait-For { !(Get-Editor).Current.HasKeyboardFocus } 'keyboard_tab_leaves_search' | Out-Null
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x10, 0x09))
    Wait-For { (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue '中文') } 'keyboard_shift_tab_restores_search' | Out-Null
    Add-Check 'tab_and_shift_tab_preserve_query_and_restore_native_focus' $true

    # Use a real Space key to activate buttons; UIA only locates/focuses them.
    Invoke-WindowsKeyboardButton 'Settings' $keyboardPeer
    Wait-For { Find-Named 'Preferences' } 'keyboard_settings_open' | Out-Null
    Invoke-WindowsKeyboardButton 'Back to history' $keyboardPeer
    Wait-For { (Get-EditorWithValue '中文') -and (Get-Editor).Current.HasKeyboardFocus } 'keyboard_settings_returns_search_focus' | Out-Null
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x23)) # End collapses GTK's select-on-focus selection.
    $keyboardPeer.TypeAscii($nativeWindowHandle, 'a')
    Wait-For { (Get-EditorWithValue '中文a') -and (Find-Named '0 items') } 'keyboard_input_after_settings' | Out-Null
    Add-Check 'keyboard_input_continues_after_settings_without_refocusing_search' $true
    Add-Check 'hotkey_and_editing_never_copy_or_automatically_paste' (
      [PreviewNative]::GetClipboardSequenceNumber() -eq $beforeKeyboardRevision -and
        $keyboardPeer.PasteCount -eq 0 -and $keyboardPeer.Text.Length -eq 0)

    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
    $keyboardPeer.TypeAscii($nativeWindowHandle, 'welcome')
    Wait-For { (Get-EditorWithValue 'welcome') -and (Find-Named 'Welcome to Clipboard Preview') } 'keyboard_activation_selection' | Out-Null
    $copyRevision = [PreviewNative]::GetClipboardSequenceNumber()
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x0d))
    Wait-For {
      ![PreviewNative]::IsWindowVisible($nativeWindowHandle) -and
        [PreviewNative]::GetClipboardSequenceNumber() -ne $copyRevision -and
        (Read-SharedJson (Join-Path $historyRoot 'history.json')).items[0].preview -ceq 'Welcome to Clipboard Preview'
    } 'keyboard_enter_copies_promotes_and_hides' | Out-Null
    Add-Check 'enter_activates_selected_original_and_promotes_without_exiting' (!$application.HasExited -and
      [PreviewNative]::ReadClipboard() -ceq 'Welcome to Clipboard Preview')
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_paste_target_foreground' | Out-Null
    Add-Check 'enter_does_not_automatically_paste_into_other_window' ($keyboardPeer.PasteCount -eq 0 -and $keyboardPeer.Text.Length -eq 0)
    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x56))
    Wait-For { $keyboardPeer.PasteCount -eq 1 -and $keyboardPeer.Text -ceq 'Welcome to Clipboard Preview' } 'keyboard_explicit_ctrl_v_native_readback' | Out-Null
    Add-Check 'explicit_ctrl_v_pastes_full_original_into_independent_native_editor' $true
    Invoke-WindowsNotepadPasteAcceptance 'Welcome to Clipboard Preview' 'english'
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_peer_after_english_notepad' | Out-Null

    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
      (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue 'welcome') } 'keyboard_hotkey_retains_query' | Out-Null
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
    $keyboardPeer.TypeUnicode($nativeWindowHandle, '中文')
    Wait-For { (Get-EditorWithValue '中文') -and (Find-Named '中文笔记 · 设计评审与输入测试') } 'keyboard_chinese_selection_before_close' | Out-Null
    $beforeCloseRevision = [PreviewNative]::GetClipboardSequenceNumber()
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x12, 0x73)) # Alt+F4 through the OS.
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'keyboard_alt_f4_hides' | Out-Null
    Add-Check 'alt_f4_keeps_tray_app_alive_without_copying' (!$application.HasExited -and
      [PreviewNative]::GetClipboardSequenceNumber() -eq $beforeCloseRevision)
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_closed_peer_foreground' | Out-Null
    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
      (Get-EditorWithValue '中文') -and (Get-Editor).Current.HasKeyboardFocus } 'keyboard_alt_f4_hotkey_restores_focus' | Out-Null
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x23))
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x08))
    Wait-For { (Get-EditorWithValue '中') -and (Find-Named '1 items') } 'keyboard_edit_after_close_reopen' | Out-Null
    Add-Check 'real_key_input_survives_close_and_global_hotkey_reopen' $true
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
    $keyboardPeer.TypeUnicode($nativeWindowHandle, '中文')
    Wait-For { (Get-EditorWithValue '中文') -and (Find-Named '中文笔记 · 设计评审与输入测试') } 'keyboard_second_activation_selection' | Out-Null
    $copyRevision = [PreviewNative]::GetClipboardSequenceNumber()
    $keyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x0d))
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) -and
      [PreviewNative]::GetClipboardSequenceNumber() -ne $copyRevision } 'keyboard_second_activation_copies' | Out-Null
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_unicode_paste_foreground' | Out-Null
    Add-Check 'second_activation_still_requires_explicit_user_paste' ($keyboardPeer.PasteCount -eq 1 -and
      $keyboardPeer.Text -ceq 'Welcome to Clipboard Preview')
    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x41))
    Wait-For { $keyboardPeer.SelectionLength -eq $keyboardPeer.Text.Length } 'keyboard_peer_selects_entire_previous_paste' | Out-Null
    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x56))
    Wait-For { $keyboardPeer.PasteCount -eq 2 -and $keyboardPeer.Text -ceq '中文笔记 · 设计评审与输入测试' } 'keyboard_unicode_ctrl_v_readback' | Out-Null
    Add-Check 'explicit_ctrl_v_preserves_complete_chinese_original' $true
    Invoke-WindowsNotepadPasteAcceptance '中文笔记 · 设计评审与输入测试' 'chinese'
    $keyboardPeer.Activate()
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $keyboardPeer.Handle } 'keyboard_peer_after_chinese_notepad' | Out-Null

    $keyboardPeer.Chord($keyboardPeer.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and (Get-Editor).Current.HasKeyboardFocus } 'keyboard_final_reopen' | Out-Null
    if ($ChineseIme) { Invoke-WindowsChineseImeAcceptance $keyboardPeer }
    Invoke-WindowsKeyboardButton 'Settings' $keyboardPeer
    Wait-For { Find-Named 'Preferences' } 'keyboard_quit_settings' | Out-Null
    Invoke-WindowsKeyboardButton 'Quit Clipboard' $keyboardPeer
    if (!$application.WaitForExit(10000)) { throw 'keyboard_quit_timeout' }
    Add-Check 'keyboard_profile_quits_cleanly' ($application.ExitCode -eq 0)
  } finally {
    if ($keyboardPeer) {
      try {
        @{ pasteCount = $keyboardPeer.PasteCount; textLength = $keyboardPeer.Text.Length;
           selectionLength = $keyboardPeer.SelectionLength;
           matchesEnglishFixture = $keyboardPeer.Text -ceq 'Welcome to Clipboard Preview';
           matchesChineseFixture = $keyboardPeer.Text -ceq '中文笔记 · 设计评审与输入测试' } |
          ConvertTo-Json | Out-File -Encoding UTF8 (Join-Path $OutputDirectory 'keyboard-peer-state.json')
      } catch { }
      $keyboardPeer.Dispose()
    }
  }
}

function Invoke-WindowsChineseImeAcceptance($KeyboardPeer) {
  # Provisioning/native IME preflight must already have passed in this VM.
  # Change the input language using the actual OS shortcut on the owned app.
  if ($KeyboardPeer.TargetInputLanguage($nativeWindowHandle) -ne 0x0409) { throw 'ime_fixture_requires_initial_english_input' }
  $imeRevision = [PreviewNative]::GetClipboardSequenceNumber()
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x08))
  Wait-For { Get-EditorWithValue '' } 'ime_empty_search_before_language_switch' | Out-Null
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x5b, 0x20))
  Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and $KeyboardPeer.TargetInputLanguage($nativeWindowHandle) -eq 0x0804 } 'ime_actual_os_shortcut_selects_chinese_profile' | Out-Null
  if (!$KeyboardPeer.TargetChineseMode($nativeWindowHandle)) {
    $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x10))
  }
  Wait-For { $KeyboardPeer.TargetChineseMode($nativeWindowHandle) } 'ime_actual_chinese_conversion_mode' | Out-Null

  # Pinyin candidate generation is asynchronous even with ordered OS key events.
  # A selection key must wait for the complete native candidate pair, not just
  # for Latin keys to have entered the input queue.
  $KeyboardPeer.TypeLatinKeys($nativeWindowHandle, 'nihao')
  Wait-WindowsPinyinCandidates 'ime_complete_native_candidates_before_cancel'
  Add-Check 'actual_pinyin_candidates_are_visible_native_controls' $true
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x1b))
  Wait-For { !(Get-WindowsPinyinHost) -and (Get-EditorWithValue '') } 'ime_escape_dismisses_candidates_without_committing' | Out-Null
  $KeyboardPeer.TypeLatinKeys($nativeWindowHandle, 'nihao')
  Wait-WindowsPinyinCandidates 'ime_complete_native_candidates_before_space'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x20))
  Wait-For { Get-EditorWithValue '你好' } 'ime_escape_cancels_then_space_commits_in_actual_search' | Out-Null
  Add-Check 'actual_pinyin_cancel_and_first_candidate_reach_gtk_search' ([PreviewNative]::IsWindowVisible($nativeWindowHandle))
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x08))
  Wait-For { Get-EditorWithValue '' } 'ime_clear_first_committed_search' | Out-Null
  $KeyboardPeer.TypeLatinKeys($nativeWindowHandle, 'nihao')
  Wait-WindowsPinyinCandidates 'ime_complete_native_candidates_before_number'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x32))
  Wait-For { Get-EditorWithValue '你号' } 'ime_number_selects_second_candidate_in_actual_search' | Out-Null
  Add-Check 'actual_pinyin_number_selects_distinct_second_candidate_in_gtk' $true

  Invoke-WindowsKeyboardButton 'Settings' $KeyboardPeer
  Wait-For { Find-Named 'Preferences' } 'ime_settings_open' | Out-Null
  Invoke-WindowsKeyboardButton 'Back to history' $KeyboardPeer
  Wait-For { (Get-EditorWithValue '你号') -and (Get-Editor).Current.HasKeyboardFocus } 'ime_settings_returns_query_and_focus' | Out-Null
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
  $imeSelection = Wait-WindowsNativeImeSelection '你号' 'ime_native_selection_after_settings'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x27))
  Wait-WindowsNativeImeCaret '你号' $imeSelection.sequence $imeSelection.current.entry 'ime_native_caret_after_settings'
  $KeyboardPeer.TypeLatinKeys($nativeWindowHandle, 'nihao')
  Wait-WindowsPinyinCandidates 'ime_complete_native_candidates_after_settings'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x20))
  Wait-For { Get-EditorWithValue '你号你好' } 'ime_input_continues_after_settings' | Out-Null
  Add-Check 'actual_pinyin_survives_settings_focus_handoff' $true

  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x12, 0x73))
  Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } 'ime_alt_f4_hides' | Out-Null
  $KeyboardPeer.Activate()
  Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $KeyboardPeer.Handle } 'ime_owned_peer_foreground' | Out-Null
  $KeyboardPeer.Chord($KeyboardPeer.Handle, [UInt16[]]@(0x11, 0x12, 0x56))
  Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
    (Get-EditorWithValue '你号你好') -and (Get-Editor).Current.HasKeyboardFocus } 'ime_hotkey_restores_query_and_focus' | Out-Null
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x11, 0x41))
  $imeSelection = Wait-WindowsNativeImeSelection '你号你好' 'ime_native_selection_after_hotkey'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x27))
  Wait-WindowsNativeImeCaret '你号你好' $imeSelection.sequence $imeSelection.current.entry 'ime_native_caret_after_hotkey'
  $KeyboardPeer.TypeLatinKeys($nativeWindowHandle, 'nihao')
  Wait-WindowsPinyinCandidates 'ime_complete_native_candidates_after_hotkey'
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x20))
  Wait-For { Get-EditorWithValue '你号你好你好' } 'ime_input_continues_after_hotkey_reopen' | Out-Null
  Add-Check 'actual_pinyin_survives_close_and_hotkey_reopen' $true
  Add-Check 'actual_ime_editing_never_copies_or_pastes' ([PreviewNative]::GetClipboardSequenceNumber() -eq $imeRevision -and $KeyboardPeer.PasteCount -eq 2)

  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x5b, 0x20))
  Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and $KeyboardPeer.TargetInputLanguage($nativeWindowHandle) -eq 0x0409 } 'ime_os_shortcut_returns_to_english' | Out-Null
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x23))
  $KeyboardPeer.TypeAscii($nativeWindowHandle, 'a')
  Wait-For { Get-EditorWithValue '你号你好你好a' } 'ime_english_input_after_chinese' | Out-Null
  Add-Check 'actual_english_input_resumes_after_pinyin' $true
}

function Wait-WindowsNativeImeSelection([string]$Query, [string]$Stage) {
  Wait-For {
    $receipt = Read-SharedJson (Join-Path $historyRoot 'ime-state.json')
    if ($receipt.current.entry -gt 0 -and $receipt.current.focused -and $receipt.current.mapped -and
        $receipt.current.selected -and $receipt.current.start -eq 0 -and $receipt.current.end -eq $Query.Length -and
        $receipt.current.characters -eq $Query.Length -and (Get-EditorWithValue $Query)) { return $receipt }
    return $false
  } $Stage
}

function Wait-WindowsNativeImeCaret([string]$Query, [int]$BeforeSequence, [int]$EntryID, [string]$Stage) {
  Wait-For {
    $receipt = Read-SharedJson (Join-Path $historyRoot 'ime-state.json')
    $lastEvent = $receipt.events[-1]
    $receipt.sequence -gt $BeforeSequence -and $receipt.current.entry -eq $EntryID -and
      $lastEvent.entry -eq $EntryID -and $lastEvent.event -in @('cursor', 'selection') -and
      $receipt.current.focused -and $receipt.current.mapped -and !$receipt.current.selected -and
      $receipt.current.characters -eq $Query.Length -and $receipt.current.cursor -eq $Query.Length -and
      (Get-EditorWithValue $Query)
  } $Stage | Out-Null
}

function Get-WindowsPinyinHost {
  if ([ClipboardKeyboardFixture]::GetForegroundWindow() -ne $nativeWindowHandle -or
      !(Get-Editor).Current.HasKeyboardFocus) { return $null }
  $condition = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ClassNameProperty, 'Microsoft.IME.UIManager.CandidateWindow.Host')
  foreach ($hostControl in $script:window.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
    $hostHandle = [IntPtr]$hostControl.Current.NativeWindowHandle
    if ($hostHandle -ne [IntPtr]::Zero -and [PreviewNative]::IsWindowVisible($hostHandle)) { return $hostControl }
  }
  return $null
}

function Wait-WindowsPinyinCandidates([string]$Stage) {
  Wait-For {
    $candidateHost = Get-WindowsPinyinHost
    if (!$candidateHost) { return $false }
    $condition = [Windows.Automation.PropertyCondition]::new(
      [Windows.Automation.AutomationElement]::ClassNameProperty, 'CandidateButton')
    $buttons = $candidateHost.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
    if ($buttons.Count -lt 2 -or $buttons.Count -gt 32) { return $false }
    $first = $buttons[0].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    $second = $buttons[1].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    $buttons[0].Current.IsEnabled -and $buttons[1].Current.IsEnabled -and
      $first -ceq '你好' -and $second -ceq '你号'
  } $Stage | Out-Null
}

function Invoke-WindowsKeyboardButton([string]$Label, $KeyboardPeer) {
  $button = Find-Named $Label
  for ($depth = 0; $depth -lt 10 -and $button -and
      $button.Current.ControlType -ne [Windows.Automation.ControlType]::Button; $depth++) {
    $button = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($button)
  }
  if (!$button -or !$button.Current.IsEnabled) { throw 'keyboard_button_unavailable' }
  $button.SetFocus()
  Wait-For { $button.Current.HasKeyboardFocus } 'keyboard_button_focus' | Out-Null
  $KeyboardPeer.Chord($nativeWindowHandle, [UInt16[]]@(0x20))
}
