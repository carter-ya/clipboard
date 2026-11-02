param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT' -or !$env:RUNNER_TEMP) {
  throw 'valid_image_probe_requires_owned_windows_actions'
}
$root = Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ('clipboard-valid-images-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$checks = [Collections.Generic.List[object]]::new()
$failure = $null
$cleanupFailure = $null
$nativeExit = $null
$stage = 'fixtures'
$failureLine = $null
try {
  Add-Type -AssemblyName System.Drawing
  Add-Type -Path (Join-Path $PSScriptRoot 'windows-valid-image-fixtures.cs') -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Drawing.dll')
  [ClipboardValidImageFixtures]::Write($root)
  foreach ($kind in @('jpeg', 'tiff')) {
    $checks.Add(@{ name = ('independent_gdi_' + $kind + '_fixture_decodes'); passed = $true })
    $checks.Add(@{ name = ('independent_gdi_' + $kind + '_orientation_metadata'); passed = $true })
  }
  $stage = 'compiler_location'
  $compilerPaths = @((Join-Path $env:ProgramFiles 'LLVM/bin/clang.exe'))
  if ($env:VCINSTALLDIR) {
    $compilerPaths += (Join-Path $env:VCINSTALLDIR 'Tools/Llvm/x64/bin/clang.exe')
    $compilerPaths += (Join-Path $env:VCINSTALLDIR 'Tools/Llvm/bin/clang.exe')
  }
  $compiler = $compilerPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (!$compiler) { throw 'valid_image_native_compiler_missing' }
  $native = Join-Path $root 'check-valid-images.exe'
  $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
  $stage = 'compile'
  & $compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' '-I' (Join-Path $repository 'Core/Sources/CDesktopClipboard/include') (Join-Path $PSScriptRoot 'check-windows-valid-images.c') (Join-Path $repository 'Core/Sources/CDesktopClipboard/desktop_clipboard.c') '-luser32' '-lshell32' '-lole32' '-lwindowscodecs' '-luuid' '-o' $native
  if ($LASTEXITCODE -ne 0) { throw 'valid_image_native_compile_failed' }
  $stage = 'native_adapter'
  $lines = & $native $root
  $nativeExit = $LASTEXITCODE
  foreach ($line in $lines) {
    if ($line -notmatch '^(PASS|FAIL) ([a-z0-9_]+)$') { throw 'valid_image_native_receipt_invalid' }
    $checks.Add(@{ name = $Matches[2]; passed = $Matches[1] -ceq 'PASS' })
  }
  if (@($lines).Count -ne 240) { throw 'valid_image_native_receipt_incomplete' }
} catch { $failure = $_.Exception; $failureLine = $_.InvocationInfo.ScriptLineNumber }
finally {
  try { [IO.Directory]::Delete($root, $true) } catch { $cleanupFailure = $_.Exception }
  $checks.Add(@{ name = 'owned_valid_image_fixture_cleanup'; passed = !$cleanupFailure })
  $passed = !$failure -and !$cleanupFailure -and $nativeExit -eq 0 -and @($checks | Where-Object { !$_.passed }).Count -eq 0
  $Output = [IO.Path]::GetFullPath($Output)
  [IO.Directory]::CreateDirectory((Split-Path $Output)) | Out-Null
  @{ passed = [bool]$passed; checks = @($checks.ToArray()); nativeExit = $nativeExit; stage = $stage; failureLine = $failureLine;
    failureType = if ($failure) { $failure.GetType().FullName } else { $null };
    cleanupFailureType = if ($cleanupFailure) { $cleanupFailure.GetType().FullName } else { $null };
    scope = 'Actual product C adapter, independent GDI+ pixels/metadata, absent/all8 JPEG/TIFF orientations in ordinary/sensitive modes, original native bytes/roundtrip and standard bitmap geometry/pixel permutations. Real app/browser paste and ICC profiles remain separate gates.' } |
    ConvertTo-Json -Depth 6 | Out-File -Encoding UTF8 $Output
}
if (!$passed) { exit 1 }
