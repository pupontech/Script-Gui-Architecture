<#
  Gui.Core.psm1 - the logic behind a script-gui window. NO WPF TYPES HERE.

  The window is a second front end, never a second engine. Everything in this module either
    * turns gui\steps.json + the operator's answers into command lines for the tool's own
      scripts, in catalog order (Get-GuiNextAction / Complete-GuiAction),
    * starts ONE child powershell.exe at a time and pumps its output without blocking
      (Start-GuiChild / Update-GuiChild / Send-GuiAnswer), or
    * reads files the tool's scripts already wrote (Read-GuiJson and friends).
  It contains none of the tool's own logic. Tool-specific extras go in an optional
  gui\Gui.Tool.psm1 that calls Register-GuiHook.

  Because it has no WPF types it is tested headless (tests\gui\Test-Gui.ps1).
  Windows PowerShell 5.1, pure ASCII, no BOM.

  Kit: script-gui (rinv-ai .claude/skills/script-gui). Derived from the ScreenConnect
  Cleanup GUI (screenconnect-cleanup/gui, docs/14-gui-architecture.md).
#>

Set-StrictMode -Version 2.0

$script:GuiKitVersion = '2026-11-15.1'
$script:Hooks = @{}

function Get-GuiKitVersion { return $script:GuiKitVersion }

# ---------------------------------------------------------------------------------------
# Argument quoting
# ---------------------------------------------------------------------------------------

function ConvertTo-GuiArg {
    # One value -> one command-line token, quoted the way CommandLineToArgvW expects.
    # Paths contain spaces and parentheses; nothing is ever routed through cmd.exe.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([string]('\' * ($backslashes * 2 + 1)))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append([string]('\' * $backslashes)); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append([string]('\' * ($backslashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-GuiArgString {
    param([string[]]$Values)
    return ((@($Values) | ForEach-Object { ConvertTo-GuiArg $_ }) -join ' ')
}

# ---------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------

function Get-GuiProp {
    # A property of a JSON object (PSCustomObject) or a key of a hashtable, or the default.
    # (A hashtable's keys are NOT in .PSObject.Properties - that mistake once left an approve
    # button enabled.)
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function ConvertTo-GuiItems {
    # The single-element array trap: a one-item JSON array can arrive as a bare object, and an
    # empty object means none.
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    if ($Value -is [pscustomobject] -and @($Value.PSObject.Properties).Count -eq 0) { return @() }
    return @($Value)
}

function Read-GuiJson {
    # Read-only; tolerates a missing, empty or half-written file.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Data = $null; Error = 'not available yet' }
    }
    try {
        $text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ Ok = $false; Data = $null; Error = 'file is empty' } }
        return [pscustomobject]@{ Ok = $true; Data = ($text | ConvertFrom-Json); Error = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Data = $null; Error = ('could not be read: ' + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------------------------------
# Hooks (the only place tool-specific code plugs in; see gui\Gui.Tool.psm1)
# ---------------------------------------------------------------------------------------

function Register-GuiHook {
    # Kinds:  After:<name>   param($Session, $Action, $ExitCode)  may return @{ Status=; Message=; Stop= }
    #         Before:<name>  param($Session, $Action)
    #         Summary        param($Session)  returns @( @{ Label=; Value=; Tone= } ... ) for the finish panel
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Script)
    $script:Hooks[$Name] = $Script
}

function Get-GuiHook {
    param([string]$Name)
    if ($script:Hooks.ContainsKey($Name)) { return $script:Hooks[$Name] }
    return $null
}

# ---------------------------------------------------------------------------------------
# Catalog and session
# ---------------------------------------------------------------------------------------

function Get-GuiCatalog {
    param([string]$Path = (Join-Path $PSScriptRoot 'steps.json'))
    $text = [IO.File]::ReadAllText($Path)
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        # ConvertFrom-Json's own message repeats the whole file; keep only its first sentence.
        $why = ([string]$_.Exception.Message -split "`r?`n")[0]
        if ($why.Length -gt 160) { $why = $why.Substring(0, 160) }
        throw ('steps.json is not valid JSON (' + $Path + '): ' + $why + ' Most often a single backslash: write \\ inside JSON strings.')
    }
}

function Get-GuiModes {
    # The modes in catalog order: Name, Label, Description, Phase, RunRoot.
    param($Catalog)
    $out = @()
    foreach ($p in $Catalog.Modes.PSObject.Properties) {
        $out += [pscustomobject]@{
            Name = $p.Name; Label = [string](Get-GuiProp $p.Value 'Label' $p.Name)
            Description = [string](Get-GuiProp $p.Value 'Description' '')
            Phase = [string](Get-GuiProp $p.Value 'Phase' 'ALL'); RunRoot = [string](Get-GuiProp $p.Value 'RunRoot' 'none')
        }
    }
    return $out
}

