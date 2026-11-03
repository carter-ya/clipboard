param([string]$Prefix = 'C:\gtk-build\gtk\x64\release',
      [string]$ImagePrefix = 'C:\clipboard-image-loaders')
$ErrorActionPreference = 'Stop'
# Reuse the fixed AccessKit runtime and its build environment. This small
# decoder overlay has its own cache; changing it must not rebuild all of GTK.
. (Join-Path $PSScriptRoot 'install-windows-gtk.ps1') -Prefix $Prefix -ConfigureOnly
$Receipt = Join-Path $ImagePrefix 'clipboard-image-runtime.json'
$SHA256 = '172f80e3626ec31520a970400f1a3694e04718f6c2cd2885f75250fb5a6995a4'
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
  # builtin_loaders=all alone does not enable BMP. Use the supported Windows
  # system decoders; leave the weakly maintained "others" formats disabled.
  Invoke-Checked {
    meson setup $Build $Source --prefix=$ImagePrefix --libdir=lib --buildtype=release --default-library=shared `
      -Dbuiltin_loaders=all -Dnative_windows_loaders=true -Dothers=disabled -Dglycin=disabled `
      -Dintrospection=disabled -Ddocumentation=false -Dman=false -Dtests=false -Dinstalled_tests=false -Dthumbnailer=disabled
  }
  Invoke-Checked { meson compile -C $Build -j 2 }
  Invoke-Checked { meson install -C $Build }
  $Licenses = Join-Path $ImagePrefix 'share/licenses/clipboard-gtk'
  New-Item -ItemType Directory -Force $Licenses | Out-Null
  Copy-Item (Join-Path $Source 'COPYING') (Join-Path $Licenses 'GdkPixbuf-COPYING')
  @{gdkPixbuf='2.44.7'; sha256=$SHA256; nativeWindowsLoaders=$true; dependencies='gvsbuild 2026.8.0'} |
    ConvertTo-Json | Set-Content -Encoding utf8 $Receipt
}
$Metadata = Get-Content -Raw $Receipt | ConvertFrom-Json
if ($Metadata.sha256 -ne $SHA256 -or $Metadata.nativeWindowsLoaders -ne $true) {
  throw 'Unexpected cached image runtime'
}
# The base runtime's dynamic SVG loader remains valid. Native formats are
# built into the DLL; do not replace its SVG registry with an empty cache.
foreach ($File in Get-ChildItem -LiteralPath $ImagePrefix -Recurse -File) {
  $Relative = $File.FullName.Substring($ImagePrefix.TrimEnd('\').Length + 1)
  if ($Relative -eq 'lib\gdk-pixbuf-2.0\2.10.0\loaders.cache') { continue }
  $Destination = Join-Path $Prefix $Relative
  New-Item -ItemType Directory -Force (Split-Path $Destination) | Out-Null
  Copy-Item -LiteralPath $File.FullName -Destination $Destination -Force
}
Invoke-Checked { python (Join-Path $PSScriptRoot 'normalize-windows-pkgconfig.py') --prefix $Prefix }
