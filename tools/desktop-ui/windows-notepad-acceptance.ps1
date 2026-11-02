# Only loaded by KeyboardOnly on the disposable Windows Actions desktop.
function Invoke-WindowsNotepadPasteAcceptance([string]$Expected, [string]$FixtureName) {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$KeyboardOnly -or
      !$application -or $application.HasExited -or !$historyRoot -or
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
    if ($notepad.HasExited -or ![string]::Equals($notepad.MainModule.FileName, $notepadExecutable, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'notepad_spawned_process_identity_mismatch'
    }
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
    Add-Check ('common_notepad_starts_empty_without_automatic_paste_' + $FixtureName) (
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
       input = 'actual Ctrl+V and Ctrl+S'; characters = $Expected.Length;
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
