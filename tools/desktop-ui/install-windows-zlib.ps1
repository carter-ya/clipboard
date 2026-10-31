param([Parameter(Mandatory=$true)][string]$Prefix)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'clipboard-zlib-1.3.2'
$SourceRoot = Join-Path $WorkRoot 'zlib-1.3.2'
$BuildRoot = Join-Path $WorkRoot 'build'
$Archive = Join-Path $WorkRoot 'zlib-1.3.2.tar.gz'
New-Item -ItemType Directory -Force $WorkRoot, $Prefix | Out-Null
# Setting LIB to only our prefix disables Swift/Clang's implicit MSVC
# discovery. Initialize the complete native SDK before extending its paths.
$Locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$Installation = (& $Locator -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (!$Installation) { throw 'msvc_installation_missing' }
$DeveloperCommand = Join-Path $Installation 'Common7/Tools/VsDevCmd.bat'
$NativeNames = @('INCLUDE', 'LIB', 'LIBPATH', 'VCToolsInstallDir', 'VCINSTALLDIR', 'VSINSTALLDIR', 'WindowsSdkDir', 'WindowsSDKVersion', 'UniversalCRTSdkDir', 'UCRTVersion')
$Batch = Join-Path $WorkRoot 'native-environment.cmd'
$Output = Join-Path $WorkRoot 'native-build-paths.txt'
$ErrorOutput = Join-Path $WorkRoot 'native-environment-error.txt'
# Emit only build-path variables, never the complete runner environment.
$BatchText = "@echo off`r`ncall `"$DeveloperCommand`" -no_logo -arch=x64 -host_arch=x64 >nul`r`nif errorlevel 1 exit /b 1`r`nfor %%V in ($($NativeNames -join ' ')) do @set %%V 2>nul`r`nexit /b 0`r`n"
Set-Content -Encoding ascii -Path $Batch -Value $BatchText
$Command = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', ('"' + $Batch + '"')) `
  -PassThru -RedirectStandardOutput $Output -RedirectStandardError $ErrorOutput
if (!$Command.WaitForExit(60000)) { $Command.Kill($true); throw 'msvc_environment_timeout' }
if ($Command.ExitCode -ne 0) { throw 'msvc_environment_failed' }
foreach ($Line in Get-Content $Output) {
  if ($Line -match '^([^=]+)=(.*)$' -and $NativeNames -contains $Matches[1]) {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
  }
}
foreach ($Library in @('msvcrt.lib', 'oldnames.lib', 'msvcprt.lib')) {
  $Found = @($env:LIB -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ $Library)) })
  if (!$Found.Count) { throw 'msvc_runtime_library_paths_missing' }
}
# Official upstream release asset, with SHA-256 published at https://zlib.net/.
# The zlib.net endpoint can return a browser challenge instead of the archive.
$ExpectedHash = 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'
Invoke-WebRequest -Uri 'https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz' -OutFile $Archive
if ((Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant() -cne $ExpectedHash) {
  throw 'zlib_source_checksum_mismatch'
}
& tar.exe -xzf $Archive -C $WorkRoot
if ($LASTEXITCODE -ne 0) { throw 'zlib_source_extraction_failed' }
& cmake -S $SourceRoot -B $BuildRoot -G 'Visual Studio 17 2022' -A x64 `
  -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON -DZLIB_BUILD_TESTING=OFF `
  ('-DCMAKE_INSTALL_PREFIX=' + $Prefix)
if ($LASTEXITCODE -ne 0) { throw 'zlib_configure_failed' }
& cmake --build $BuildRoot --config Release --target zlibstatic --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'zlib_build_failed' }
& cmake --install $BuildRoot --config Release
if ($LASTEXITCODE -ne 0) { throw 'zlib_install_failed' }
$Libraries = @(Get-ChildItem (Join-Path $Prefix 'lib') -Filter '*.lib' | Where-Object { $_.Name -match '^(zs|zlibstatic)\.lib$' })
if ($Libraries.Count -ne 1) { throw 'zlib_static_library_missing' }
# ZIPFoundation's Windows system target links "zlib". This build-time SDK
# dependency is static; it adds no DLL to the desktop distribution.
Copy-Item $Libraries[0].FullName (Join-Path $Prefix 'lib/zlib.lib') -Force
if (!(Test-Path (Join-Path $Prefix 'include/zlib.h')) -or !(Test-Path (Join-Path $Prefix 'include/zconf.h'))) {
  throw 'zlib_headers_missing'
}
$env:INCLUDE = (Join-Path $Prefix 'include') + ';' + $env:INCLUDE
$env:LIB = (Join-Path $Prefix 'lib') + ';' + $env:LIB
if ($env:GITHUB_ENV) {
  "INCLUDE=$env:INCLUDE" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  "LIB=$env:LIB" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  foreach ($Name in $NativeNames | Where-Object { $_ -notin @('INCLUDE', 'LIB') }) {
    $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($Value) { "$Name=$Value" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV }
  }
}
Write-Host 'Verified static zlib SDK headers and library configured'
