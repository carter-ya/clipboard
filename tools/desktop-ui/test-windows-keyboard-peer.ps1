# Native self-test of the actual recipient before the expensive Swift build.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'keyboard_peer_test_requires_windows_actions' }
function Wait-Peer([scriptblock]$Predicate, [string]$Stage) {
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (& $Predicate) { return }
    Start-Sleep -Milliseconds 100
  }
  throw $Stage
}
$ownedPeer = $null
try {
  $ownedPeer = [ClipboardKeyboardFixture]::new([uint32]$PID)
  $ownedPeer.Activate()
  Wait-Peer { [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $ownedPeer.Handle } 'native_peer_foreground'
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
  if ($ownedPeer) { $ownedPeer.Dispose() }
}
