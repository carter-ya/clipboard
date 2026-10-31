param([Parameter(Mandatory=$true)][string]$Prefix)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'clipboard-zlib-1.3.2'
$SourceRoot = Join-Path $WorkRoot 'zlib-1.3.2'
$BuildRoot = Join-Path $WorkRoot 'build'
$Archive = Join-Path $WorkRoot 'zlib-1.3.2.tar.gz'
New-Item -ItemType Directory -Force $WorkRoot, $Prefix | Out-Null
# Official zlib release and SHA-256 published at https://zlib.net/.
$ExpectedHash = 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'
Invoke-WebRequest -Uri 'https://zlib.net/fossils/zlib-1.3.2.tar.gz' -OutFile $Archive
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
# ZIPFoundation's Windows system target links "zlib". This Core-only SDK
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
}
Write-Host 'Verified static zlib SDK headers and library configured'
