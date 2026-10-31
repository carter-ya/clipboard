param([Parameter(Mandatory=$true)][string]$FixturePython)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
. (Join-Path $PSScriptRoot 'private-fixture-python.ps1')
foreach ($configuredInput in @($false,$true)) {
  $info = [Diagnostics.ProcessStartInfo]::new((Resolve-PrivateFixturePython $FixturePython))
  $info.Arguments = '"' + (Join-Path $PSScriptRoot 'ai-probe-server.py') + '"'
  $info.UseShellExecute = $false
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  if ($null -ne $info.PSObject.Properties['StandardInputEncoding']) {
    # Reproduce the legacy StreamWriter preamble even on modern PowerShell.
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($true)
  }
  if ($configuredInput) { Set-PrivateFixtureInputEncoding $info }
  $info.EnvironmentVariables['CLIPBOARD_PRIVATE_AI_TEST']='1'
  $info.EnvironmentVariables['CLIPBOARD_PRIVATE_AI_MODE']='analysis'
  $server=[Diagnostics.Process]::Start($info)
  $client=[Net.Http.HttpClient]::new()
  try {
    $null=$server.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $ready=$server.StandardOutput.ReadLineAsync()
    if (!$ready.Wait(10000) -or $ready.Result -notmatch '^ready:([0-9]+)$') { throw 'fixture_start' }
    $port=$Matches[1]
    # Keep this script ASCII so Windows PowerShell 5.1 cannot misdecode UTF-8.
    $userContent = "Synthetic fixture`n`nRelease checklist " + [char]0x00B7 + ' build, test, publish'
    $body=@{model='fixture-model';messages=@(@{role='system';content='Synthetic fixture'},@{role='user';content=$userContent})}|ConvertTo-Json -Depth 6 -Compress
    $content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
    $response=$client.PostAsync(('http://127.0.0.1:'+$port+'/v1/chat/completions'),$content)
    $blocked=$server.StandardOutput.ReadLineAsync()
    if (!$blocked.Wait(10000) -or $blocked.Result -cne 'blocked') { throw 'fixture_not_held' }
    $server.StandardInput.WriteLine('release')
    $server.StandardInput.Flush()
    if (!$response.Wait(5000)) { throw 'fixture_release_incomplete' }
    if ([int]$response.Result.StatusCode -ne 503) { throw 'fixture_release_status' }
    $server.StandardInput.Close()
    if (!$server.WaitForExit(10000)) { throw 'fixture_quit' }
    $report=$server.StandardOutput.ReadLineAsync()
    if (!$report.Wait(5000)) {throw 'fixture_report'}
    $audit=$report.Result|ConvertFrom-Json
    if ($server.ExitCode -ne 0 -or $audit.requests -ne 1 -or !$audit.fixedTestsOnly -or !$audit.noAuthorization -or !$audit.noCookies) {throw 'fixture_audit'}
    Write-Host ('Actual fixture releases without EOF; explicit input encoding=' + $configuredInput)
  } finally {
    $client.Dispose()
    if (!$server.HasExited) {$server.Kill();$server.WaitForExit()}
    $server.Dispose()
  }
}
