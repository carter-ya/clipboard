# All browser commands address only the private endpoint of the job-owned Chrome.
function Wait-BrowserCondition([scriptblock]$Predicate, [string]$Stage) {
  $deadline = [DateTime]::UtcNow.AddSeconds(40)
  while ([DateTime]::UtcNow -lt $deadline) {
    $value = & $Predicate
    if ($value) { return $value }
    Start-Sleep -Milliseconds 100
  }
  throw $Stage
}

function Invoke-BrowserRpc($Context, [string]$Method, [hashtable]$Parameters = @{}, [switch]$Page) {
  $Context.next++
  $packet = @{ id = $Context.next; method = $Method; params = $Parameters }
  if ($Page) { $packet.sessionId = $Context.session }
  $Context.native.Send(($packet | ConvertTo-Json -Compress -Depth 12))
  $timer = [Diagnostics.Stopwatch]::StartNew()
  for ($index = 0; $index -lt 64 -and $timer.ElapsedMilliseconds -lt 5000; $index++) {
    $remaining = [int][Math]::Max(1, 5000 - $timer.ElapsedMilliseconds)
    $reply = $Context.native.Receive($remaining) | ConvertFrom-Json
    if ($reply.id -ne $packet.id) { continue }
    if ($reply.error -or ($Page -and $reply.sessionId -cne $Context.session)) { throw 'owned_browser_protocol_error' }
    return $reply.result
  }
  throw 'owned_browser_protocol_deadline'
}

function Invoke-BrowserScript($Context, [string]$Expression) {
  $result = Invoke-BrowserRpc $Context 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } -Page
  if ($result.exceptionDetails) { throw 'owned_browser_script_exception' }
  return $result.result.value
}

function New-WindowsOwnedBrowser {
  if ($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT') { throw 'browser_requires_windows_actions' }
  if (!('ClipboardBrowserFixture' -as [type])) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -Path (Join-Path $PSScriptRoot 'windows-browser-fixture.cs') `
      -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
  }
  if (!('ClipboardKeyboardFixture' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'windows-keyboard-fixture.cs') `
      -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
  }
  $chrome = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object {
    Join-Path $_ 'Google/Chrome/Application/chrome.exe'
  } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (!$chrome) { throw 'runner_chrome_not_installed' }
  $native = $null
  $context = $null
  $ready = $false
  $startupError = $null
  try {
    $page = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'windows-browser-paste.html'))
    $native = [ClipboardBrowserFixture]::new([IO.Path]::GetFullPath($chrome), $page)
    $context = [PSCustomObject]@{ native = $native; next = 0; session = ''; window = [IntPtr]::Zero; keys = $null }
    Wait-BrowserCondition { $native.PortReady } 'owned_browser_endpoint_ready' | Out-Null
    # Endpoint-file creation alone is not an acknowledged WebSocket handshake.
    # Poll transport readiness on this same live owned process, never resend keys
    # or restart the browser. The existing per-stage bound remains 40 seconds.
    Wait-BrowserCondition { $native.Connect() } 'owned_browser_endpoint_handshake' | Out-Null
    $processes = (Invoke-BrowserRpc $context 'SystemInfo.getProcessInfo').processInfo
    $browser = @($processes | Where-Object { $_.type -ceq 'browser' })
    if ($browser.Count -ne 1 -or $browser[0].id -ne $native.ProcessId) { throw 'browser_protocol_process_identity' }
    $target = Wait-BrowserCondition {
      $targets = @((Invoke-BrowserRpc $context 'Target.getTargets').targetInfos)
      if ($targets.Count -gt 16) { throw 'owned_browser_target_bound' }
      $matches = @($targets | Where-Object { $_.type -ceq 'page' -and $_.url -ceq $native.PageUrl })
      if ($matches.Count -gt 1) { throw 'owned_browser_page_not_unique' }
      if ($matches.Count -eq 1) { $matches[0] }
    } 'owned_browser_exact_private_page'
    $context.session = (Invoke-BrowserRpc $context 'Target.attachToTarget' @{ targetId = $target.targetId; flatten = $true }).sessionId
    $context.window = Wait-BrowserCondition {
      $handle = $native.Window()
      if ($handle -ne [IntPtr]::Zero) { $handle }
    } 'owned_browser_native_window'
    $snapshot = Wait-BrowserCondition {
      Invoke-BrowserScript $context 'window.clipboardProbe ? window.clipboardProbe.snapshot() : null'
    } 'owned_browser_private_page_ready'
    if ($snapshot.owner -cne $native.Owner) { throw 'owned_browser_private_page_identity' }
    $context.keys = [ClipboardKeyboardFixture]::new($native.ProcessId)
    $ready = $true
    return $context
  } catch { $startupError = $_.Exception; throw }
  finally {
    if (!$ready) {
      try { Close-WindowsOwnedBrowser $context $native }
      catch {
        if ($startupError) { throw [AggregateException]::new('owned_browser_startup_and_cleanup_failed', [Exception[]]@($startupError, $_.Exception)) }
        throw
      }
      if ($startupError) { $startupError.Data['ownedBrowserCleanupComplete'] = [bool]($native -and $native.CleanupComplete) }
    }
  }
}

function Close-WindowsOwnedBrowser($Context, $Native = $null) {
  try { if ($Context -and $Context.keys) { $Context.keys.Dispose() } }
  finally {
    if ($Context) { $Native = $Context.native }
    if ($Native) { $Native.Dispose() }
  }
}

