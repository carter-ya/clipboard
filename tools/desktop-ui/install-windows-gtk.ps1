param([string]$Prefix = 'C:\gtk-build\gtk\x64\release', [switch]$ConfigureOnly)
$ErrorActionPreference = 'Stop'

function Invoke-Checked([scriptblock]$Command) {
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "Native build command failed: $LASTEXITCODE" }
}
function Get-VerifiedFile([string]$Url, [string]$Path, [string]$SHA256) {
  Write-Host ('Downloading verified input: ' + [IO.Path]::GetFileName($Path))
  # Invoke-WebRequest stalled for the entire job despite TimeoutSec. Curl has
  # independent connect and total deadlines, and avoids PowerShell progress I/O.
  & curl.exe --ipv4 --fail --location --silent --show-error --retry 2 --retry-delay 3 `
    --connect-timeout 20 --max-time 180 --output $Path $Url
  if ($LASTEXITCODE -ne 0) { throw ('Verified input download failed: ' + [IO.Path]::GetFileName($Path)) }
  Write-Host ('Downloaded bytes: ' + (Get-Item $Path).Length)
  if ((Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant() -ne $SHA256) {
    throw 'Downloaded GTK source/runtime checksum mismatch'
  }
  Write-Host ('Verified checksum: ' + [IO.Path]::GetFileName($Path))
}
function Enter-VisualStudioEnvironment {
  $Locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  $Installation = (& $Locator -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
  if (!$Installation) { throw 'Visual Studio C++ tools are required' }
  $DeveloperCommand = Join-Path $Installation 'Common7/Tools/VsDevCmd.bat'
  Write-Host 'Initializing Visual Studio C++ environment'
  $EnvironmentRoot = Join-Path $env:RUNNER_TEMP 'clipboard-vc-environment'
  New-Item -ItemType Directory -Force $EnvironmentRoot | Out-Null
  $Batch = Join-Path $EnvironmentRoot 'initialize.cmd'
  $Output = Join-Path $EnvironmentRoot 'environment.txt'
  $ErrorOutput = Join-Path $EnvironmentRoot 'error.txt'
  # A private batch file avoids cmd /s quoting ambiguities around spaced paths.
  "@echo off`r`ncall `"$DeveloperCommand`" -no_logo -arch=x64 -host_arch=x64`r`nif errorlevel 1 exit /b 1`r`nset`r`n" |
    Set-Content -Encoding ascii $Batch
  $Command = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', ('"' + $Batch + '"')) `
    -PassThru -RedirectStandardOutput $Output -RedirectStandardError $ErrorOutput
  if (!$Command.WaitForExit(120000)) {
    $Command.Kill($true)
    throw 'Visual Studio environment initialization exceeded two minutes'
  }
  if ($Command.ExitCode -ne 0) { throw 'Could not initialize Visual Studio tools' }
  $DeveloperEnvironment = Get-Content $Output
  foreach ($Line in $DeveloperEnvironment) {
    if ($Line -match '^([^=]+)=(.*)$') {
      [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
  }
}
function Set-GtkEnvironment {
  $env:Path = "$Prefix\bin;" + $env:Path
  $env:PKG_CONFIG_PATH = "$Prefix\lib\pkgconfig;$Prefix\share\pkgconfig"
  $env:LIB = "$Prefix\lib;" + $env:LIB
  $env:INCLUDE = "$Prefix\include;" + $env:INCLUDE
  if ($env:GITHUB_PATH) { "$Prefix\bin" | Out-File -Append -Encoding utf8 $env:GITHUB_PATH }
  if ($env:GITHUB_ENV) {
    "PKG_CONFIG_PATH=$env:PKG_CONFIG_PATH" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
    "LIB=$env:LIB" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
  }
}

if (!$ConfigureOnly) {
  $BuildRoot = Join-Path $env:RUNNER_TEMP 'clipboard-gtk-source'
  New-Item -ItemType Directory -Force $BuildRoot, $Prefix | Out-Null
  $RuntimeZip = Join-Path $BuildRoot 'gtk-runtime.zip'
  Get-VerifiedFile 'https://github.com/wingtk/gvsbuild/releases/download/2026.8.0/GTK4_Gvsbuild_2026.8.0_x64.zip' $RuntimeZip '1f95a92d037f5292da05e6ab1037032ff21ddb7b20d4ac8e83e3674c864c07b0'
  Write-Host 'Extracting fixed GTK dependency archive'
  Expand-Archive -Path $RuntimeZip -DestinationPath $Prefix -Force
  Set-GtkEnvironment
  Invoke-Checked { python -m pip install meson==1.9.1 ninja==1.13.0 }
  Write-Host 'Installing fixed Rust toolchain without updating rustup'
  $env:RUSTUP_DOWNLOAD_TIMEOUT = '180'
  Invoke-Checked { rustup toolchain install 1.87.0 --profile minimal --no-self-update }
  $env:RUSTUP_TOOLCHAIN = '1.87.0'
  Enter-VisualStudioEnvironment
  Set-GtkEnvironment
  $env:CC = 'cl'
  $env:CXX = 'cl'
  Get-Command cl.exe -ErrorAction Stop | Out-Null
  $SourceArchive = Join-Path $BuildRoot 'gtk-4.22.4.tar.xz'
  Get-VerifiedFile 'https://download.gnome.org/sources/gtk/4.22/gtk-4.22.4.tar.xz' $SourceArchive '51bd9f60c7d23a665a556c7364c21fb2e4e282566b3e7e092455e8f910330893'
  Write-Host 'Extracting fixed GTK source archive with Python'
  # Windows tar stalled after downloading the source without reporting progress.
  # Read the already verified regular-file-only archive with Python instead.
  Invoke-Checked { python (Join-Path $PSScriptRoot 'extract-gtk-source.py') $SourceArchive $BuildRoot }
  $SourceRoot = Join-Path $BuildRoot 'gtk-4.22.4'
  $AccessKitRoot = Join-Path $SourceRoot 'subprojects/accesskit-c'
  Write-Host 'Fetching fixed AccessKit source'
  $env:GIT_TERMINAL_PROMPT = '0'
  Invoke-Checked { git init $AccessKitRoot }
  Invoke-Checked { git -C $AccessKitRoot remote add origin https://github.com/AccessKit/accesskit-c.git }
  Invoke-Checked { git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=120 -C $AccessKitRoot fetch --depth 1 origin 0c52a8ce2357bbeb927f90dc9a1c19c8ec1bd2c3 }
  Invoke-Checked { git -C $AccessKitRoot checkout --detach FETCH_HEAD }
  $OutputRoot = Join-Path $BuildRoot 'build'
  # The upstream Windows archive supplies fixed MSVC dependencies. Rebuild GTK
  # itself with AccessKit enabled; its standard archive omits this backend.
  Write-Host 'Configuring GTK with AccessKit'
  Invoke-Checked {
    meson setup $OutputRoot $SourceRoot --prefix=$Prefix --libdir=lib --buildtype=release --default-library=shared `
      -Daccesskit=enabled -Dintrospection=disabled -Ddocumentation=false -Dman-pages=false -Dscreenshots=false `
      -Dbuild-tests=false -Dbuild-testsuite=false -Dbuild-demos=false -Dbuild-examples=false `
      -Dvulkan=disabled -Dmedia-gstreamer=disabled -Dprint-cups=disabled -Dsysprof=disabled `
      -Dx11-backend=false -Dwayland-backend=false -Dmacos-backend=false -Dandroid-backend=false
  }
  Write-Host 'Compiling GTK with AccessKit'
  Invoke-Checked { meson compile -C $OutputRoot -j 2 }
  Invoke-Checked { meson install -C $OutputRoot }
  $LicenseRoot = Join-Path $Prefix 'share/licenses/clipboard-gtk'
  New-Item -ItemType Directory -Force $LicenseRoot | Out-Null
  Copy-Item (Join-Path $SourceRoot 'COPYING') (Join-Path $LicenseRoot 'GTK-COPYING')
  Copy-Item (Join-Path $AccessKitRoot 'LICENSE-*') $LicenseRoot
  @{
    gtk = '4.22.4'; gtkSHA256 = '51bd9f60c7d23a665a556c7364c21fb2e4e282566b3e7e092455e8f910330893'
    accesskitC = '0.18.0'; accesskitCommit = '0c52a8ce2357bbeb927f90dc9a1c19c8ec1bd2c3'
    dependencies = 'gvsbuild 2026.8.0'; rust = '1.87.0'; accessibility = 'accesskit'
  } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Prefix 'clipboard-runtime.json')
}
if (!(Test-Path (Join-Path $Prefix 'clipboard-runtime.json'))) { throw 'Verified AccessKit GTK runtime is missing' }
# A cache hit skips the runtime build, but Swift still needs the MSVC/SDK
# library paths before LIB is explicitly extended with the GTK prefix.
if ($ConfigureOnly) { Enter-VisualStudioEnvironment }
Set-GtkEnvironment
Invoke-Checked { & (Join-Path $Prefix 'bin/pkg-config.exe') --modversion gtk4 }
