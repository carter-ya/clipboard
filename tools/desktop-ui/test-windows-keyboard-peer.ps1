# Native self-test of the actual recipient before the expensive Swift build.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'keyboard_peer_test_requires_windows_actions' }
$keyFactory = [ClipboardKeyboardFixture].GetMethod('Key', [Reflection.BindingFlags]'NonPublic,Static')
foreach ($keyCase in @(
  @{ key = 0x23; flags = 1 }, @{ key = 0x27; flags = 1 }, @{ key = 0x2e; flags = 1 },
  @{ key = 0x5b; flags = 1 }, @{ key = 0x11; flags = 0 }, @{ key = 0x41; flags = 0 }
)) {
  foreach ($up in @($false, $true)) {
    $encodedKey = $keyFactory.Invoke($null, @([UInt16]$keyCase.key, $up))
    $expectedFlags = $keyCase.flags -bor $(if ($up) { 2 } else { 0 })
    if ($encodedKey.data.keyboard.flags -ne $expectedFlags -or $encodedKey.data.keyboard.scan -eq 0) {
      throw 'actual_keyboard_factory_extended_key_flags_and_scan_code'
    }
  }
}
function Wait-Peer([scriptblock]$Predicate, [string]$Stage) {
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (& $Predicate) { return }
    Start-Sleep -Milliseconds 100
  }
  throw $Stage
}
$ownedPeer = $null
$originalInput = [Windows.Forms.InputLanguage]::CurrentInputLanguage
try {
  $chineseProfile = [Windows.Forms.InputLanguage]::InstalledInputLanguages | Where-Object { $_.Culture.Name -eq 'zh-CN' } | Select-Object -First 1
  if ($chineseProfile) { [Windows.Forms.InputLanguage]::CurrentInputLanguage = $chineseProfile }
  $ownedPeer = [ClipboardKeyboardFixture]::new([uint32]$PID)
  $ownedPeer.Activate()
  Wait-Peer { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $ownedPeer.Handle } 'native_peer_foreground'
  if ($ownedPeer.TargetInputLanguage($ownedPeer.Handle) -ne 0x0409) { throw 'owned_peer_must_establish_english_after_chinese_preflight' }
  if ($chineseProfile -and [Windows.Forms.InputLanguage]::CurrentInputLanguage.Handle -ne $chineseProfile.Handle) {
    throw 'owned_peer_must_not_change_parent_thread_input_language'
  }
  $ownedPeer.TypeAscii($ownedPeer.Handle, 'welcome')
  Wait-Peer { $ownedPeer.Text -ceq 'welcome' } 'native_peer_ascii_input'
  $ownedPeer.Chord($ownedPeer.Handle, [UInt16[]]@(0x11, 0x41))
  Wait-Peer { $ownedPeer.SelectionLength -eq 7 } 'native_multiline_ctrl_a_selects_complete_text'
  $chinese = [string][char]0x4e2d + [char]0x6587
  $ownedPeer.TypeUnicode($ownedPeer.Handle, $chinese)
  Wait-Peer { $ownedPeer.Text -ceq $chinese } 'native_peer_unicode_replaces_selected_text'
  if ($ownedPeer.PasteCount -ne 0) { throw 'native_peer_selftest_must_not_paste' }
  Write-Host 'Owned native recipient accepts ASCII, selects all by Ctrl+A and replaces it with Unicode input'
} finally {
  try { if ($ownedPeer) { $ownedPeer.Dispose() } }
  finally { [Windows.Forms.InputLanguage]::CurrentInputLanguage = $originalInput }
}
