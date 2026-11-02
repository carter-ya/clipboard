param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'browser_probe_requires_windows_actions' }
. (Join-Path $PSScriptRoot 'windows-browser-functions.ps1')
$context = $null
$completed = $false
$checks = [Collections.Generic.List[object]]::new()
$errorType = $null
$failure = $null
$diagnostic = $null
$startupCleanup = $false
try {
  $context = New-WindowsOwnedBrowser
  & (Join-Path $PSScriptRoot 'test-windows-browser-cleanup.ps1')
  $checks.Add(@{ name = 'owned_browser_teardown_failure_still_removes_private_profile'; passed = $true })
  foreach ($kind in @('text', 'html', 'image', 'files')) {
    Focus-WindowsOwnedBrowser $context -Reset
    $context.native.WriteFixture($kind)
    $revision = $context.native.ClipboardRevision
    $context.keys.Chord($context.window, [UInt16[]]@(0x11, 0x56))
    $receipt = Assert-WindowsBrowserPaste $context $kind
    $checks.Add(@{ name = ('browser_trusted_native_' + $kind + '_paste_preserves_original'); passed = $true; receipt = $receipt })
    $unchanged = $context.native.ClipboardRevision -eq $revision
    $checks.Add(@{ name = ('browser_' + $kind + '_paste_does_not_write_clipboard'); passed = $unchanged })
    if (!$unchanged) { throw 'browser_paste_writes_clipboard' }
  }
  $completed = $true
} catch {
  $errorType = $_.Exception.GetType().FullName
  $failure = $_.Exception.Message.Substring(0, [Math]::Min(1024, $_.Exception.Message.Length))
  $errorCursor = $_.Exception
  for ($depth = 0; $depth -lt 5 -and $errorCursor; $depth++) {
    if ($errorCursor.Data.Contains('ownedBrowserCleanupComplete')) { $startupCleanup = $errorCursor.Data['ownedBrowserCleanupComplete'] -eq $true; break }
    $errorCursor = $errorCursor.InnerException
  }
  if ($context) {
    try { $diagnostic = Get-WindowsBrowserDiagnostic $context } catch { $diagnostic = @{ unavailable = $true } }
  }
}
finally {
  try { Close-WindowsOwnedBrowser $context }
  catch {
    $completed = $false; $errorType = $_.Exception.GetType().FullName
    $failure = 'owned_browser_cleanup_failed'
  }
  $cleanup = ($context -and $context.native.CleanupComplete) -or (!$context -and $startupCleanup)
  $checks.Add(@{ name = 'owned_browser_process_job_and_private_profile_cleanup'; passed = [bool]$cleanup })
  $passed = $completed -and $cleanup -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $Output = [IO.Path]::GetFullPath($Output)
  [IO.Directory]::CreateDirectory((Split-Path $Output)) | Out-Null
  @{ passed = [bool]$passed; checks = @($checks.ToArray()); errorType = $errorType; failure = $failure; stage = $kind; diagnostic = $diagnostic;
     scope = 'Owned Windows Actions Chrome native input reference only; product capture/copy is a separate gate.' } |
    ConvertTo-Json -Depth 8 | Out-File -Encoding UTF8 $Output
  if (!$passed) { exit 1 }
}
