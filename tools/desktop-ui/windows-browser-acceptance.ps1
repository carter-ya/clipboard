# Real product capture/copy followed by native paste into the owned browser.
function Invoke-WindowsBrowserAcceptance($AppKeys) {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$KeyboardOnly -or !$BrowserPaste -or
      !$application -or $application.HasExited -or !$AppKeys -or !$historyRoot -or
      [IO.Path]::GetFullPath($historyRoot) -eq [IO.Path]::GetFullPath($env:APPDATA)) {
    throw 'browser_app_acceptance_requires_owned_private_keyboard_profile'
  }
  $browser = $null
  $failure = $null
  $cleanupFailure = $null
  $stage = 'startup'
  $receipts = [Collections.Generic.List[object]]::new()
  $browserOutput = Join-Path $OutputDirectory 'browser'
  [IO.Directory]::CreateDirectory($browserOutput) | Out-Null
  try {
    $browser = New-WindowsOwnedBrowser
    $sourceHashes = @{}
    foreach ($path in $browser.native.Files) { $sourceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    foreach ($format in @('text', 'html', 'image', 'files')) {
      $fixture = switch ($format) {
        'text' { @{ query = 'fixture'; preview = $browser.native.PlainText; kind = 'text' } }
        'html' { @{ query = 'rich'; preview = $browser.native.HtmlText; kind = 'text' } }
        'image' { @{ query = '<image>'; preview = '<image>'; kind = 'image' } }
        'files' { @{ query = 'alpha'; preview = [IO.Path]::GetFileName($browser.native.Files[0]); kind = 'file' } }
      }
      $stage = 'capture_' + $format
      [PreviewNative]::SetForegroundWindow($nativeWindowHandle) | Out-Null
      Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle } ('browser_app_setup_foreground_' + $format) | Out-Null
      Set-Search $fixture.query
      Wait-For { Get-EditorWithValue $fixture.query } ('browser_app_query_' + $format) | Out-Null
      $beforeIDs = @((Get-LocalTextRecords).id)
      Invoke-Button 'Start recording'
      Wait-For { Find-Named 'Recording clipboard' } ('browser_app_recording_' + $format) | Out-Null
      $browser.native.WriteFixture($format)
      if ($format -eq 'html') {
        Wait-BrowserCondition { $browser.native.HtmlFixtureMatches() } 'browser_app_source_has_exact_native_utf8_html' | Out-Null
        Add-Check 'browser_app_independent_writer_has_exact_native_utf8_html' $true
      }
      $browserRecord = Wait-For {
        $matches = @(Get-LocalTextRecords | Where-Object {
          $_.id -notin $beforeIDs -and $_.kind -ceq $fixture.kind -and $_.preview -ceq $fixture.preview -and !$_.sensitive
        })
        if ($matches.Count -eq 1) { $matches[0] }
      } ('browser_app_persists_captured_original_' + $format)
      Wait-For { (Get-EditorWithValue $fixture.query) -and (Find-Named '1 items') } ('browser_app_unique_captured_selection_' + $format) | Out-Null
      Invoke-Button 'Pause recording'
      Wait-For { (Find-Named 'Recording paused') -and (Find-Named 'Start recording') } ('browser_app_capture_paused_' + $format) | Out-Null
      Add-Check ('browser_app_captures_and_selects_independent_native_' + $format) $true

      $stage = 'copy_' + $format
      # Mac and desktop shortcuts toggle a visible history window off. Begin
      # this summon check hidden, through the actual user-facing Hide control.
      Invoke-Button 'Hide'
      Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) } ('browser_app_hidden_before_hotkey_' + $format) | Out-Null
      Focus-WindowsOwnedBrowser $browser -Reset
      $copyRevision = [PreviewNative]::GetClipboardSequenceNumber()
      $browser.keys.Chord($browser.window, [UInt16[]]@(0x11, 0x12, 0x56))
      Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
        (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue $fixture.query) -and
        (Find-Named '1 items') } ('browser_actual_hotkey_focuses_captured_' + $format) | Out-Null
      $AppKeys.Chord($nativeWindowHandle, [UInt16[]]@(0x0d))
      Wait-For { ![PreviewNative]::IsWindowVisible($nativeWindowHandle) -and
        [PreviewNative]::GetClipboardSequenceNumber() -ne $copyRevision -and
        (Get-LocalTextRecords)[0].id -ieq $browserRecord.id } ('browser_app_enter_copies_and_promotes_' + $format) | Out-Null
      $empty = Get-WindowsBrowserSnapshot $browser
      Add-Check ('browser_app_copy_never_automatically_pastes_' + $format) (
        @($empty.receipts).Count -eq 0 -and $empty.content -ceq '' -and !$empty.image)

      $stage = 'paste_' + $format
      Focus-WindowsOwnedBrowser $browser
      $pasteRevision = [PreviewNative]::GetClipboardSequenceNumber()
      $browser.keys.Chord($browser.window, [UInt16[]]@(0x11, 0x56))
      $receipt = Assert-WindowsBrowserPaste $browser $format
      Add-Check ('browser_explicit_ctrl_v_preserves_app_copied_' + $format) $true
      Add-Check ('browser_pasting_app_copied_' + $format + '_does_not_write_clipboard') (
        [PreviewNative]::GetClipboardSequenceNumber() -eq $pasteRevision)
      $receipts.Add($receipt)
      # Restore the actual app using the shortcut before the next capture.
      $browser.keys.Chord($browser.window, [UInt16[]]@(0x11, 0x12, 0x56))
      Wait-For { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $nativeWindowHandle -and
        (Get-Editor).Current.HasKeyboardFocus -and (Get-EditorWithValue $fixture.query) } ('browser_app_returns_after_paste_' + $format) | Out-Null
    }
    $sourcesUnchanged = $true
    foreach ($path in $browser.native.Files) {
      if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $sourceHashes[$path]) { $sourcesUnchanged = $false }
    }
    Add-Check 'browser_app_capture_copy_and_paste_keep_original_file_bytes_unchanged' $sourcesUnchanged
    @{ scope = 'Real private product capture, actual hotkey/Enter copy, trusted browser Ctrl+V';
       receipts = @($receipts.ToArray()); otherApplications = 'not_verified'; physicalClient = 'not_verified' } |
      ConvertTo-Json -Depth 8 | Out-File -Encoding UTF8 (Join-Path $browserOutput 'receipt.json')
  } catch {
    $failure = $_.Exception
    $diagnostic = $null
    if ($browser) { try { $diagnostic = Get-WindowsBrowserDiagnostic $browser } catch { $diagnostic = @{ unavailable = $true } } }
    @{ stage = $stage; failureType = $failure.GetType().FullName; diagnostic = $diagnostic } |
      ConvertTo-Json -Depth 8 | Out-File -Encoding UTF8 (Join-Path $browserOutput 'failure.json')
  } finally {
    try { Close-WindowsOwnedBrowser $browser } catch { $cleanupFailure = $_.Exception }
    $clean = $browser -and $browser.native.CleanupComplete
    if (!$browser -and $failure) {
      $cursor = $failure
      for ($depth = 0; $depth -lt 5 -and $cursor; $depth++) {
        if ($cursor.Data.Contains('ownedBrowserCleanupComplete')) { $clean = $cursor.Data['ownedBrowserCleanupComplete'] -eq $true; break }
        $cursor = $cursor.InnerException
      }
    }
    $script:checks.Add(@{ name = 'browser_app_owned_job_and_private_profile_cleanup'; passed = [bool]$clean })
  }
  if ($failure -and $cleanupFailure) { throw [AggregateException]::new('browser_app_and_cleanup_failed', [Exception[]]@($failure, $cleanupFailure)) }
  if ($cleanupFailure) { throw $cleanupFailure }
  if ($failure) { throw $failure }
}
