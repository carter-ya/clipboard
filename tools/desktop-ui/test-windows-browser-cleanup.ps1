param([string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
if ($AssemblyPath) { [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath)) | Out-Null }
if (!('ClipboardBrowserFixture' -as [type])) { throw 'browser_cleanup_test_requires_compiled_actual_type' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-browser-cleanup-regression-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'owned.txt'), 'synthetic fixture')
try {
  # Exercise the actual Dispose method without starting any browser, using a
  # deliberately invalid native job handle to force its teardown failure path.
  $fixture = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([ClipboardBrowserFixture])
  [ClipboardBrowserFixture].GetProperty('Root').GetSetMethod($true).Invoke($fixture, [object[]]@([string]$root)) | Out-Null
  [ClipboardBrowserFixture].GetField('job', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($fixture, [IntPtr]1)
  $failure = $null
  try { $fixture.Dispose() } catch { $failure = $_.Exception }
  if (!$failure -or (Test-Path -LiteralPath $root) -or $fixture.CleanupComplete) {
    throw 'actual_browser_teardown_failure_must_attempt_profile_cleanup_and_remain_failed'
  }
  if (!$failure.ToString().Contains('owned_browser_process_teardown_failed')) { throw 'actual_browser_teardown_failure_must_be_preserved' }
  Write-Host 'Actual browser Dispose removes owned files after native teardown failure and preserves the failure'
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
