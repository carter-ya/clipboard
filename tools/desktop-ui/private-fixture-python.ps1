function Resolve-PrivateFixturePython([string]$ExplicitPath) {
  if ([string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $ExplicitPath = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  }
  if (![IO.Path]::IsPathRooted($ExplicitPath) -or ![IO.File]::Exists($ExplicitPath)) {
    throw 'private_fixture_python_unavailable'
  }
  return [IO.Path]::GetFullPath($ExplicitPath)
}
