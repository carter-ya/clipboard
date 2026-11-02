# Exercise the actual mode-selection statements against asynchronous provider
# states. No native types, processes, desktop, clipboard or input are loaded.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'windows-keyboard-acceptance.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'actual_ime_acceptance_syntax' }
$definitions = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true))
foreach ($definition in $definitions | Where-Object { $_.Name -ceq 'Wait-WindowsImeProfileStable' }) {
  Invoke-Expression $definition.Extent.Text
}
$entry = @($definitions | Where-Object { $_.Name -ceq 'Invoke-WindowsChineseImeAcceptance' })
if ($entry.Count -ne 1) { throw 'actual_ime_mode_entry_missing' }
$statements = $entry[0].Body.EndBlock.Statements
$start = -1; $end = -1
for ($i = 0; $i -lt $statements.Count; $i++) {
  $text = $statements[$i].Extent.Text
  if ($text.Contains('ime_actual_os_shortcut_selects_chinese_profile')) { $start = $i }
  if ($end -lt 0 -and $text.Contains('.TypeLatinKeys(')) { $end = $i }
}
if ($start -lt 0 -or $end -le $start) { throw 'actual_ime_mode_statements_missing' }
function Save-WindowsImeTargetState { }
function Wait-For([scriptblock]$Predicate, [string]$Stage, [int]$Seconds = 40) {
  if ($Seconds -ne 40) { throw 'ime_mode_must_keep_existing_deadline' }
  for ($tick = 0; $tick -lt 20; $tick++) {
    try { $value = & $Predicate; if ($value) { return $value } } catch { }
  }
  throw ('timeout_' + $Stage)
}
function Status([bool]$Open, [UInt64]$Conversion = 1, [bool]$Query = $true, [int]$Language = 0x0804) {
  [PSCustomObject]@{ Open = $Open; Conversion = $Conversion; QuerySucceeded = $Query;
    WindowPresent = $true; Layout = [long]$Language; Language = $Language }
}
$nativeWindowHandle = [IntPtr]1
$ready = Status $true
$closed = Status $false
$english = Status $true 0
$unavailable = Status $false 1 $false
$absent = Status $false
$absent.WindowPresent = $false
$oscillating = @()
foreach ($tick in 1..22) { if ($tick % 2) { $oscillating += $closed } else { $oscillating += $ready } }
$cases = @(
  @{ name = 'initial_closed_then_native_without_a_mode_key'; before = @($closed, $ready, $ready, $ready); after = @($ready); shifts = 0; minReads = 4 },
  @{ name = 'already_native'; before = @($ready); after = @($ready); shifts = 0; minReads = 3 },
  @{ name = 'initial_query_pending'; before = @((Status $false 1 $false), $ready); after = @($ready); shifts = 0; minReads = 4 },
  @{ name = 'initial_layout_pending'; before = @((Status $true 1 $true 0x0409), $ready); after = @($ready); shifts = 0; minReads = 4 },
  @{ name = 'stable_closed_needs_one_mode_key'; before = @($closed); after = @($ready); shifts = 1; minReads = 6 },
  @{ name = 'stable_english_needs_one_mode_key'; before = @($english); after = @($ready); shifts = 1; minReads = 6 },
  @{ name = 'post_key_transient_native_is_not_completion'; before = @($english); after = @($ready, $closed, $ready, $ready, $ready); shifts = 1; minReads = 8 },
  @{ name = 'unavailable_query_never_changes_mode'; before = @($unavailable); after = @($ready); shifts = 0; minReads = 20; failure = 'timeout_ime_native_profile_settled' },
  @{ name = 'absent_ime_never_changes_mode'; before = @($absent); after = @($ready); shifts = 0; minReads = 20; failure = 'timeout_ime_native_profile_settled' },
  @{ name = 'oscillating_profile_never_changes_mode'; before = $oscillating; after = @($ready); shifts = 0; minReads = 20; failure = 'timeout_ime_native_profile_settled' }
)
foreach ($case in $cases) {
  $KeyboardPeer = [PSCustomObject]@{ States = $case.before; After = $case.after; Index = 0; Shifts = 0; Reads = 0 }
  $KeyboardPeer | Add-Member ScriptMethod ReadTargetImeStatus {
    param([IntPtr]$Target)
    if ($Target -ne [IntPtr]1) { throw 'ime_mode_target_changed' }
    $index = [Math]::Min($this.Index, $this.States.Count - 1)
    $this.Index++; $this.Reads++
    return $this.States[$index]
  }
  $KeyboardPeer | Add-Member ScriptMethod TargetChineseMode {
    param([IntPtr]$Target)
    $state = $this.ReadTargetImeStatus($Target)
    return $state.Open -and ($state.Conversion -band 1) -ne 0
  }
  $KeyboardPeer | Add-Member ScriptMethod Chord {
    param([IntPtr]$Target, $Keys)
    if ($Target -ne [IntPtr]1 -or $Keys.GetType() -ne [UInt16[]] -or $Keys.Count -ne 1 -or $Keys[0] -ne 0x10) {
      throw 'ime_mode_changed_the_actual_key_batch'
    }
    $this.Shifts++
    $this.States = $this.After; $this.Index = 0
  }
  $failure = ''
  try { for ($i = $start + 1; $i -lt $end; $i++) { Invoke-Expression $statements[$i].Extent.Text } }
  catch { $failure = $_.Exception.Message }
  if ($failure -cne [string]$case.failure -or $KeyboardPeer.Shifts -ne $case.shifts -or $KeyboardPeer.Reads -lt $case.minReads) {
    throw ('actual_mode_gate_acts_before_provider_is_stable_' + $case.name)
  }
}
Write-Host ('Actual Windows IME mode gate passes ' + $cases.Count + ' asynchronous state cases without input')
