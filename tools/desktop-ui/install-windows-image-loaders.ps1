param([string]$Prefix = 'C:\gtk-build\gtk\x64\release',
      [string]$ImagePrefix = 'C:\clipboard-image-loaders')
$ErrorActionPreference = 'Stop'
# Reuse the fixed GTK/AccessKit SDK. Only the native BMP module is installed;
# existing PNG/JPEG/TIFF loaders and their bounded decode paths stay unchanged.
. (Join-Path $PSScriptRoot 'install-windows-gtk.ps1') -Prefix $Prefix -ConfigureOnly
$InstalledReceipt = Join-Path $Prefix 'clipboard-image-runtime.json'
if (Test-Path $InstalledReceipt) {
  $Installed = Get-Content -Raw $InstalledReceipt | ConvertFrom-Json
  if ($Installed.nativeWindowsLoaders -eq $true) { throw 'Restore the fixed GTK base before installing the BMP-only decoder' }
}
$BaseLibrary = Join-Path $Prefix 'bin/gdk_pixbuf-2.0-0.dll'
$BaseDigest = (Get-FileHash $BaseLibrary).Hash.ToLowerInvariant()
$Receipt = Join-Path $ImagePrefix 'clipboard-image-runtime.json'
$SHA256 = '172f80e3626ec31520a970400f1a3694e04718f6c2cd2885f75250fb5a6995a4'
$RelativeLoader = 'lib\gdk-pixbuf-2.0\2.10.0\loaders\pixbufloader-gdip-bmp.dll'
if (!(Test-Path $Receipt)) {
  $BuildRoot = Join-Path $env:RUNNER_TEMP 'clipboard-pixbuf-source'
  New-Item -ItemType Directory -Force $BuildRoot, $ImagePrefix | Out-Null
  $Archive = Join-Path $BuildRoot 'gdk-pixbuf-2.44.7.tar.xz'
  Get-VerifiedFile 'https://download.gnome.org/sources/gdk-pixbuf/2.44/gdk-pixbuf-2.44.7.tar.xz' $Archive $SHA256
  Invoke-Checked { python (Join-Path $PSScriptRoot 'extract-gtk-source.py') $Archive $BuildRoot --skip-pixbuf-test-images }
  Invoke-Checked { python -m pip install meson==1.9.1 ninja==1.13.0 }
  $env:CC = 'cl'; $env:CXX = 'cl'
  $Source = Join-Path $BuildRoot 'gdk-pixbuf-2.44.7'
  $Build = Join-Path $BuildRoot 'build'
  Invoke-Checked {
    meson setup $Build $Source --prefix=$ImagePrefix --libdir=lib --buildtype=release --default-library=shared `
      -Dbuiltin_loaders=png -Dnative_windows_loaders=true -Dothers=disabled -Dglycin=disabled `
      -Dintrospection=disabled -Ddocumentation=false -Dman=false -Dtests=false -Dinstalled_tests=false -Dthumbnailer=disabled
  }
  # Build just this module and its build-time library dependency. Do not install
  # that library, its SDK, or any other native loaders over the fixed runtime.
  Invoke-Checked { meson compile -C $Build -j 2 pixbufloader-gdip-bmp }
  $Module = @(Get-ChildItem -LiteralPath $Build -Recurse -Filter 'pixbufloader-gdip-bmp.dll')
  if ($Module.Count -ne 1) { throw 'Native BMP module build output is ambiguous' }
  $CachedLoader = Join-Path $ImagePrefix $RelativeLoader
  New-Item -ItemType Directory -Force (Split-Path $CachedLoader) | Out-Null
  Copy-Item -LiteralPath $Module[0].FullName -Destination $CachedLoader
  $Licenses = Join-Path $ImagePrefix 'share/licenses/clipboard-gtk'
  New-Item -ItemType Directory -Force $Licenses | Out-Null
  Copy-Item (Join-Path $Source 'COPYING') (Join-Path $Licenses 'GdkPixbuf-COPYING')
  @{gdkPixbuf='2.44.7'; sha256=$SHA256; nativeWindowsFormats=@('bmp'); dependencies='gvsbuild 2026.8.0';
    moduleSHA256=(Get-FileHash $CachedLoader).Hash.ToLowerInvariant()} |
    ConvertTo-Json | Set-Content -Encoding utf8 $Receipt
}
$Metadata = Get-Content -Raw $Receipt | ConvertFrom-Json
$CachedLoader = Join-Path $ImagePrefix $RelativeLoader
if ($Metadata.sha256 -ne $SHA256 -or @($Metadata.nativeWindowsFormats).Count -ne 1 -or
    $Metadata.nativeWindowsFormats[0] -ne 'bmp' -or
    (Get-FileHash $CachedLoader).Hash.ToLowerInvariant() -ne $Metadata.moduleSHA256) {
  throw 'Unexpected cached BMP decoder'
}
$Destination = Join-Path $Prefix $RelativeLoader
New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
Copy-Item -LiteralPath $CachedLoader -Destination $Destination -Force
# Query the module against the existing runtime, then make its registry path
# relative so private/per-user installations never need the builder's SDK.
$Entry = @(& (Join-Path $Prefix 'bin/gdk-pixbuf-query-loaders.exe') $Destination)
if ($LASTEXITCODE -ne 0) { throw 'Native BMP loader registration failed' }
$Entry = @($Entry | Where-Object { $_ -and !$_.StartsWith('#') })
if ($Entry.Count -lt 5 -or $Entry[0] -notmatch 'pixbufloader-gdip-bmp\.dll"$' -or
    $Entry[1] -notmatch '^"bmp" ') { throw 'Unexpected native BMP registry entry' }
$Entry[0] = '"' + $RelativeLoader.Replace('\','/') + '"'
$Cache = Join-Path $Prefix 'lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'
$Previous = [IO.File]::ReadAllText($Cache)
$Blocks = @([regex]::Split($Previous, '\r?\n\r?\n') | Where-Object { $_ -notmatch 'pixbufloader-gdip-bmp\.dll' })
[IO.File]::WriteAllText($Cache, (($Blocks -join "`n`n").TrimEnd() + "`n`n" + ($Entry -join "`n") + "`n`n"), [Text.UTF8Encoding]::new($false))
$Licenses = Join-Path $Prefix 'share/licenses/clipboard-gtk'
New-Item -ItemType Directory -Force $Licenses | Out-Null
Copy-Item (Join-Path $ImagePrefix 'share/licenses/clipboard-gtk/GdkPixbuf-COPYING') $Licenses -Force
if ((Get-FileHash $BaseLibrary).Hash.ToLowerInvariant() -ne $BaseDigest) {
  throw 'The existing image decoder library changed'
}
$Metadata | Add-Member -NotePropertyName basePixbufSHA256 -NotePropertyValue $BaseDigest -Force
$Metadata | ConvertTo-Json | Set-Content -Encoding utf8 $InstalledReceipt
