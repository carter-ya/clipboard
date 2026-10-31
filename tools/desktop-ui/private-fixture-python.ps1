function Resolve-PrivateFixturePython([string]$ExplicitPath) {
  if ([string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $ExplicitPath = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  }
  if (![IO.Path]::IsPathRooted($ExplicitPath) -or ![IO.File]::Exists($ExplicitPath)) {
    throw 'private_fixture_python_unavailable'
  }
  return [IO.Path]::GetFullPath($ExplicitPath)
}

function Set-PrivateFixtureInputEncoding([Diagnostics.ProcessStartInfo]$Info) {
  # Modern .NET can choose a preamble-free writer. Windows PowerShell 5.1 uses
  # .NET Framework without this property; the fixture also accepts its first BOM.
  if ($null -ne $Info.PSObject.Properties['StandardInputEncoding']) {
    $Info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  }
}
