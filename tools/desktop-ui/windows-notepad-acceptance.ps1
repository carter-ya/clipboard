# Owned Notepad checks on the disposable Windows Actions desktop.
function Wait-OwnedNotepadIdentity($Process, [string]$ExpectedExecutable) {
  # Start-Process can return before MainModule is available. Observe only the
  # retained process; an exited/delegated/wrong executable is never retried.
  $identity = Wait-For {
    try {
      if ($Process.HasExited) { return 'exited' }
      $Process.Refresh()
      if ($Process.HasExited) { return 'exited' }
      $module = $Process.MainModule
      if ($null -eq $module -or [string]::IsNullOrWhiteSpace($module.FileName)) { return $false }
      if (![string]::Equals($module.FileName, $ExpectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        return 'mismatch'
      }
      return 'ready'
    } catch {
      return 'unreadable'
    }
  } 'notepad_spawned_process_identity_ready' 10
  # Wait-For normally retries UI lookup exceptions. Return terminal states from
  # its predicate and reject them outside that loop, before any input is sent.
  switch ($identity) {
    'ready' { return }
    'exited' { throw 'owned_notepad_exited_before_identity' }
    'mismatch' { throw 'notepad_spawned_process_identity_mismatch' }
    default { throw 'owned_notepad_identity_unreadable' }
  }
}

function Invoke-WindowsNotepadPasteAcceptance([string]$Expected, [string]$FixtureName, [string]$Query, $AppKeys) {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$KeyboardOnly -or
      !$application -or $application.HasExited -or !$historyRoot -or !$AppKeys -or !$Query -or
      $FixtureName -notin @('english', 'chinese')) { throw 'notepad_paste_requires_private_keyboard_profile' }
  $notepad = $null
  $notepadKeys = $null
  try {
    $notepadExecutable = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32/notepad.exe'))
    $notepadDirectory = Join-Path $OutputDirectory ('notepad-' + $FixtureName)
    New-Item -ItemType Directory -Force $notepadDirectory | Out-Null
    $notepadFile = Join-Path ([IO.Path]::GetFullPath($notepadDirectory)) ('clipboard-owned-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($notepadFile, '', [Text.UTF8Encoding]::new($true))
    $notepad = Start-Process -FilePath $notepadExecutable -ArgumentList ('"' + $notepadFile + '"') -PassThru
    $null = $notepad.Handle
    # The pinned Server runner has classic Notepad. A delegated Store process
    # or another editor must fail rather than receiving input by a broad search.
    Wait-OwnedNotepadIdentity $notepad $notepadExecutable
    $notepadWindow = Wait-For {
      if ($notepad.HasExited) { throw 'owned_notepad_exited_before_window' }
      $handle = [ClipboardOwnedNotepad]::FindWindow([uint32]$notepad.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } ('notepad_window_' + $FixtureName)
    $notepadEditor = Wait-For {
      $handle = [ClipboardOwnedNotepad]::FindEditor($notepadWindow, [uint32]$notepad.Id)
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } ('notepad_editor_' + $FixtureName)
    $notepadKeys = [ClipboardKeyboardFixture]::new([uint32]$notepad.Id)
    [PreviewNative]::SetForegroundWindow($notepadWindow) | Out-Null
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $notepadWindow -and
      [ClipboardOwnedNotepad]::EditorFocused($notepadWindow, $notepadEditor, [uint32]$notepad.Id) } ('notepad_focus_' + $FixtureName) | Out-Null
    if ([ClipboardOwnedNotepad]::ReadText($notepadWindow, $notepadEditor, [uint32]$notepad.Id) -cne '') {
      throw 'owned_notepad_document_not_initially_empty'
    }
    # Exercise the user flow with Notepad already foreground: open Clipboard by
    # its registered shortcut and copy by Enter, then require Notepad to remain
    # empty until the separately submitted Ctrl+V. Do not populate either editor.
    $beforeCopy = [PreviewNative]::GetClipboardSequenceNumber()
    $notepadKeys.Chord($notepadWindow, [UInt16[]]@(0x11, 0x12, 0x56))
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
      (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue $Query) -and
      (Find-Named $Expected) } ('notepad_registered_hotkey_' + $FixtureName) | Out-Null
    $AppKeys.Chord($nativeWindowHandle, [UInt16[]]@(0x0d))
    Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) -and
      [PreviewNative]::GetClipboardSequenceNumber() -ne $beforeCopy -and
      [PreviewNative]::ReadClipboard() -ceq $Expected } ('notepad_app_copies_selected_original_' + $FixtureName) | Out-Null
    [PreviewNative]::SetForegroundWindow($notepadWindow) | Out-Null
    Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $notepadWindow -and
      [ClipboardOwnedNotepad]::EditorFocused($notepadWindow, $notepadEditor, [uint32]$notepad.Id) } ('notepad_returns_after_copy_' + $FixtureName) | Out-Null
    Add-Check ('common_notepad_remains_empty_after_app_copy_until_explicit_paste_' + $FixtureName) (
      [ClipboardOwnedNotepad]::ReadText($notepadWindow, $notepadEditor, [uint32]$notepad.Id) -ceq '')
    $beforePaste = [PreviewNative]::GetClipboardSequenceNumber()
    $notepadKeys.Chord($notepadWindow, [UInt16[]]@(0x11, 0x56))
    Wait-For {
      [ClipboardOwnedNotepad]::ReadText($notepadWindow, $notepadEditor, [uint32]$notepad.Id) -ceq $Expected
    } ('notepad_actual_ctrl_v_' + $FixtureName) | Out-Null
    Add-Check ('common_notepad_actual_ctrl_v_preserves_full_original_' + $FixtureName) $true
    $notepadKeys.Chord($notepadWindow, [UInt16[]]@(0x11, 0x53))
    Wait-For { [IO.File]::ReadAllText($notepadFile) -ceq $Expected } ('notepad_saved_text_' + $FixtureName) | Out-Null
    Add-Check ('common_notepad_saved_text_matches_original_without_changing_clipboard_' + $FixtureName) (
      [PreviewNative]::GetClipboardSequenceNumber() -eq $beforePaste)
    $notepadKeys.Chord($notepadWindow, [UInt16[]]@(0x12, 0x73))
    if (!$notepad.WaitForExit(10000) -or $notepad.ExitCode -ne 0) { throw 'owned_notepad_clean_exit_failed' }
    Add-Check ('common_notepad_saved_document_closes_normally_' + $FixtureName) $true
    @{ application = 'Windows Server 2022 classic Notepad'; fixture = $FixtureName;
       input = 'actual global hotkey, Enter, Ctrl+V and Ctrl+S'; characters = $Expected.Length;
       exactEditorAndSavedFileMatch = $true; clipboardUnchanged = $true;
       richFormats = 'not_verified'; otherApplications = 'not_verified' } |
      ConvertTo-Json | Out-File -Encoding UTF8 (Join-Path $notepadDirectory 'receipt.json')
  } finally {
    try { if ($notepadKeys) { $notepadKeys.Dispose() } }
    finally {
      if ($notepad) {
        try {
          if (!$notepad.HasExited) {
            $notepad.Kill()
            if (!$notepad.WaitForExit(5000)) { throw 'owned_notepad_cleanup_failed' }
          }
        } finally { $notepad.Dispose() }
      }
    }
  }
}
