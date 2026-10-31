param([Parameter(Mandatory=$true)][string]$Binary, [Parameter(Mandatory=$true)][string]$Output,
      [string]$GtkPrefix = 'C:/gtk-build/gtk/x64/release')
$ErrorActionPreference = 'Stop'
$Repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Version = (Get-Content (Join-Path $Repository 'Desktop/Sources/ClipboardDesktop/Resources/VERSION') -Raw).Trim()
$Result = & python (Join-Path $PSScriptRoot 'package-desktop.py') --binary $Binary --output $Output --platform windows --gtk-prefix $GtkPrefix
if ($LASTEXITCODE -ne 0) { throw 'Windows package assembly failed' }
$Package = ($Result -join "`n") | ConvertFrom-Json
$Compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (!(Test-Path $Compiler)) { throw 'Inno Setup 6 is required on the native builder' }
& $Compiler ('/DBundleDir=' + $Package.directory) ('/DDesktopVersion=' + $Version) ('/DArtifactDir=' + (Resolve-Path $Output).Path) (Join-Path $Repository 'Desktop/Packaging/clipboard.iss')
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed' }
$Installer = Join-Path $Output ('ClipboardDesktop-' + $Version + '-windows-x64-setup.exe')
$Checksum = (Get-FileHash -Algorithm SHA256 $Installer).Hash.ToLowerInvariant()
($Checksum + '  ' + (Split-Path $Installer -Leaf)) | Out-File -Append -Encoding utf8 (Join-Path $Output 'SHA256SUMS')