function Focus-WindowsOwnedBrowser($Context, [switch]$Reset) {
  $method = if ($Reset) { 'window.clipboardProbe.reset()' } else { 'window.clipboardProbe.focus()' }
  if (!(Invoke-BrowserScript $Context $method)) { throw 'owned_browser_dom_focus' }
  $Context.native.Activate($Context.window)
  Wait-BrowserCondition {
    [ClipboardKeyboardFixture]::GetForegroundWindow() -eq $Context.window -and
      (Invoke-BrowserScript $Context 'window.clipboardProbe.snapshot()').focused
  } 'owned_browser_foreground_and_editor_focus' | Out-Null
}

function Get-WindowsBrowserSnapshot($Context) {
  $snapshot = Invoke-BrowserScript $Context 'window.clipboardProbe.snapshot()'
  if ($snapshot.owner -cne $Context.native.Owner) { throw 'owned_browser_snapshot_identity' }
  return $snapshot
}

function Assert-WindowsBrowserPaste($Context, [string]$Kind) {
  $snapshot = Wait-BrowserCondition {
    $state = Get-WindowsBrowserSnapshot $Context
    if ($state.error) { throw 'owned_browser_paste_scope' }
    if (@($state.receipts).Count -eq 1 -and $state.receipts[0].ready) {
      if ($Kind -ne 'image' -or ($state.image -and $state.image.pixels)) { $state }
    }
  } ('browser_trusted_paste_ready_' + $Kind)
  $receipt = $snapshot.receipts[0]
  if (!$receipt.trusted) { throw 'browser_paste_must_be_trusted' }
  $native = $Context.native
  switch ($Kind) {
    'text' {
      if ($receipt.types -notcontains 'text/plain' -or @($receipt.files).Count -ne 0 -or
          $receipt.text.Replace("`r`n", "`n") -cne $native.PlainText -or
          $snapshot.text.Replace("`r`n", "`n") -cne $native.PlainText) { throw 'browser_plain_original_mismatch' }
    }
    'html' {
      if ($receipt.types -notcontains 'text/html' -or $receipt.html -notmatch '<b(?:\s|>)' -or
          $snapshot.content -cne $native.HtmlText -or $snapshot.bold -cnotcontains $native.BoldText) {
        throw 'browser_html_original_or_default_bold_render_mismatch'
      }
    }
    'image' {
      if (@($receipt.files).Count -ne 1 -or $receipt.files[0].type -cne 'image/png' -or
          [string]::IsNullOrEmpty($native.PngData) -or $receipt.files[0].data -cne $native.PngData -or $snapshot.image.width -ne 3 -or
          $snapshot.image.height -ne 2 -or $snapshot.image.pixels -cne $native.PixelData) {
        throw 'browser_png_original_or_default_render_pixels_mismatch'
      }
    }
    'files' {
      if ($receipt.types -notcontains 'Files' -or @($receipt.files).Count -ne 2) { throw 'browser_file_list_mismatch' }
      for ($index = 0; $index -lt 2; $index++) {
        $expected = $native.Files[$index]
        if ($receipt.files[$index].name -cne [IO.Path]::GetFileName($expected) -or
            $receipt.files[$index].data -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($expected))) {
          throw 'browser_file_name_or_original_bytes_mismatch'
        }
      }
    }
    default { throw 'unknown_browser_paste_kind' }
  }
  return @{ kind = $Kind; trusted = $true; types = @($receipt.types); files = @($receipt.files).Count; originalPreserved = $true }
}

function Get-WindowsBrowserDiagnostic($Context) {
  # Fixed-fixture comparisons and lengths only; do not retain paste contents.
  $snapshot = Get-WindowsBrowserSnapshot $Context
  $receipt = @($snapshot.receipts) | Select-Object -First 1
  return @{
    ownerMatches = $snapshot.owner -ceq $Context.native.Owner
    receiptCount = @($snapshot.receipts).Count
    trusted = [bool]$receipt.trusted
    types = @($receipt.types)
    htmlLength = ([string]$receipt.html).Length
    htmlHasBoldTag = [string]$receipt.html -match '<b(?:\s|>)'
    htmlContainsExpectedPlain = ([string]$receipt.html).Contains($Context.native.HtmlText)
    contentLength = ([string]$snapshot.content).Length
    expectedHtmlLength = $Context.native.HtmlText.Length
    contentMatchesHtml = $snapshot.content -ceq $Context.native.HtmlText
    clipboardTextMatchesHtml = $receipt.text -ceq $Context.native.HtmlText
    contentMatchesHtmlAfterNbsp = ([string]$snapshot.content).Replace([char]0xa0, [char]0x20) -ceq $Context.native.HtmlText
    boldMatchesAfterNbsp = @($snapshot.bold | ForEach-Object { $_.Replace([char]0xa0, [char]0x20) }) -ccontains $Context.native.BoldText
    sourceHtmlTextMatches = $snapshot.sourceHtml.text -ceq $Context.native.HtmlText
    sourceHtmlBoldMatches = $snapshot.sourceHtml.bold -ccontains $Context.native.BoldText
    contentMatchesHtmlWithFinalLF = $snapshot.content -ceq ($Context.native.HtmlText + "`n")
    contentMatchesHtmlWithFinalCRLF = $snapshot.content -ceq ($Context.native.HtmlText + "`r`n")
    boldCount = @($snapshot.bold).Count
    boldLengths = @($snapshot.bold | ForEach-Object { $_.Length })
    boldMatches = $snapshot.bold -ccontains $Context.native.BoldText
    boldMatchesWithFinalLF = $snapshot.bold -ccontains ($Context.native.BoldText + "`n")
    imageWidth = $snapshot.image.width
    imageHeight = $snapshot.image.height
    pixelsMatch = $snapshot.image.pixels -ceq $Context.native.PixelData
    pngFileBytesMatch = @($receipt.files).Count -eq 1 -and
      ![string]::IsNullOrEmpty($Context.native.PngData) -and $receipt.files[0].data -ceq $Context.native.PngData
    files = @($receipt.files).Count
  }
}
