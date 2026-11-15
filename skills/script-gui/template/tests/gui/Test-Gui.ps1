<#
  Test-Gui.ps1 - checks for a script-gui window. Needs no admin and touches nothing outside a temp
  folder. Run it after ANY change to gui\ or to a script that asks a question:

      powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Test-Gui.ps1

  Parts:
    A  house rules     every gui file parses, is pure ASCII, has no BOM; the launcher is CRLF
    B  catalog         every script, Ask, hook and prompt the catalog names exists; each prompt's
                       text is printed by the script itself (Write-Host -NoNewline), because
                       Read-Host's own prompt is invisible when stdin is redirected
    C  headless core   a no-newline prompt is seen and answered over stdin; closing a dialog
                       refuses; a typed word is required
    D  window          the XAML loads with every named control; the typed-word gate and the
                       colour tokens hold (-SelfTest)
    E  demo run        ONLY while the catalog still points at gui\demo: drives the real window
                       through both modes with canned answers
  Parts A-D are generic and stay valid after the catalog points at the real tool. Replace part E
  with runs of the real catalog against STUB copies of the tool's scripts (stubs that record
  "script|arguments" and write the one file the next step needs), never the real scripts.

  Exit 0 = all checks passed. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
param(
    [string]$ToolRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$KeepWork
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$gui = Join-Path $ToolRoot 'gui'
$script:Failures = New-Object System.Collections.ArrayList
$script:Passes = 0
function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Passes++; Write-Host ('  [pass] ' + $Message) -ForegroundColor Green }
    else { [void]$script:Failures.Add($Message); Write-Host ('  [FAIL] ' + $Message) -ForegroundColor Red }
}
$psExe = Join-Path $PSHOME 'powershell.exe'
$work = Join-Path $env:TEMP ('script-gui-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force

# ---- A: house rules --------------------------------------------------------------------------------
Write-Host 'A. House rules'
$files = @(Get-ChildItem -LiteralPath $gui -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.xaml', '.json' })
$files += @(Get-ChildItem -LiteralPath $ToolRoot -File -Filter 'Run-*Gui.bat')
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $rel = $f.FullName.Substring($ToolRoot.TrimEnd('\').Length + 1)
    Check (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) ($rel + ' is pure ASCII')
    Check (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) ($rel + ' has no BOM')
    if ($f.Extension -in '.ps1', '.psm1') {
        $e = $null; $t = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
        Check (@($e).Count -eq 0) ($rel + ' parses')
    }
    if ($f.Extension -eq '.bat') {
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        Check (($text -replace "`r`n", '') -notmatch "`n") ($rel + ' has CRLF line ends only')
    }
}

# ---- B: catalog ------------------------------------------------------------------------------------
Write-Host 'B. Catalog'
Import-Module (Join-Path $gui 'Gui.Core.psm1') -Force
$toolModule = Join-Path $gui 'Gui.Tool.psm1'
if (Test-Path -LiteralPath $toolModule -PathType Leaf) { Import-Module $toolModule -Force }
$catalog = Get-GuiCatalog
$modes = @(Get-GuiModes $catalog)
Check ($modes.Count -ge 1) 'the catalog has at least one mode'
$askNames = @()
$asks = Get-GuiProp $catalog 'Asks' $null
if ($asks) { $askNames = @($asks.PSObject.Properties | ForEach-Object { $_.Name }) }
$stepIds = @{}
foreach ($step in @($catalog.Steps)) {
    $stepIds[[string]$step.Id] = $true
    foreach ($call in @($step.Calls)) {
        $s = [string](Get-GuiProp $call 'Script' '')
        Check ($s -and (Test-Path -LiteralPath (Join-Path $ToolRoot $s) -PathType Leaf)) ('step ' + $step.Id + ': script exists - ' + $s)
        $a = [string](Get-GuiProp $call 'Ask' '')
        if ($a) { Check ($askNames -contains $a) ('step ' + $step.Id + ': Ask "' + $a + '" is defined') }
        foreach ($h in 'After', 'Before') {
            $n = [string](Get-GuiProp $call $h '')
            if ($n) { Check ($null -ne (Get-GuiHook ($h + ':' + $n))) ('step ' + $step.Id + ': ' + $h + ' hook "' + $n + '" is registered (gui\Gui.Tool.psm1)') }
        }
    }
}
foreach ($m in $modes) {
    $sess = New-GuiSession -Mode $m.Name -ToolRoot $ToolRoot -RunRootBase $work
    Check ($sess.Plan.Count -ge 1) ('mode ' + $m.Name + ' runs at least one call')
}
foreach ($row in (Get-GuiPromptTable $catalog)) {
    $id = [string]$row.Id
    $buttons = @(ConvertTo-GuiItems $row.Buttons)
    Check ($buttons.Count -ge 1) ('prompt ' + $id + ' has buttons')
    $word = [string](Get-GuiProp $row 'TypeWord' '')
    if ($word) { Check (@($buttons | Where-Object { [bool](Get-GuiProp $_ 'NeedsWord' $false) }).Count -ge 1) ('prompt ' + $id + ': a button needs the typed word') }
    # Closing the dialog must never approve: Refuse may not equal what an approving button sends.
    $approving = @($buttons | Where-Object { [bool](Get-GuiProp $_ 'NeedsWord' $false) } | ForEach-Object { [string](Get-GuiProp $_ 'Send' '') })
    Check ($approving -notcontains [string](Get-GuiProp $row 'Refuse' '')) ('prompt ' + $id + ': closing the dialog does not send the approving answer')
    foreach ($needle in @(ConvertTo-GuiItems $row.Needles)) {
        foreach ($s in @(ConvertTo-GuiItems (Get-GuiProp $row 'Scripts' $null))) {
            $p = Join-Path $ToolRoot ([string]$s)
            $src = $(if (Test-Path -LiteralPath $p -PathType Leaf) { [IO.File]::ReadAllText($p) } else { '' })
            Check ($src.Contains([string]$needle)) ('prompt ' + $id + ': ' + $s + ' still contains its text')
            # The text must be printed by Write-Host (not only handed to Read-Host, which stays silent
            # when stdin is redirected).
            $printed = $false
            foreach ($line in ($src -split "`r?`n")) { if ($line.Contains([string]$needle) -and $line -match 'Write-Host' -and $line -match '-NoNewline') { $printed = $true } }
            Check $printed ('prompt ' + $id + ': ' + $s + ' prints it with Write-Host -NoNewline')
        }
    }
}

# ---- C: headless core ------------------------------------------------------------------------------
Write-Host 'C. Headless core (a prompt without a line end, answered over stdin)'
$probe = Join-Path $work 'probe.ps1'
@'
Write-Host 'working...'
Write-Host 'Really do it? [y/N]' -NoNewline
$a = Read-Host
Write-Host ('GOT=[' + $a + ']')
if ($a -eq 'y') { exit 0 } else { exit 3 }
'@ | Set-Content -LiteralPath $probe -Encoding ASCII
$probeCatalog = [pscustomobject]@{ Prompts = @([pscustomobject]@{ Id = 'P'; Needles = @('Really do it? [y/N]'); TypeWord = 'GO'; Refuse = 'n'
            Buttons = @([pscustomobject]@{ Text = 'Do it'; Send = 'y'; NeedsWord = $true }, [pscustomobject]@{ Text = 'No'; Send = 'n' }) }) }
function Invoke-Probe {
    param($ButtonIndex, [string]$Typed)
    $saved = Set-GuiConsoleEncoding
    try {
        $child = Start-GuiChild -ScriptPath $probe
        $lines = @(); $seen = $false; $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $u = Update-GuiChild -Child $child
            $lines += @($u.Lines)
            if ($u.Exited) { return [pscustomobject]@{ ExitCode = $u.ExitCode; Lines = $lines; Seen = $seen } }
            $pp = Get-GuiPendingPrompt -Child $child -Catalog $probeCatalog
            if ($pp -and $pp.Kind -eq 'Known') {
                $seen = $true
                Send-GuiAnswer -Child $child -Text (Resolve-GuiPromptSend -Row $pp.Row -ButtonIndex $ButtonIndex -Typed $Typed).Send
            }
            Start-Sleep -Milliseconds 100
        }
        Stop-GuiChild $child
        return [pscustomobject]@{ ExitCode = -1; Lines = $lines; Seen = $seen }
    } finally { Restore-GuiConsoleEncoding $saved }
}
$r = Invoke-Probe -ButtonIndex 0 -Typed 'GO'
Check ($r.Seen) 'the prompt printed without a line end is recognised'
Check ($r.ExitCode -eq 0 -and (@($r.Lines) -contains 'GOT=[y]')) 'approve + the typed word sends y, received clean (no byte order mark)'
$r = Invoke-Probe -ButtonIndex 0 -Typed 'go'
Check ($r.ExitCode -eq 3) 'approve with the wrong word sends the refusing answer'
$r = Invoke-Probe -ButtonIndex $null -Typed 'GO'
Check ($r.ExitCode -eq 3) 'closing the dialog sends the refusing answer'
$r = Invoke-Probe -ButtonIndex 1 -Typed ''
Check ($r.ExitCode -eq 3) 'the refusing button sends the refusing answer'
Check ((ConvertTo-GuiArg 'C:\a b\c (1)\') -eq '"C:\a b\c (1)\\"') 'a path with spaces, parentheses and a trailing backslash is quoted correctly'

# ---- D: window -------------------------------------------------------------------------------------
Write-Host 'D. Window'
$start = Join-Path $gui 'Start-Gui.ps1'
$out = & $psExe -NoProfile -STA -ExecutionPolicy Bypass -File $start -LoadOnly -AllowNotElevated 2>&1 | Out-String
Check ($LASTEXITCODE -eq 0 -and $out -match 'LOAD_OK') ('the XAML loads with every named control' + $(if ($out -notmatch 'LOAD_OK') { ' :: ' + $out.Trim() } else { '' }))
foreach ($theme in 'Light', 'Dark') {
    $out = & $psExe -NoProfile -STA -ExecutionPolicy Bypass -File $start -SelfTest -AllowNotElevated -Theme $theme 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0 -and $out -match 'SELFTEST_OK') ('typed-word gate and colour tokens hold (' + $theme + ')' + $(if ($out -notmatch 'SELFTEST_OK') { ' :: ' + $out.Trim() } else { '' }))
}

# ---- E: demo run (only while the catalog still points at gui\demo) --------------------------------
$isDemo = @($catalog.Steps | ForEach-Object { $_.Calls } | Where-Object { ([string](Get-GuiProp $_ 'Script' '')) -like 'gui\demo\*' }).Count -gt 0
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isDemo -and $isAdmin) { Write-Host 'E. Demo run - SKIPPED: run this test from a window that is NOT elevated (the test hooks refuse to work elevated).' -ForegroundColor Yellow }
if ($isDemo -and -not $isAdmin) {
    Write-Host 'E. Demo run through the real window'
    function Invoke-Window {
        param([string]$ModeName, $Answers)
        $result = Join-Path $work ('result-' + [guid]::NewGuid().ToString('N') + '.json')
        $ansFile = Join-Path $work 'answers.json'
        ($Answers | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ansFile -Encoding ASCII
        $env:SCRIPTGUI_TEST = '1'; $env:SCRIPTGUI_TEST_ANSWERS = $ansFile
        try { & $psExe -NoProfile -STA -ExecutionPolicy Bypass -File $start -AutoStart -Mode $ModeName -ResultPath $result -RunRootBase (Join-Path $work 'runs') -AllowNotElevated | Out-Null }
        finally { $env:SCRIPTGUI_TEST = $null; $env:SCRIPTGUI_TEST_ANSWERS = $null }
        if (-not (Test-Path -LiteralPath $result)) { return $null }
        return ([IO.File]::ReadAllText($result) | ConvertFrom-Json)
    }
    $r = Invoke-Window 'Check' @{}
    Check ($null -ne $r -and -not $r.Stopped -and $r.FinalStatus -eq 0) 'Check mode finishes cleanly'
    Check ($null -ne $r -and $r.Steps.'2' -eq 'not part of this mode') 'Check mode never runs the change step'
    Check ($null -ne $r -and -not (Test-Path -LiteralPath (Join-Path $r.RunRoot 'change.txt'))) 'Check mode changed nothing'

    $r = Invoke-Window 'Full' @{ Options = @{ Value = 'accept'; Checks = @{ Thorough = $true }; Text = 'hello there' }; ApplyConfirm = @{ Value = '0'; Text = 'APPLY' } }
    $changeFile = $(if ($r) { Join-Path $r.RunRoot 'change.txt' } else { '' })
    Check ($null -ne $r -and (Test-Path -LiteralPath $changeFile)) 'Full mode: accepted and typed APPLY -> the change ran'
    Check ($changeFile -and (Test-Path -LiteralPath $changeFile) -and ([IO.File]::ReadAllText($changeFile).Trim() -eq 'applied thorough note=hello there')) 'the tick box and the typed text reached the script as arguments'
    Check ($null -ne $r -and @($r.ResultItems | Where-Object { $_.Label -eq 'Summary' -and $_.Value -eq '3 items changed' }).Count -eq 1) 'a value the script printed was captured for the results panel'

    $r = Invoke-Window 'Full' @{ Options = @{ Value = 'accept' } }
    Check ($null -ne $r -and -not (Test-Path -LiteralPath (Join-Path $r.RunRoot 'change.txt'))) 'Full mode: confirmation box closed -> nothing changed'
    Check ($null -ne $r -and $r.Steps.'2' -like 'done - Not applied*') 'the declined change is shown as declined, not as a failure'

    $r = Invoke-Window 'Full' @{ Options = @{ Value = 'accept' }; ApplyConfirm = @{ Value = '0'; Text = 'apply' } }
    Check ($null -ne $r -and -not (Test-Path -LiteralPath (Join-Path $r.RunRoot 'change.txt'))) 'Full mode: wrong word typed -> nothing changed'

    $r = Invoke-Window 'Full' @{}
    Check ($null -ne $r -and $r.Steps.'2' -like 'skipped*' -and -not (Test-Path -LiteralPath (Join-Path $r.RunRoot 'change.txt'))) 'Full mode: options box closed -> the change step is skipped'
}

if (-not $KeepWork) { try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { } } else { Write-Host ('Work folder kept: ' + $work) }
Write-Host ''
if ($script:Failures.Count -eq 0) { Write-Host ('ALL PASSED: ' + $script:Passes + ' checks') -ForegroundColor Green; exit 0 }
Write-Host ($script:Failures.Count.ToString() + ' FAILED of ' + ($script:Passes + $script:Failures.Count)) -ForegroundColor Red
exit 1
