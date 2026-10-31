param([Parameter(Mandatory=$true)][string]$FixturePython)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private-fixture-python.ps1')
foreach ($configuredInput in @($false,$true)) {
  $info = [Diagnostics.ProcessStartInfo]::new((Resolve-PrivateFixturePython $FixturePython))
  $info.Arguments = '"' + (Join-Path $PSScriptRoot 'ai-probe-server.py') + '"'
  $info.UseShellExecute = $false
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardInputEncoding = [Text.UTF8Encoding]::new($true)
  if ($configuredInput) { Set-PrivateFixtureInputEncoding $info }
  $info.Environment['CLIPBOARD_PRIVATE_AI_TEST']='1'
  $info.Environment['CLIPBOARD_PRIVATE_AI_MODE']='analysis'
  $server=[Diagnostics.Process]::Start($info)
  $client=[Net.Http.HttpClient]::new()
  try {
    $null=$server.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $ready=$server.StandardOutput.ReadLineAsync()
    if (!$ready.Wait(10000) -or $ready.Result -notmatch '^ready:([0-9]+)$') { throw 'fixture_start' }
    $port=$Matches[1]
    $body=@{model='fixture-model';messages=@(@{role='system';content='Synthetic fixture'},@{role='user';content="Synthetic fixture`n`nRelease checklist · build, test, publish"})}|ConvertTo-Json -Depth 6 -Compress
    $content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
    $response=$client.PostAsync(('http://127.0.0.1:'+$port+'/v1/chat/completions'),$content)
    $blocked=$server.StandardOutput.ReadLineAsync()
    if (!$blocked.Wait(10000) -or $blocked.Result -cne 'blocked') { throw 'fixture_not_held' }
    if (!$configuredInput) {
      $server.StandardInput.WriteLine('release');$server.StandardInput.Flush()
      if ($response.Wait(1500)) { throw 'BOM_failure_not_reproduced' }
      Write-Host 'BOM-prefixed StreamWriter command does not release actual fixture'
      $server.StandardInput.Close()
    }
    if ($configuredInput) {
      $server.StandardInput.WriteLine('release')
      $server.StandardInput.Flush()
    }
    if (!$response.Wait(5000)) { throw 'fixture_release_incomplete' }
    if ([int]$response.Result.StatusCode -ne 503) { throw 'fixture_release_status' }
    $server.StandardInput.Close()
    if (!$server.WaitForExit(10000)) { throw 'fixture_quit' }
    $report=$server.StandardOutput.ReadLineAsync()
    if (!$report.Wait(5000)) {throw 'fixture_report'}
    $audit=$report.Result|ConvertFrom-Json
    if ($server.ExitCode -ne 0 -or $audit.requests -ne 1 -or !$audit.fixedTestsOnly -or !$audit.noAuthorization -or !$audit.noCookies) {throw 'fixture_audit'}
    if ($configuredInput) {Write-Host 'Explicit UTF-8 without a preamble releases the actual fixture'}
  } finally {
    $client.Dispose()
    if (!$server.HasExited) {$server.Kill();$server.WaitForExit()}
    $server.Dispose()
  }
}