function Get-GuiAskDefaults {
    # What every Ask answers when nobody is asked (headless runs) or the dialog is refused:
    # tick boxes as the catalog's "Checked", the input's "Default", "Sets" false.
    param($Catalog, [switch]$Refused)
    $d = @{}
    $asks = Get-GuiProp $Catalog 'Asks' $null
    if (-not $asks) { return $d }
    foreach ($p in $asks.PSObject.Properties) {
        foreach ($c in @(ConvertTo-GuiItems (Get-GuiProp $p.Value 'Checks' $null))) {
            $d[[string]$c.Key] = $(if ($Refused) { $false } else { [bool](Get-GuiProp $c 'Checked' $false) })
        }
        $inp = Get-GuiProp $p.Value 'Input' $null
        if ($inp) { $d[[string]$inp.Key] = [string](Get-GuiProp $inp 'Default' '') }
        $sets = [string](Get-GuiProp $p.Value 'Sets' '')
        if ($sets) { $d[$sets] = $(if ($Refused) { $false } else { [bool](Get-GuiProp $p.Value 'Default' $false) }) }
    }
    return $d
}

function New-GuiSession {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'steps.json'),
        [string]$RunRootBase = '',
        [string]$ComputerName = $env:COMPUTERNAME,
        [hashtable]$Answers,
        # The window sets this: the run then stops at each "Ask" of the catalog until the operator's
        # answer arrives through Set-GuiAnswer. Without it the catalog defaults apply.
        [switch]$Interactive
    )
    $catalog = Get-GuiCatalog -Path $CatalogPath
    $modeInfo = @(Get-GuiModes $catalog | Where-Object { $_.Name -eq $Mode })
    if ($modeInfo.Count -eq 0) { throw ('Unknown mode: ' + $Mode) }
    $modeInfo = $modeInfo[0]
    $root = $ToolRoot
    if (-not $root.EndsWith('\')) { $root += '\' }
    if (-not $RunRootBase) {
        $RunRootBase = [Environment]::ExpandEnvironmentVariables([string](Get-GuiProp (Get-GuiProp $catalog 'Tool' $null) 'RunRootBase' ''))
    }

    $merged = Get-GuiAskDefaults -Catalog $catalog
    if ($Answers) { foreach ($k in $Answers.Keys) { $merged[$k] = $Answers[$k] } }

    $plan = New-Object System.Collections.ArrayList
    foreach ($step in @($catalog.Steps)) {
        $phases = @(ConvertTo-GuiItems (Get-GuiProp $step 'Phases' $null))
        if ($phases.Count -gt 0 -and $phases -notcontains $modeInfo.Phase) { continue }
        foreach ($call in @($step.Calls)) {
            $cp = @(ConvertTo-GuiItems (Get-GuiProp $call 'Phases' $null))
            if ($cp.Count -gt 0 -and $cp -notcontains $modeInfo.Phase) { continue }
            [void]$plan.Add([pscustomobject]@{
                    StepId = [string]$step.Id; StepTitle = [string]$step.Title
                    Destructive = [bool](Get-GuiProp $step 'Destructive' $false); Call = $call
                })
        }
    }

    return [pscustomobject]@{
        Mode = $Mode; Phase = $modeInfo.Phase; RunRootKind = $modeInfo.RunRoot
        ToolRoot = $root; RunRootBase = $RunRootBase; ComputerName = $ComputerName
        Catalog = $catalog; RunRoot = ''; Vars = @{}
        PipeRc = 0; Answers = $merged
        Interactive = [bool]$Interactive; Asked = @{}
        Plan = $plan; Index = 0
        Results = (New-Object System.Collections.ArrayList)
        Stopped = $false; StopMessage = ''; Started = (Get-Date).ToUniversalTime()
        Current = $null
    }
}

function Initialize-GuiRunRoot {
    # Mode "RunRoot": "new" -> <RunRootBase>\<PC>-<yyyyMMdd-HHmmss>-<4 hex>; "none" -> no folder.
    # Fails closed: a mode that needs a folder and cannot get one does not run.
    param($Session)
    if ($Session.RunRootKind -ne 'new') { return '' }
    if (-not $Session.RunRootBase) { throw 'This mode needs a run folder but steps.json has no Tool.RunRootBase.' }
    $name = $Session.ComputerName + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $p = Join-Path $Session.RunRootBase $name
    $null = New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop
    $Session.RunRoot = $p
    return $p
}

# ---------------------------------------------------------------------------------------
# Token expansion and conditions
# ---------------------------------------------------------------------------------------

function Expand-GuiTokens {
    # {ToolRoot} (ends with \)  {RunRoot}  {Phase}  {Mode}  {PipeRc}  {Answer:<key>}  {Var:<name>}
    param($Session, [string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text.Replace('{ToolRoot}', $Session.ToolRoot).Replace('{RunRoot}', [string]$Session.RunRoot).Replace('{Phase}', $Session.Phase).Replace('{Mode}', $Session.Mode).Replace('{PipeRc}', [string]$Session.PipeRc)
    foreach ($m in @([regex]::Matches($t, '\{(Answer|Var):(\w+)\}'))) {
        $v = ''
        if ($m.Groups[1].Value -eq 'Answer') { $v = [string]$Session.Answers[$m.Groups[2].Value] }
        else { $v = [string]$Session.Vars[$m.Groups[2].Value] }
        $t = $t.Replace($m.Value, $v)
    }
    return $t
}

function Test-GuiCondition {
    # Answer:<key>  NotAnswer:<key>  Var:<name> (non-empty)  NotVar:<name>  Exists:<path>  NotExists:<path>  Phase:<name>
    param($Session, [string]$Condition)
    $i = $Condition.IndexOf(':')
    if ($i -lt 1) { throw ('Bad condition: ' + $Condition) }
    $kind = $Condition.Substring(0, $i)
    $arg = $Condition.Substring($i + 1)
    switch ($kind) {
        'Answer'    { $v = $Session.Answers[$arg]; if ($v -is [string]) { return ($v -ne '') }; return [bool]$v }
        'NotAnswer' { return (-not (Test-GuiCondition -Session $Session -Condition ('Answer:' + $arg))) }
        'Var'       { return (-not [string]::IsNullOrEmpty([string]$Session.Vars[$arg])) }
        'NotVar'    { return ([string]::IsNullOrEmpty([string]$Session.Vars[$arg])) }
        'Phase'     { return ($Session.Phase -eq $arg) }
        'Exists' {
            $p = Expand-GuiTokens -Session $Session -Text $arg
            if ([string]::IsNullOrWhiteSpace($p)) { return $false }
            return (Test-Path -LiteralPath $p)
        }
        'NotExists' { return (-not (Test-GuiCondition -Session $Session -Condition ('Exists:' + $arg))) }
        default     { throw ('Unknown condition kind: ' + $kind) }
    }
}

function Test-GuiConditions {
    param($Session, $Conditions)
    foreach ($c in @(ConvertTo-GuiItems $Conditions)) {
        if (-not (Test-GuiCondition -Session $Session -Condition ([string]$c))) { return $false }
    }
    return $true
}

function Expand-GuiArgs {
    # An element is a string (tokens expanded) or { "When": [...], "Args": [...] }: a group of
    # arguments that is only passed when every condition holds.
    param($Session, $Template)
    $out = New-Object System.Collections.ArrayList
    foreach ($a in @(ConvertTo-GuiItems $Template)) {
        if ($a -is [string]) { [void]$out.Add((Expand-GuiTokens -Session $Session -Text $a)); continue }
        if (Test-GuiConditions -Session $Session -Conditions (Get-GuiProp $a 'When' $null)) {
            foreach ($x in @(ConvertTo-GuiItems (Get-GuiProp $a 'Args' $null))) { [void]$out.Add((Expand-GuiTokens -Session $Session -Text ([string]$x))) }
        }
    }
    return @($out.ToArray())
}

# ---------------------------------------------------------------------------------------
# The state machine
# ---------------------------------------------------------------------------------------

function Add-GuiResult {
    param($Session, $Entry, [string]$Status, [string]$Message, $ExitCode = $null)
    $rec = [pscustomobject]@{
        StepId = $Entry.StepId; Title = $Entry.StepTitle
        Script = [string](Get-GuiProp $Entry.Call 'Script' '')
        Status = $Status; ExitCode = $ExitCode; Message = $Message
        Utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    [void]$Session.Results.Add($rec)
    return $rec
}

function Set-GuiPipeRc {
    # The run's final status is the FIRST non-zero code that counts.
    param($Session, [int]$Rc)
    if ($Session.PipeRc -eq 0) { $Session.PipeRc = $Rc }
}

function Get-GuiNextAction {
    # Returns the next thing to do, or $null when the run is finished or stopped.
    #   Kind = 'Ask'  the window must collect an answer (Set-GuiAnswer), then call this again
    #   Kind = 'Run'  start ScriptPath with Args, then Complete-GuiAction with its exit code
    # Calls whose "When" is false are recorded as Skipped and passed over.
    param($Session)
    while ((-not $Session.Stopped) -and $Session.Index -lt $Session.Plan.Count) {
        $entry = $Session.Plan[$Session.Index]
        $call = $entry.Call
        $script = [string](Get-GuiProp $call 'Script' '')
        $scriptPath = Join-Path $Session.ToolRoot $script

        # A question for the operator. Only asked when the call could otherwise run, i.e. every
        # condition that does not depend on an answer holds.
        $ask = [string](Get-GuiProp $call 'Ask' '')
        if ($ask -and $Session.Interactive -and -not $Session.Asked.ContainsKey($ask)) {
            $pre = $true
            foreach ($cond in @(ConvertTo-GuiItems (Get-GuiProp $call 'When' $null))) {
                if (([string]$cond) -notmatch '^(Not)?Answer:' -and -not (Test-GuiCondition -Session $Session -Condition ([string]$cond))) { $pre = $false; break }
            }
            if ($pre -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                $action = [pscustomobject]@{ Kind = 'Ask'; Ask = $ask; Index = $Session.Index; StepId = $entry.StepId; Title = $entry.StepTitle
                    Destructive = $entry.Destructive; ScriptPath = $scriptPath; Args = @(); Call = $call; Entry = $entry }
                $Session.Current = $action
                return $action
            }
        }

        if (-not (Test-GuiConditions -Session $Session -Conditions (Get-GuiProp $call 'When' $null))) {
            [void](Add-GuiResult $Session $entry 'Skipped' ([string](Get-GuiProp $call 'SkipText' 'Not needed.')))
            $Session.Index++; continue
        }

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            $msg = [string](Get-GuiProp $call 'MissingMessage' ($script + ' is missing.'))
            if ([string](Get-GuiProp $call 'OnMissing' 'Stop') -eq 'Stop') {
                [void](Add-GuiResult $Session $entry 'Failed' $msg)
                $Session.Stopped = $true; $Session.StopMessage = $msg
            } else {
                Set-GuiPipeRc $Session 1
                [void](Add-GuiResult $Session $entry 'Warn' $msg)
                $Session.Index++
            }
            continue
        }

        if (-not (Test-GuiConditions -Session $Session -Conditions (Get-GuiProp $call 'Needs' $null))) {
            Set-GuiPipeRc $Session 1
            [void](Add-GuiResult $Session $entry 'Warn' ([string](Get-GuiProp $call 'NeedsText' 'Something this step needs is missing.')))
            $Session.Index++; continue
        }

        $action = [pscustomobject]@{ Kind = 'Run'; Ask = ''; Index = $Session.Index; StepId = $entry.StepId; Title = $entry.StepTitle
            Destructive = $entry.Destructive; ScriptPath = $scriptPath
            Args = @(Expand-GuiArgs -Session $Session -Template (Get-GuiProp $call 'Args' $null)); Call = $call; Entry = $entry }
        $before = [string](Get-GuiProp $call 'Before' '')
        if ($before) {
            $h = Get-GuiHook ('Before:' + $before)
            if (-not $h) { throw ('Unknown before-hook: ' + $before) }
            [void](& $h $Session $action)
        }
        $Session.Current = $action
        return $action
    }
    $Session.Current = $null
    return $null
}

function Get-GuiAsk {
    param($Session, [string]$Name)
    $a = Get-GuiProp (Get-GuiProp $Session.Catalog 'Asks' $null) $Name $null
    if (-not $a) { throw ('steps.json has no Ask named ' + $Name) }
    return $a
}

function Set-GuiAnswer {
    # Records the operator's answer to an Ask. Only the keys that Ask owns can be set.
    # Nothing is ever answered on the operator's behalf: the caller passes what was clicked.
    param($Session, [Parameter(Mandatory = $true)][string]$Ask, [hashtable]$Values)
    $def = Get-GuiAsk -Session $Session -Name $Ask
    $allowed = @()
    foreach ($c in @(ConvertTo-GuiItems (Get-GuiProp $def 'Checks' $null))) { $allowed += [string]$c.Key }
    $inp = Get-GuiProp $def 'Input' $null
    if ($inp) { $allowed += [string]$inp.Key }
    $sets = [string](Get-GuiProp $def 'Sets' '')
    if ($sets) { $allowed += $sets }
    if ($null -eq $Values) { $Values = @{} }
    foreach ($k in @($Values.Keys)) {
        if ($allowed -notcontains $k) { throw ('Ask ' + $Ask + ' cannot set ' + $k) }
        $Session.Answers[$k] = $Values[$k]
    }
    $Session.Asked[$Ask] = $true
    $Session.Current = $null
}

function Update-GuiCapture {
    # "Capture": [ { "Var": "ShareUrl", "Pattern": "^UPLOAD: (\\S+)$" } ] - a value the step prints.
    param($Session, $Action, [string[]]$Lines)
    $caps = @(ConvertTo-GuiItems (Get-GuiProp $Action.Call 'Capture' $null))
    if ($caps.Count -eq 0) { return }
    foreach ($l in @($Lines)) {
        foreach ($c in $caps) {
            $m = [regex]::Match([string]$l, [string]$c.Pattern)
            if ($m.Success) { $Session.Vars[[string]$c.Var] = $(if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { $m.Value }) }
        }
    }
}

function Complete-GuiAction {
    # Applies the catalog's rules for a finished call. Returns Status (Done | Warn | Failed | Alert),
    # Stop ($true when the run must not continue) and Message.
    #   "OnNonZero": Warn (default; marks the run) | Ignore | Stop
    #   "ExitCodes": { "1": { "Status": "Alert", "Message": "...", "Stop": false, "Counts": true } }
    #   "RequireOutput": a file that must exist after exit 0, else the run stops
    #   "SetVar": { "Report": "{RunRoot}\\report.html" }      "After": "<hook name>"
    param($Session, $Action, [int]$ExitCode, [string]$Message = '')
    $call = $Action.Call
    $status = 'Done'; $text = $Message; $stop = $false

    $special = Get-GuiProp (Get-GuiProp $call 'ExitCodes' $null) ([string]$ExitCode) $null
    if ($special) {
        $status = [string](Get-GuiProp $special 'Status' 'Warn')
        $text = [string](Get-GuiProp $special 'Message' ('Exit ' + $ExitCode + '.'))
        $stop = [bool](Get-GuiProp $special 'Stop' $false)
        if ($ExitCode -ne 0 -and [bool](Get-GuiProp $special 'Counts' $true)) { Set-GuiPipeRc $Session $ExitCode }
    } elseif ($ExitCode -ne 0) {
        $nz = [string](Get-GuiProp $call 'NonZeroText' '')
        switch ([string](Get-GuiProp $call 'OnNonZero' 'Warn')) {
            'Ignore' { }
            'Stop' { $status = 'Failed'; $stop = $true; Set-GuiPipeRc $Session $ExitCode; $text = [string](Get-GuiProp $call 'StopMessage' ('Failed with exit ' + $ExitCode + '.')) }
            default { $status = 'Warn'; Set-GuiPipeRc $Session $ExitCode; $text = ($(if ($nz) { $nz } else { 'Ended with a problem.' }) + ' (exit ' + $ExitCode + ')') }
        }
    }

    if ((-not $stop) -and $ExitCode -eq 0) {
        $req = [string](Get-GuiProp $call 'RequireOutput' '')
        if ($req -and -not (Test-Path -LiteralPath (Expand-GuiTokens -Session $Session -Text $req))) {
            $status = 'Failed'; $stop = $true; Set-GuiPipeRc $Session 1
            $text = [string](Get-GuiProp $call 'StopMessage' 'A required output file was not written.')
        }
    }

    if (-not $stop) {
        $sv = Get-GuiProp $call 'SetVar' $null
        if ($sv) { foreach ($p in $sv.PSObject.Properties) { $Session.Vars[$p.Name] = Expand-GuiTokens -Session $Session -Text ([string]$p.Value) } }
        $after = [string](Get-GuiProp $call 'After' '')
        if ($after) {
            $h = Get-GuiHook ('After:' + $after)
            if (-not $h) { throw ('Unknown after-hook: ' + $after) }
            $r = & $h $Session $Action $ExitCode
            if ($r -is [System.Collections.IDictionary]) {
                if ($r.Contains('Status')) { $status = [string]$r['Status'] }
                if ($r.Contains('Message')) { $text = [string]$r['Message'] }
                if ($r.Contains('Stop')) { $stop = [bool]$r['Stop'] }
            }
        }
    }

    if ($stop) { $Session.Stopped = $true; $Session.StopMessage = $text }
    [void](Add-GuiResult $Session $Action.Entry $status $text $ExitCode)
    $Session.Index = $Action.Index + 1
    $Session.Current = $null
    return [pscustomobject]@{ Status = $status; Stop = $stop; Message = $text; ExitCode = $ExitCode; StepId = $Action.StepId }
}

function Get-GuiFinalStatus {
    param($Session)
    return [int]$Session.PipeRc
}

function Get-GuiResultItems {
    # The catalog's "Results" list, resolved for the finish panel:
    #   { "Label": "Report", "Path": "{RunRoot}\\report.html" }   a file (the window offers Open)
    #   { "Label": "Paste link", "Var": "ShareUrl" }              a captured value
    # followed by whatever the optional Summary hook returns.
    param($Session)
    $out = @()
    foreach ($r in @(ConvertTo-GuiItems (Get-GuiProp $Session.Catalog 'Results' $null))) {
        if (-not (Test-GuiConditions -Session $Session -Conditions (Get-GuiProp $r 'When' $null))) { continue }
        $label = [string]$r.Label
        $path = [string](Get-GuiProp $r 'Path' '')
        if ($path) {
            $full = Expand-GuiTokens -Session $Session -Text $path
            $exists = (-not [string]::IsNullOrWhiteSpace($full)) -and (Test-Path -LiteralPath $full)
            $out += [pscustomobject]@{ Label = $label; Value = $(if ($exists) { $full } else { 'not produced' }); Path = $(if ($exists) { $full } else { '' }); Tone = $(if ($exists) { 'Foreground' } else { 'WarningFg' }) }
            continue
        }
        $var = [string](Get-GuiProp $r 'Var' '')
        $val = $(if ($var) { [string]$Session.Vars[$var] } else { Expand-GuiTokens -Session $Session -Text ([string](Get-GuiProp $r 'Text' '')) })
        if ($val) { $out += [pscustomobject]@{ Label = $label; Value = $val; Path = ''; Tone = 'Foreground' } }
    }
    $h = Get-GuiHook 'Summary'
    if ($h) {
        foreach ($x in @(& $h $Session)) {
            if ($null -eq $x) { continue }
            $out += [pscustomobject]@{ Label = [string](Get-GuiProp $x 'Label' ''); Value = [string](Get-GuiProp $x 'Value' ''); Path = [string](Get-GuiProp $x 'Path' ''); Tone = [string](Get-GuiProp $x 'Tone' 'Foreground') }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------------------
# Console encoding (Windows PowerShell 5.1 corrupts redirected stdin on code page 65001)
# ---------------------------------------------------------------------------------------

function Set-GuiConsoleEncoding {
    # A redirected powershell.exe child that inherits a UTF-8 (65001) console puts a byte order
    # mark in front of what Read-Host returns, so "y" arrives as U+FEFF + "y" and a y/N loop never
    # accepts it. OEM code pages (437, 862) are clean. Windows 11's "UTF-8 for worldwide language
    # support" makes 65001 a real field case, so the window switches the shared console to 437
    # for its lifetime and restores it on exit.
    $saved = [pscustomobject]@{ In = $null; Out = $null; Changed = $false }
    try {
        $saved.In = [Console]::InputEncoding
        $saved.Out = [Console]::OutputEncoding
        if ($saved.In.CodePage -eq 65001 -or $saved.Out.CodePage -eq 65001) {
            $e = [Text.Encoding]::GetEncoding(437)
            [Console]::InputEncoding = $e
            [Console]::OutputEncoding = $e
            $saved.Changed = $true
        }
    } catch { }
    return $saved
}

function Restore-GuiConsoleEncoding {
    param($Saved)
    if ($Saved -and $Saved.Changed) {
        try { [Console]::InputEncoding = $Saved.In; [Console]::OutputEncoding = $Saved.Out } catch { }
    }
}

# ---------------------------------------------------------------------------------------
# One child process at a time
# ---------------------------------------------------------------------------------------

function Start-GuiChild {
    # Never add -NonInteractive: it makes Read-Host throw in the child.
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [string[]]$ArgumentList, [string]$WorkingDirectory)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $argText = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-GuiArg $ScriptPath)
    # (An unbound [string[]] parameter is $null, and @($null).Count throws under strict mode here.)
    if ($null -ne $ArgumentList -and $ArgumentList.Length -gt 0) { $argText += ' ' + (ConvertTo-GuiArgString $ArgumentList) }
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $enc = [Console]::OutputEncoding
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }

    $p = [System.Diagnostics.Process]::Start($psi)
    $outBuf = New-Object char[] 4096
    $errBuf = New-Object char[] 4096
    return [pscustomobject]@{
        Process = $p; CommandLine = ($psi.FileName + ' ' + $argText)
        OutBuf = $outBuf; ErrBuf = $errBuf
        # Characters, not lines: a prompt printed with -NoNewline never ends its line, so a line
        # reader would never return it and the window would wait forever on a question it cannot see.
        OutTask = $p.StandardOutput.ReadAsync($outBuf, 0, $outBuf.Length)
        ErrTask = $p.StandardError.ReadAsync($errBuf, 0, $errBuf.Length)
        OutEof = $false; ErrEof = $false
        Tail = ''; ErrTail = ''
        PendingLines = (New-Object System.Collections.ArrayList)
        StartedUtc = (Get-Date).ToUniversalTime(); LastOutputUtc = (Get-Date).ToUniversalTime(); ExitedUtc = $null
        DismissedTail = ''; DismissedUtc = $null; Finished = $false; ExitCode = $null
    }
}

function Add-GuiChildText {
    param($Child, [string]$Text, [bool]$IsError)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $Text = $Text.Replace([string][char]0xFEFF, '').Replace("`r`n", "`n").Replace("`r", "`n")
    $Child.LastOutputUtc = (Get-Date).ToUniversalTime()
    $prefix = ''
    if ($IsError) { $combined = $Child.ErrTail + $Text; $prefix = '[stderr] ' } else { $combined = $Child.Tail + $Text }
    $parts = $combined.Split([char]"`n")
    for ($i = 0; $i -lt $parts.Length - 1; $i++) { [void]$Child.PendingLines.Add($prefix + $parts[$i]) }
    if ($IsError) { $Child.ErrTail = $parts[$parts.Length - 1] } else { $Child.Tail = $parts[$parts.Length - 1] }
}

function Receive-GuiChildStream {
    param($Child, [bool]$IsError)
    if ($IsError) { $task = $Child.ErrTask; $buf = $Child.ErrBuf; $reader = $Child.Process.StandardError }
    else { $task = $Child.OutTask; $buf = $Child.OutBuf; $reader = $Child.Process.StandardOutput }
    $eof = $(if ($IsError) { $Child.ErrEof } else { $Child.OutEof })
    while ((-not $eof) -and $task.IsCompleted) {
        $n = 0
        if (-not $task.IsFaulted -and -not $task.IsCanceled) { $n = $task.Result }
        if ($n -le 0) { $eof = $true; break }
        Add-GuiChildText -Child $Child -Text (New-Object string -ArgumentList @(, $buf[0..($n - 1)])) -IsError $IsError
        $task = $reader.ReadAsync($buf, 0, $buf.Length)
    }
    if ($IsError) { $Child.ErrTask = $task; $Child.ErrEof = $eof } else { $Child.OutTask = $task; $Child.OutEof = $eof }
}

function Update-GuiChild {
    # Call from the UI timer (or a loop). Never blocks. Returns the new complete lines and, once
    # the process has exited and its output is drained, Exited = $true and ExitCode.
    param($Child)
    Receive-GuiChildStream -Child $Child -IsError $false
    Receive-GuiChildStream -Child $Child -IsError $true

    $exited = $false
    if ($Child.Process.HasExited) {
        if (-not $Child.ExitedUtc) { $Child.ExitedUtc = (Get-Date).ToUniversalTime() }
        # A program the child started can inherit the pipe and keep it open after the child is
        # gone, so EOF is not awaited forever: 1.5 s of grace, then stop waiting.
        $grace = ((Get-Date).ToUniversalTime() - $Child.ExitedUtc).TotalMilliseconds
        if (($Child.OutEof -and $Child.ErrEof) -or $grace -gt 1500) { $exited = $true }
    }
    if ($exited -and -not $Child.Finished) {
        if ($Child.Tail -ne '') { [void]$Child.PendingLines.Add($Child.Tail); $Child.Tail = '' }
        if ($Child.ErrTail -ne '') { [void]$Child.PendingLines.Add('[stderr] ' + $Child.ErrTail); $Child.ErrTail = '' }
        $Child.Finished = $true
        $Child.ExitCode = [int]$Child.Process.ExitCode
    }
    $lines = @($Child.PendingLines.ToArray())
    $Child.PendingLines.Clear()
    return [pscustomobject]@{ Lines = $lines; Exited = $Child.Finished; ExitCode = $Child.ExitCode }
}

function Send-GuiAnswer {
    # Writes one answer line to the child's stdin as RAW BYTES in the console's own code page (no
    # byte order mark). The caller must have shown a dialog that named the thing being approved
    # and must pass the operator's own choice.
    param($Child, [AllowEmptyString()][string]$Text)
    $enc = [Console]::InputEncoding
    $bytes = $enc.GetBytes($Text + "`r`n")
    $s = $Child.Process.StandardInput.BaseStream
    $s.Write($bytes, 0, $bytes.Length)
    $s.Flush()
    [void]$Child.PendingLines.Add('[GUI sent answer: ' + $(if ($Text -eq '') { '(empty line)' } else { $Text }) + ']')
    $Child.Tail = ''
    $Child.LastOutputUtc = (Get-Date).ToUniversalTime()
}

function Stop-GuiChild {
    # Ends a running step. By default the whole tree goes. -KeepDescendants ends only the step's own
    # powershell.exe: closing the window must not close a program the operator is driving.
    param($Child, [switch]$KeepDescendants)
    if (-not $Child -or $Child.Process.HasExited) { return }
    if ($KeepDescendants) { try { $Child.Process.Kill() } catch { }; return }
    try { & taskkill.exe /PID $Child.Process.Id /T /F | Out-Null } catch { try { $Child.Process.Kill() } catch { } }
}

# ---------------------------------------------------------------------------------------
# Prompts (questions a script asks with Read-Host)
# ---------------------------------------------------------------------------------------

function Get-GuiPromptTable {
    # The catalog's "Prompts". A prompt is recognised when the UNFINISHED output line is exactly
    # one of its Needles. Under redirected stdin Windows PowerShell 5.1 does NOT print Read-Host's
    # own prompt argument, so every script must print its prompt itself:
    #     Write-Host '<text>' -NoNewline ; $x = Read-Host
    # tests\gui\Test-Gui.ps1 checks each Needle still appears in the scripts the row names.
    param($Catalog)
    return @(ConvertTo-GuiItems (Get-GuiProp $Catalog 'Prompts' $null))
}

function Get-GuiPendingPrompt {
    # Known prompts match the table. Any other line that sits unfinished and quiet for
    # -QuietSeconds becomes a generic "the tool is waiting for an answer" box, so a prompt nobody
    # listed degrades to a plain dialog instead of hanging the window. Complete lines never
    # trigger it, so a long quiet step does not look like a question. A box the operator marked
    # "not a question" stays away for -RepeatSeconds.
    param($Child, $Catalog, [int]$QuietSeconds = 5, [int]$RepeatSeconds = 60)
    if ($Child.Finished) { return $null }
    $t = ([string]$Child.Tail).Trim()
    if ($t -eq '') { return $null }
    foreach ($row in (Get-GuiPromptTable $Catalog)) {
        foreach ($n in @(ConvertTo-GuiItems $row.Needles)) {
            if ($t -ceq ([string]$n).Trim()) { return [pscustomobject]@{ Kind = 'Known'; Row = $row; Text = $t } }
        }
    }
    $now = (Get-Date).ToUniversalTime()
    if (($now - $Child.LastOutputUtc).TotalSeconds -lt $QuietSeconds) { return $null }
    if ($Child.DismissedTail -eq $t -and $Child.DismissedUtc -and ($now - $Child.DismissedUtc).TotalSeconds -lt $RepeatSeconds) { return $null }
    return [pscustomobject]@{ Kind = 'Unknown'; Row = $null; Text = $t }
}

function Set-GuiPromptDismissed {
    param($Child, [string]$Text)
    $Child.DismissedTail = $Text
    $Child.DismissedUtc = (Get-Date).ToUniversalTime()
}

function Resolve-GuiPromptSend {
    # What to send for a prompt row given the dialog result ($null = closed with the window X).
    # Closing ALWAYS sends the row's Refuse text: never an approval.
    #   Button "Send": the literal line, or "{Typed}" for what the operator typed.
    param($Row, $ButtonIndex, [string]$Typed)
    $refuse = [string](Get-GuiProp $Row 'Refuse' '')
    if ($null -eq $ButtonIndex) { return [pscustomobject]@{ Send = $refuse; Approved = $false } }
    $buttons = @(ConvertTo-GuiItems $Row.Buttons)
    $i = [int]$ButtonIndex
    if ($i -lt 0 -or $i -ge $buttons.Count) { return [pscustomobject]@{ Send = $refuse; Approved = $false } }
    $b = $buttons[$i]
    $word = [string](Get-GuiProp $Row 'TypeWord' '')
    $needs = [bool](Get-GuiProp $b 'NeedsWord' $false)
    if ($needs -and $word -and ($Typed -cne $word)) { return [pscustomobject]@{ Send = $refuse; Approved = $false } }
    $send = [string](Get-GuiProp $b 'Send' $refuse)
    if ($send -eq '{Typed}') { $send = [string]$Typed }
    return [pscustomobject]@{ Send = $send; Approved = $needs }
}

# ---------------------------------------------------------------------------------------
# Display-only session file (never read to decide whether a step may run)
# ---------------------------------------------------------------------------------------

function Save-GuiSession {
    param($Session)
    if ([string]::IsNullOrEmpty($Session.RunRoot) -or -not (Test-Path -LiteralPath $Session.RunRoot)) { return $true }
    try {
        $doc = [ordered]@{
            Note = 'Display data written by the window. Nothing reads this file to decide whether a step may run.'
            Mode = $Session.Mode; ComputerName = $Session.ComputerName; RunRoot = $Session.RunRoot
            FinalStatus = (Get-GuiFinalStatus $Session); Stopped = [bool]$Session.Stopped; StopMessage = $Session.StopMessage
            Steps = @($Session.Results | ForEach-Object { [ordered]@{ Step = $_.StepId; Title = $_.Title; Status = $_.Status; ExitCode = $_.ExitCode; Message = $_.Message; Utc = $_.Utc } })
        }
        ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $Session.RunRoot 'gui-session.json') -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch { return $false }
}

Export-ModuleMember -Function `
    Get-GuiKitVersion, ConvertTo-GuiArg, ConvertTo-GuiArgString, Get-GuiProp, ConvertTo-GuiItems, Read-GuiJson, `
    Register-GuiHook, Get-GuiHook, Get-GuiCatalog, Get-GuiModes, Get-GuiAskDefaults, New-GuiSession, Initialize-GuiRunRoot, `
    Expand-GuiTokens, Test-GuiCondition, Test-GuiConditions, Expand-GuiArgs, `
    Get-GuiNextAction, Get-GuiAsk, Set-GuiAnswer, Update-GuiCapture, Complete-GuiAction, Get-GuiFinalStatus, Get-GuiResultItems, `
    Set-GuiConsoleEncoding, Restore-GuiConsoleEncoding, `
    Start-GuiChild, Update-GuiChild, Send-GuiAnswer, Stop-GuiChild, `
    Get-GuiPromptTable, Get-GuiPendingPrompt, Set-GuiPromptDismissed, Resolve-GuiPromptSend, Save-GuiSession
