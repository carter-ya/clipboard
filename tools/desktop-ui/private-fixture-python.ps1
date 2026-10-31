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
  # The owned fixture accepts ASCII line commands. Console encodings on Windows
  # can prepend a UTF-8 BOM to StreamWriter's first command; specify no preamble.
  $Info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
}
