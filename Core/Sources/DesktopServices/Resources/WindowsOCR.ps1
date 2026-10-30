param([switch]$Probe, [string]$Language)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
  $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType=WindowsRuntime]
  $null = [Windows.Storage.Streams.DataWriter, Windows.Foundation, ContentType=WindowsRuntime]
  if ($Language) {
    $null = [Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]
    $requested = New-Object Windows.Globalization.Language $Language
    if (![Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($requested)) { throw 'language_unavailable' }
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($requested)
  } else {
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  }
  if (!$engine) { throw 'unavailable' }
  if ($Probe) { [Console]::Write('available'); exit 0 }
  function Await-Result($Operation, [Type]$ResultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    if (!$method) { throw 'unavailable' }
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.GetAwaiter().GetResult()
  }
  $encoded = [Console]::In.ReadToEnd()
  if ($encoded.Length -gt 24 * 1024 * 1024) { throw 'too_large' }
  $bytes = [Convert]::FromBase64String($encoded)
  if (!$bytes.Length -or $bytes.Length -gt 16 * 1024 * 1024) { throw 'too_large' }
  $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
  $writer = New-Object Windows.Storage.Streams.DataWriter $stream
  try {
    $writer.WriteBytes($bytes)
    $null = Await-Result ($writer.StoreAsync()) ([uint32])
    $writer.DetachStream() | Out-Null
    $stream.Seek(0)
    $decoder = Await-Result ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    if ($decoder.PixelWidth -gt 32768 -or $decoder.PixelHeight -gt 32768 -or
        [long]$decoder.PixelWidth * [long]$decoder.PixelHeight -gt 80000000) { throw 'too_large' }
    $transform = New-Object Windows.Graphics.Imaging.BitmapTransform
    $scale = [Math]::Min(1.0, [Windows.Media.Ocr.OcrEngine]::MaxImageDimension / [double][Math]::Max($decoder.PixelWidth, $decoder.PixelHeight))
    $transform.ScaledWidth = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelWidth * $scale))
    $transform.ScaledHeight = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelHeight * $scale))
    $bitmap = Await-Result ($decoder.GetSoftwareBitmapAsync(
      [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
      $transform, [Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,
      [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
    try {
      $result = Await-Result ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
      $text = $result.Text
      if ($text.Length -gt 8000) { $text = $text.Substring(0, 8000) }
      [Console]::Write($text)
    } finally { $bitmap.Dispose() }
  } finally { $writer.Dispose(); $stream.Dispose() }
} catch {
  # Never include image bytes, recognized content, exception bodies or paths.
  [Console]::Error.Write('ocr_unavailable')
  exit 1
}
