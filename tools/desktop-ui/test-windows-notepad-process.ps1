param([string]$Output = 'ui-artifacts/input/notepad-process.json')
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') {
  throw 'notepad_process_probe_requires_disposable_windows_actions'
}
# Reuse the actual bounded observer, including its UI-exception semantics.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'smoke-windows.ps1'), [ref]$tokens, [ref]$errors)
$wait = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-For'
}, $true))
if ($errors.Count -or $wait.Count -ne 1) { throw 'actual_notepad_observer_missing' }
. ([ScriptBlock]::Create($wait[0].Extent.Text))
. (Join-Path $PSScriptRoot 'windows-notepad-acceptance.ps1')
$script:application = $null
$script:sensitiveProbe = $false
$executable = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32/notepad.exe'))
$root = Join-Path ([IO.Path]::GetTempPath()) ('clipboard-notepad-readiness-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$checks = @()
try {
  foreach ($index in 1..3) {
    $owned = $null
    try {
      $file = Join-Path $root ('empty-' + $index + '.txt')
      [IO.File]::WriteAllText($file, '', [Text.UTF8Encoding]::new($true))
      $owned = Start-Process -FilePath $executable -ArgumentList ('"' + $file + '"') -PassThru
      $null = $owned.Handle
      $moduleInitiallyAvailable = $false
      try { $moduleInitiallyAvailable = $null -ne $owned.MainModule } catch { }
      Wait-OwnedNotepadIdentity $owned $executable
      $checks += @{ check = 'retained_process_identity_ready'; passed = $true;
                    attempt = $index; moduleInitiallyAvailable = $moduleInitiallyAvailable }
    } finally {
      if ($owned) {
        try {
          if (!$owned.HasExited) {
            $owned.Kill()
            if (!$owned.WaitForExit(5000)) { throw 'owned_notepad_readiness_cleanup_failed' }
          }
        } finally { $owned.Dispose() }
      }
    }
  }
  $target = [IO.Path]::GetFullPath($Output)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
  @{ scope = 'native_notepad_process_readiness'; checks = $checks;
     input = 'none'; clipboard = 'untouched'; processSearch = 'none' } |
    ConvertTo-Json -Depth 5 | Out-File -Encoding UTF8 $target
} finally { [IO.Directory]::Delete($root, $true) }
