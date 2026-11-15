<#
  Start-Gui.ps1 - the window for __TOOL_TITLE__ (script-gui kit).

  A second front end, not a second engine: every step is a child powershell.exe running one of
  the tool's own scripts with the arguments gui\steps.json names, one at a time. This file only
  wires controls, one DispatcherTimer and a few dialogs to gui\Gui.Core.psm1. It contains none of
  the tool's logic, imports none of the tool's modules and runs none of its code in this process.

  Rules that never bend:
    * an approving answer is written to a child ONLY as the direct result of the operator's own
      click or typing in a dialog that names what is being approved;
    * closing a dialog (window X) sends the script's REFUSING answer, never yes;
    * a prompt with "TypeWord" needs that word typed before its approve button works;
    * nothing is remembered between runs and there is no unattended mode.

  Started by the Run-*Gui.bat launcher (-STA). Windows PowerShell 5.1, pure ASCII, no BOM.

  Test hooks (tests\gui only): -LoadOnly loads the XAML, checks every named control and exits.
  -SelfTest builds the real dialogs without showing them and checks the typed-word gate and the
  colour tokens. -AutoStart -Mode <m> -ResultPath <file> runs without a click, writes the final
  window state to the file and closes. It needs SCRIPTGUI_TEST=1 and is honoured ONLY in a window
  that is not elevated; SCRIPTGUI_TEST_ANSWERS=<json file> stands in for the operator's clicks, and
  a dialog with no entry there behaves as if it was closed with the window X (the refusing answer).
#>
param(
    [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RunRootBase = '',
    [switch]$AllowNotElevated,
    [switch]$LoadOnly,
    [switch]$SelfTest,
    [switch]$AutoStart,
    [string]$Mode = '',
    [string]$ResultPath = '',
    # Light or dark design tokens; System follows the Windows app-mode setting.
    [ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# WPF needs a single-threaded apartment. The launcher passes -STA; if this was started some other way, restart once.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $again = @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $again += ('-' + $kv.Key) } }
        else { $again += @(('-' + $kv.Key), [string]$kv.Value) }
    }
    & (Join-Path $PSHOME 'powershell.exe') @again
    exit $LASTEXITCODE
}

# ---- screen scaling ------------------------------------------------------------------------------
# powershell.exe starts DPI-unaware and WPF then makes it only "system aware": blurry on a monitor
# with a different scale. So, BEFORE WPF loads: ask for per-monitor awareness (v2). Either step
# failing just leaves the window system aware.
$script:DpiMode = 'system (WPF default)'
try {
    if (-not ('ScriptGuiDpi' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ScriptGuiDpi { [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value); }'
    }
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    if ([ScriptGuiDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $script:DpiMode = 'per-monitor v2' }
} catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'Gui.Core.psm1') -Force
# Optional tool-specific hooks (After:/Before:/Summary). No WPF types in there either.
$toolModule = Join-Path $PSScriptRoot 'Gui.Tool.psm1'
if (Test-Path -LiteralPath $toolModule -PathType Leaf) { Import-Module $toolModule -Force }

$script:Catalog = Get-GuiCatalog
$script:Tool = Get-GuiProp $script:Catalog 'Tool' $null
$script:ToolTitle = [string](Get-GuiProp $script:Tool 'Title' 'Tool')
$script:Version = ''
$vf = [string](Get-GuiProp $script:Tool 'VersionFile' '')
if ($vf) { try { $script:Version = ([IO.File]::ReadAllText((Join-Path $ToolRoot $vf))).Trim() } catch { } }

# ---- elevation: the launcher elevates once; the window never asks again ----------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ([bool](Get-GuiProp $script:Tool 'RequireAdmin' $false) -and -not $isAdmin -and -not $AllowNotElevated) {
    [void][System.Windows.MessageBox]::Show("This window must run as administrator.`n`nClose it and start the Run-*Gui.bat launcher, which asks for administrator rights once.", $script:ToolTitle, 'OK', 'Warning')
    exit 1
}

# ---- load the window --------------------------------------------------------------------------
$xamlText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xamlText)))
$ui = @{}
$controlNames = 'TitleText', 'InfoText', 'RunText', 'StepperHost', 'StartPanel', 'StartHeading', 'StartIntro', 'ModesHost', 'BtnStart',
'RunPanel', 'StatusTitle', 'StatusDetail', 'Busy', 'Banner', 'BannerText', 'CardsHost', 'BtnOpenRun', 'BtnNewRun',
'BtnCopy', 'BtnOpenLog', 'ConsoleBox', 'RowConsole', 'ColStepper', 'RootGrid', 'HeaderCard', 'StatusCard', 'FooterText'
$missing = @()
foreach ($n in $controlNames) {
    $c = $win.FindName($n)
    if ($null -eq $c) { $missing += $n } else { $ui[$n] = $c }
}
if ($missing.Count -gt 0) {
    Write-Host ('Window is missing controls: ' + ($missing -join ', ')) -ForegroundColor Red
    exit 1
}
if ($LoadOnly) { Write-Host ('LOAD_OK controls=' + $controlNames.Count); exit 0 }

# ---- state -------------------------------------------------------------------------------------
$script:Session = $null
$script:Action = $null
$script:Child = $null
$script:InDialog = $false
$script:Finished = $false
$script:StepRows = @{}
$script:ModeButtons = @()
$script:LogPath = ''
$script:CloseLock = $false
$script:DlgValue = $null
$script:DlgChecks = @{}
$script:DlgText = $null
$script:ConsoleSaved = Set-GuiConsoleEncoding
$script:SessionWriteWarned = $false
$script:Modes = @(Get-GuiModes $script:Catalog)

# Test hooks: canned dialog answers stand in for the operator's clicks. Honoured ONLY in a window
# that is NOT elevated and only with SCRIPTGUI_TEST=1 and -ResultPath, so a real (elevated) run of a
# tool that needs administrator rights never has them. A tool that changes things WITHOUT admin
# rights should not ship its tests\ folder to other people's PCs.
$script:TestHooksAllowed = (-not $isAdmin) -and [bool]$ResultPath -and ($env:SCRIPTGUI_TEST -eq '1')
$script:TestAnswers = $null
if ($script:TestHooksAllowed -and $env:SCRIPTGUI_TEST_ANSWERS -and (Test-Path -LiteralPath $env:SCRIPTGUI_TEST_ANSWERS)) {
    $script:TestAnswers = [IO.File]::ReadAllText($env:SCRIPTGUI_TEST_ANSWERS) | ConvertFrom-Json
}
$script:TestMode = $script:TestHooksAllowed
$script:AutoStart = ($AutoStart -and $script:TestHooksAllowed)
$startMode = $(if ($Mode) { $Mode } else { $script:Modes[0].Name })
if (@($script:Modes | Where-Object { $_.Name -eq $startMode }).Count -eq 0) {
    Write-Host ('Unknown mode: ' + $startMode + ' (steps.json has: ' + (($script:Modes | ForEach-Object { $_.Name }) -join ', ') + ').') -ForegroundColor Red
    exit 2
}

function Get-TestAnswer {
    param([string]$Id)
    if (-not $script:TestMode -or $null -eq $script:TestAnswers) { return $null }
    $p = $script:TestAnswers.PSObject.Properties[$Id]
    if ($p) { return $p.Value }
    return $null
}

function Get-Brush {
    # A design token from MainWindow.xaml ("Brush.<Tone>"). Never a literal colour. An unknown token throws.
    param([string]$Tone)
    return $win.FindResource('Brush.' + $Tone)
}

function Set-GuiTheme {
    # Light is what the XAML defines. Dark replaces every Brush.* token with the Theme.Dark set before
    # any element is built. System = the Windows "app mode" setting.
    param([string]$Name)
    $useDark = $false
    if ($Name -eq 'Dark') { $useDark = $true }
    elseif ($Name -eq 'System') {
        try {
            $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
            $useDark = ([int]$v.AppsUseLightTheme -eq 0)
        } catch { $useDark = $false }
    }
    if ($useDark) {
        $dark = $win.Resources['Theme.Dark']
        foreach ($k in @($dark.Keys)) { $win.Resources[$k] = $dark[$k] }
    }
    $script:ThemeName = $(if ($useDark) { 'Dark' } else { 'Light' })
}
Set-GuiTheme $Theme

function Set-ButtonStyle {
    param($Button, [string]$Variant = 'Secondary')
    $Button.Style = $win.FindResource('Button.' + $Variant)
}

function Write-GuiLogText {
    param([string]$Text)
    if (-not $script:LogPath) { return }
    try { [IO.File]::AppendAllText($script:LogPath, $Text + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Add-ConsoleLines {
    param([string[]]$Lines)
    if (@($Lines).Count -eq 0) { return }
    $ui.ConsoleBox.AppendText((@($Lines) -join "`r`n") + "`r`n")
    if ($ui.ConsoleBox.Text.Length -gt 400000) { $ui.ConsoleBox.Text = $ui.ConsoleBox.Text.Substring(200000) }
    $ui.ConsoleBox.ScrollToEnd()
    Write-GuiLogText ((@($Lines)) -join "`r`n")
}

function Add-ConsoleNote {
    param([string]$Text)
    Add-ConsoleLines @('[GUI] ' + $Text)
}

# ---- stepper -----------------------------------------------------------------------------------
function Initialize-Stepper {
    # Every step of the catalog, in order. Steps the chosen mode does not run stay listed, greyed.
    param($Plan)
    $ui.StepperHost.Children.Clear()
    $script:StepRows = @{}
    $inMode = @{}
    foreach ($e in $Plan) { $inMode[$e.StepId] = $true }
    $seen = @{}
    foreach ($step in @($script:Catalog.Steps)) {
        $id = [string]$step.Id
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $outside = -not $inMode.ContainsKey($id)
        $border = New-Object System.Windows.Controls.Border
        $border.Padding = New-Object System.Windows.Thickness(10, 7, 10, 7)
        $border.Margin = New-Object System.Windows.Thickness(0, 0, 0, 3)
        $border.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $border.BorderThickness = New-Object System.Windows.Thickness(1)
        $border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $dock = New-Object System.Windows.Controls.DockPanel
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Margin = New-Object System.Windows.Thickness(0, 5, 10, 0); $dot.VerticalAlignment = 'Top'
        [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
        $sp = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $id + '  ' + [string]$step.Title
        $title.TextWrapping = 'Wrap'; $title.FontWeight = 'SemiBold'; $title.Foreground = Get-Brush 'Foreground'
        $state = New-Object System.Windows.Controls.TextBlock
        $state.TextWrapping = 'Wrap'; $state.FontSize = 11.5; $state.Margin = New-Object System.Windows.Thickness(0, 1, 0, 0)
        [void]$sp.Children.Add($title); [void]$sp.Children.Add($state)
        [void]$dock.Children.Add($dot); [void]$dock.Children.Add($sp)
        $border.Child = $dock
        if ($outside) { $title.Foreground = Get-Brush 'Subtle'; $title.FontWeight = 'Normal' }
        [void]$ui.StepperHost.Children.Add($border)
        $script:StepRows[$id] = [pscustomobject]@{ Border = $border; State = $state; Dot = $dot; Outside = $outside }
    }
}

function Update-Stepper {
    # Every state has a word, not only a colour.
    foreach ($id in @($script:StepRows.Keys)) {
        $row = $script:StepRows[$id]
        if ($row.Outside) {
            $row.State.Text = 'not part of this mode'
            $row.State.Foreground = Get-Brush 'Subtle'
            $row.Border.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $row.Dot.Fill = [System.Windows.Media.Brushes]::Transparent
            $row.Dot.Stroke = Get-Brush 'Border'; $row.Dot.StrokeThickness = 1.5
            continue
        }
        $word = 'waiting'; $note = ''; $bg = ''; $fg = 'Muted'; $dotTone = 'BorderStrong'; $active = $false
        $res = $null
        if ($script:Session) { $res = @($script:Session.Results | Where-Object { $_.StepId -eq $id }) | Select-Object -Last 1 }
        if ($script:Action -and $script:Action.StepId -eq $id) {
            $active = $true
            if ($script:Action.Kind -eq 'Ask') { $word = 'waiting for you'; $bg = 'WarningBg'; $fg = 'WarningFg' }
            else { $word = 'running'; $bg = 'InfoBg'; $fg = 'InfoFg' }
        }
        elseif ($res) {
            switch ($res.Status) {
                'Done' { $word = 'done'; $bg = 'SuccessBg'; $fg = 'SuccessFg'; $note = $res.Message }
                'Warn' { $word = 'done with warning'; $bg = 'WarningBg'; $fg = 'WarningFg'; $note = $res.Message }
                'Failed' { $word = 'failed'; $bg = 'DangerBg'; $fg = 'DangerFg'; $note = $res.Message }
                'Alert' { $word = 'ALERT'; $bg = 'DangerBg'; $fg = 'DangerFg'; $note = $res.Message }
                'Skipped' { $word = 'skipped'; $bg = ''; $fg = 'Muted'; $note = $res.Message }
            }
            $dotTone = $(if ($fg -eq 'Muted') { 'Subtle' } else { $fg })
        }
        if ($active) { $dotTone = $fg }
        $row.State.Text = $word + $(if ($note) { ' - ' + $note } else { '' })
        $row.State.Foreground = Get-Brush $fg
        $row.Border.Background = $(if ($bg) { Get-Brush $bg } else { [System.Windows.Media.Brushes]::Transparent })
        $row.Border.BorderBrush = $(if ($active) { Get-Brush $fg } else { [System.Windows.Media.Brushes]::Transparent })
        $row.Dot.Fill = Get-Brush $dotTone
        $row.Dot.Stroke = $null
    }
}

# ---- dialogs -----------------------------------------------------------------------------------
function New-DialogWindow {
    # Builds (does not show) one modal dialog in the window's design tokens. See Show-Dialog.
    # Buttons: @{ Text; Value; NeedsWord } hashtables or JSON objects (read with Get-GuiProp only).
    param(
        [string]$Title, [string]$Message, [string]$Detail = '', $Buttons,
        $Checks = @(), [switch]$TextInput, [string]$InputLabel = '', [string]$InputDefault = '', [string]$TypeWord = ''
    )
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.SizeToContent = 'WidthAndHeight'; $w.MaxWidth = 660; $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterOwner'
    if ($win.IsLoaded) { $w.Owner = $win }
    # A dialog is its own window and does not see the main window's resources, so it gets a copy.
    foreach ($k in @($win.Resources.Keys)) { $w.Resources[$k] = $win.Resources[$k] }
    $w.Background = Get-Brush 'Background'; $w.Foreground = Get-Brush 'Foreground'
    $w.FontFamily = $win.FontFamily; $w.FontSize = $win.FontSize
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness(22, 18, 22, 18)
    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = $Title; $head.FontSize = 15; $head.FontWeight = 'SemiBold'; $head.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $head.Foreground = Get-Brush 'Foreground'
    [void]$sp.Children.Add($head)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Message; $tb.TextWrapping = 'Wrap'; $tb.MaxWidth = 610; $tb.Foreground = Get-Brush 'Muted'
    [void]$sp.Children.Add($tb)
    if ($Detail) {
        $d = New-Object System.Windows.Controls.TextBox
        $d.Text = $Detail; $d.IsReadOnly = $true; $d.TextWrapping = 'Wrap'; $d.FontFamily = 'Consolas'; $d.FontSize = 12
        $d.MaxHeight = 200; $d.VerticalScrollBarVisibility = 'Auto'; $d.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $d.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
        $d.Background = Get-Brush 'SurfaceSunken'; $d.Foreground = Get-Brush 'Foreground'; $d.BorderBrush = Get-Brush 'Border'
        [void]$sp.Children.Add($d)
    }
    $tag = @{ Checks = @{}; Text = $null; Word = $TypeWord; Gated = @() }
    foreach ($c in @($Checks)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = [string](Get-GuiProp $c 'Text' ''); $cb.IsChecked = [bool](Get-GuiProp $c 'Checked' $false)
        $cb.IsEnabled = [bool](Get-GuiProp $c 'Enabled' $true)
        $cb.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0); $cb.Foreground = Get-Brush 'Foreground'
        $dep = [string](Get-GuiProp $c 'DependsOn' '')
        if ($dep) { $cb.Tag = $dep }
        $tag.Checks[[string](Get-GuiProp $c 'Key' '')] = $cb
        [void]$sp.Children.Add($cb)
    }
    foreach ($cb in @($tag.Checks.Values)) {
        if ($cb.Tag) {
            # a tick box that only makes sense when another is ticked
            $parent = $tag.Checks[[string]$cb.Tag]
            $child = $cb
            $apply = { param($s, $e) $child.IsEnabled = [bool]$parent.IsChecked; if (-not $parent.IsChecked) { $child.IsChecked = $false } }.GetNewClosure()
            $parent.add_Checked($apply); $parent.add_Unchecked($apply)
            & $apply $null $null
        }
    }
    if ($TextInput -or $TypeWord) {
        if ($InputLabel) {
            $il = New-Object System.Windows.Controls.TextBlock
            $il.Text = $InputLabel; $il.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0); $il.Foreground = Get-Brush 'Muted'
            [void]$sp.Children.Add($il)
        }
        $box = New-Object System.Windows.Controls.TextBox
        $box.Margin = New-Object System.Windows.Thickness(0, $(if ($InputLabel) { 4 } else { 12 }), 0, 0); $box.FontFamily = 'Consolas'; $box.FontSize = 13
        $box.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6); $box.MinWidth = 320
        $box.Background = Get-Brush 'Surface'; $box.Foreground = Get-Brush 'Foreground'; $box.BorderBrush = Get-Brush 'BorderStrong'
        $box.CaretBrush = Get-Brush 'Foreground'
        if ($InputDefault -and -not $TypeWord) { $box.Text = $InputDefault }
        $tag.Text = $box
        [void]$sp.Children.Add($box)
    }
    $wp = New-Object System.Windows.Controls.WrapPanel
    $wp.Margin = New-Object System.Windows.Thickness(0, 18, 0, 0)
    foreach ($b in @($Buttons)) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = [string](Get-GuiProp $b 'Text' ''); $btn.Tag = [string](Get-GuiProp $b 'Value' '')
        # Neutral buttons everywhere; only the approval that needs the typed word looks like what it does.
        $needs = ($TypeWord -and [bool](Get-GuiProp $b 'NeedsWord' $false))
        Set-ButtonStyle $btn $(if ($needs) { 'Danger' } else { 'Secondary' })
        if ($needs) { $btn.IsEnabled = $false; $tag.Gated += $btn }
        $btn.add_Click({
                param($s, $e)
                $dw = [System.Windows.Window]::GetWindow($s)
                $script:DlgValue = [string]$s.Tag
                $script:DlgChecks = @{}
                foreach ($k in @($dw.Tag.Checks.Keys)) { $script:DlgChecks[$k] = [bool]$dw.Tag.Checks[$k].IsChecked }
                if ($dw.Tag.Text) { $script:DlgText = [string]$dw.Tag.Text.Text }
                $dw.Close()
            })
        [void]$wp.Children.Add($btn)
    }
    if ($TypeWord) {
        $gated = $tag.Gated; $word = $TypeWord; $boxRef = $tag.Text
        $boxRef.add_TextChanged({ param($s, $e) foreach ($g in $gated) { $g.IsEnabled = (([string]$boxRef.Text) -ceq $word) } }.GetNewClosure())
    }
    [void]$sp.Children.Add($wp)
    $w.Tag = $tag
    $w.Content = $sp
    return $w
}

function Show-Dialog {
    # One modal dialog primitive. Returns $null when it was closed with the window X (the caller then
    # takes the REFUSING path, never yes); otherwise Value (the clicked button), Checks, Text.
    # -TypeWord: the button marked NeedsWord stays disabled until the box holds exactly that word
    # (case-sensitive), so the approval is the operator's own typing, never a button alone.
    param(
        [string]$Id, [string]$Title, [string]$Message, [string]$Detail = '', $Buttons,
        $Checks = @(), [switch]$TextInput, [string]$InputLabel = '', [string]$InputDefault = '', [string]$TypeWord = ''
    )
    if ($script:TestMode) {
        $t = Get-TestAnswer $Id
        if ($null -eq $t) { return $null }
        # (PowerShell variables are case-insensitive: do not name this $checks, it would overwrite -Checks.)
        $ticked = @{}
        foreach ($c in @($Checks)) { $ticked[[string](Get-GuiProp $c 'Key' '')] = [bool](Get-GuiProp $c 'Checked' $false) }
        $tc = Get-GuiProp $t 'Checks' $null
        if ($tc) { foreach ($p in $tc.PSObject.Properties) { $ticked[$p.Name] = [bool]$p.Value } }
        return [pscustomobject]@{ Value = [string](Get-GuiProp $t 'Value' ''); Checks = $ticked; Text = [string](Get-GuiProp $t 'Text' '') }
    }
    $script:DlgValue = $null; $script:DlgChecks = @{}; $script:DlgText = $null
    $w = New-DialogWindow -Title $Title -Message $Message -Detail $Detail -Buttons $Buttons -Checks $Checks -TextInput:$TextInput -InputLabel $InputLabel -InputDefault $InputDefault -TypeWord $TypeWord
    $script:InDialog = $true
    try { [void]$w.ShowDialog() } finally { $script:InDialog = $false }
    if ($null -eq $script:DlgValue) { return $null }
    return [pscustomobject]@{ Value = $script:DlgValue; Checks = $script:DlgChecks; Text = $script:DlgText }
}

function Get-RecentConsole {
    param([int]$Count = 6)
    if ($Count -le 0) { return '' }
    $lines = @($ui.ConsoleBox.Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $take = [Math]::Min($Count, $lines.Count)
    if ($take -eq 0) { return '' }
    return (($lines[($lines.Count - $take)..($lines.Count - 1)]) -join "`r`n")
}

function Resolve-Prompt {
    # A script is waiting on Read-Host. Shows the dialog that names what is being asked and sends
    # the operator's own answer. The dialog's text and buttons come from steps.json "Prompts".
    param($Pending)
    $child = $script:Child
    if ($Pending.Kind -eq 'Unknown') {
        $r = Show-Dialog -Id 'Unknown' -Title 'The tool is waiting for an answer' -Message ('The tool is waiting for an answer:' + "`r`n`r`n" + 'Type an answer and Send, or close this box to send an empty line (the tool''s own default). Choose "This is not a question" only if the tool is still working; this box comes back after a minute if it is still waiting.') -Detail $Pending.Text -TextInput -Buttons @(
            @{ Text = 'Send'; Value = 'send' }, @{ Text = 'This is not a question'; Value = 'skip' })
        if ($r -and $r.Value -eq 'skip') { Set-GuiPromptDismissed -Child $child -Text $Pending.Text; Add-ConsoleNote 'Marked as not a question; the tool keeps running.' }
        elseif ($r -and $r.Value -eq 'send') { Send-GuiAnswer -Child $child -Text $r.Text; Add-ConsoleNote 'Answer sent to the tool.' }
        else { Send-GuiAnswer -Child $child -Text ''; Add-ConsoleNote 'Box closed: sent an empty line, the tool''s own default.' }
        return
    }
    $row = $Pending.Row
    $buttons = @(); $i = 0
    foreach ($b in @(ConvertTo-GuiItems $row.Buttons)) {
        $buttons += @{ Text = [string]$b.Text; Value = [string]$i; NeedsWord = [bool](Get-GuiProp $b 'NeedsWord' $false) }
        $i++
    }
    $word = [string](Get-GuiProp $row 'TypeWord' '')
    $r = Show-Dialog -Id ([string]$row.Id) -Title ([string](Get-GuiProp $row 'Title' 'The tool asks')) `
        -Message ([string](Get-GuiProp $row 'Message' $Pending.Text)) -Detail (Get-RecentConsole ([int](Get-GuiProp $row 'DetailLines' 0))) `
        -Buttons $buttons -TextInput:([bool](Get-GuiProp $row 'Input' $false)) -TypeWord $word
    $idx = $null; $typed = ''
    if ($r) { $idx = $r.Value; $typed = [string]$r.Text }
    $s = Resolve-GuiPromptSend -Row $row -ButtonIndex $idx -Typed $typed
    if ($s.Approved -and [bool](Get-GuiProp $row 'Lock' $false)) { $script:CloseLock = $true }
    Send-GuiAnswer -Child $child -Text $s.Send
}

function Resolve-Ask {
    # A question from steps.json "Asks", shown before its step. Accept records the tick boxes, the
    # typed text and the "Sets" answer; refusing or closing the box records everything as off.
    param($A)
    $def = Get-GuiAsk -Session $script:Session -Name $A.Ask
    $checks = @(ConvertTo-GuiItems (Get-GuiProp $def 'Checks' $null))
    $inp = Get-GuiProp $def 'Input' $null
    $buttons = @(@{ Text = [string](Get-GuiProp $def 'AcceptText' 'Continue'); Value = 'accept' })
    $refuseText = [string](Get-GuiProp $def 'RefuseText' '')
    if ($refuseText) { $buttons += @{ Text = $refuseText; Value = 'refuse' } }
    $r = Show-Dialog -Id $A.Ask -Title ([string](Get-GuiProp $def 'Title' $A.Title)) -Message ([string](Get-GuiProp $def 'Message' '')) `
        -Checks $checks -Buttons $buttons -TextInput:([bool]$inp) -InputLabel ([string](Get-GuiProp $inp 'Label' '')) -InputDefault ([string](Get-GuiProp $inp 'Default' ''))
    $accepted = [bool]($r -and $r.Value -eq 'accept')
    $vals = @{}
    foreach ($c in $checks) { $vals[[string]$c.Key] = [bool]($accepted -and $r.Checks[[string]$c.Key]) }
    if ($inp) { $vals[[string]$inp.Key] = $(if ($accepted) { [string]$r.Text } else { '' }) }
    $sets = [string](Get-GuiProp $def 'Sets' '')
    if ($sets) { $vals[$sets] = $accepted }
    Set-GuiAnswer -Session $script:Session -Ask $A.Ask -Values $vals
    Add-ConsoleNote ('Answer to "' + [string](Get-GuiProp $def 'Title' $A.Ask) + '": ' + $(if ($accepted) { 'accepted' } else { 'declined' }) + '.')
}

# ---- panels ------------------------------------------------------------------------------------
function Show-Banner {
    param([string]$Text, [string]$Kind = 'info')
    $bg = 'SurfaceSunken'; $bd = 'Border'; $fg = 'Foreground'
    if ($Kind -eq 'ok') { $bg = 'SuccessBg'; $bd = 'SuccessBorder'; $fg = 'SuccessFg' }
    if ($Kind -eq 'warn') { $bg = 'WarningBg'; $bd = 'WarningBorder'; $fg = 'WarningFg' }
    if ($Kind -eq 'bad') { $bg = 'DangerBg'; $bd = 'DangerBorder'; $fg = 'DangerFg' }
    $ui.Banner.Background = Get-Brush $bg
    $ui.Banner.BorderBrush = Get-Brush $bd
    $ui.BannerText.Foreground = Get-Brush $fg
    $ui.BannerText.FontWeight = 'SemiBold'
    $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
}

function Show-Panel {
    param([string]$Which)
    $ui.StartPanel.Visibility = $(if ($Which -eq 'Start') { 'Visible' } else { 'Collapsed' })
    $ui.RunPanel.Visibility = $(if ($Which -eq 'Run') { 'Visible' } else { 'Collapsed' })
}

function Update-HeaderButtons {
    $has = ($script:Session -and $script:Session.RunRoot -and (Test-Path -LiteralPath $script:Session.RunRoot))
    $ui.BtnOpenRun.IsEnabled = [bool]$has
    $ui.BtnOpenLog.IsEnabled = [bool]($script:LogPath -and (Test-Path -LiteralPath $script:LogPath))
}

function Show-RunSummary {
    # What the run's own files say (steps.json "Results" + the optional Summary hook). Read-only.
    param($Sess)
    $items = @(Get-GuiResultItems -Session $Sess)
    if ($items.Count -eq 0) { return }
    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = 'Results'; $head.FontSize = 15; $head.FontWeight = 'SemiBold'; $head.Margin = New-Object System.Windows.Thickness(0, 4, 0, 6)
    [void]$ui.CardsHost.Children.Add($head)
    foreach ($it in $items) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
        if ($it.Path) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = 'Open'; $btn.Tag = $it.Path; Set-ButtonStyle $btn 'Secondary'
            $btn.Padding = New-Object System.Windows.Thickness(10, 3, 10, 3); $btn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
            $btn.add_Click({ param($s, $e) try { Start-Process -FilePath ([string]$s.Tag) } catch { } })
            [void]$row.Children.Add($btn)
        }
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $it.Label + ': '; $lbl.FontWeight = 'SemiBold'; $lbl.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
        [void]$row.Children.Add($lbl)
        # A read-only box, so the value can be selected and copied.
        $val = New-Object System.Windows.Controls.TextBox
        $val.Text = $it.Value; $val.IsReadOnly = $true; $val.BorderThickness = New-Object System.Windows.Thickness(0)
        $val.Background = [System.Windows.Media.Brushes]::Transparent; $val.Foreground = Get-Brush $it.Tone; $val.TextWrapping = 'Wrap'; $val.VerticalAlignment = 'Center'
        [void]$row.Children.Add($val)
        [void]$ui.CardsHost.Children.Add($row)
    }
}

# ---- run control -------------------------------------------------------------------------------
function Get-SelectedMode {
    foreach ($rb in $script:ModeButtons) { if ($rb.IsChecked) { return [string]$rb.Tag } }
    return $script:Modes[0].Name
}

function Get-ModeLabel {
    param([string]$Name)
    return [string](@($script:Modes | Where-Object { $_.Name -eq $Name })[0].Label)
}

function Set-PreviewMode {
    param([string]$ModeName)
    $tmp = New-GuiSession -Mode $ModeName -ToolRoot $ToolRoot -RunRootBase $RunRootBase
    Initialize-Stepper $tmp.Plan
    $ui.InfoText.Text = 'PC: ' + $env:COMPUTERNAME + '     Mode: ' + (Get-ModeLabel $ModeName)
    Update-Stepper
}

function Save-Session {
    if (-not (Save-GuiSession $script:Session) -and -not $script:SessionWriteWarned) {
        $script:SessionWriteWarned = $true
        Add-ConsoleNote 'Could not write gui-session.json in the run folder (display data only; the run is not affected).'
    }
}

function Start-Run {
    param([string]$ModeName)
    $script:Finished = $false
    $sess = New-GuiSession -Mode $ModeName -ToolRoot $ToolRoot -RunRootBase $RunRootBase -Interactive
    try { $run = Initialize-GuiRunRoot -Session $sess }
    catch {
        $msg = $_.Exception.Message
        Add-ConsoleNote ('No run started: ' + $msg)
        if (-not $script:TestMode) { [void][System.Windows.MessageBox]::Show(('No run was started.' + "`n`n" + $msg), $script:ToolTitle, 'OK', 'Error') }
        if ($script:AutoStart) { $win.Close() }
        return
    }
    $script:Session = $sess
    Initialize-Stepper $sess.Plan
    $script:LogPath = ''
    if ($run) { $script:LogPath = Join-Path $run 'gui-console.log' }
    $ui.ConsoleBox.Clear()
    $ui.CardsHost.Children.Clear()
    $ui.Banner.Visibility = 'Collapsed'
    $ui.BtnNewRun.Visibility = 'Collapsed'
    $ui.InfoText.Text = 'PC: ' + $env:COMPUTERNAME + '     Mode: ' + (Get-ModeLabel $ModeName)
    $ui.RunText.Text = $(if ($run) { 'Run folder: ' + $run } else { '' })
    Show-Panel 'Run'
    Add-ConsoleNote ((Get-ModeLabel $ModeName) + $(if ($run) { '. Run folder: ' + $run } else { '' }))
    Save-Session
    Update-Stepper
    Update-HeaderButtons
    Move-Next
}

function Move-Next {
    # Starts the next call, or asks the next question, or finishes. Runs only on the UI thread and
    # only when no child is alive.
    while ($true) {
        $a = Get-GuiNextAction -Session $script:Session
        if (-not $a) { Complete-Run; return }
        $script:Action = $a
        if ($a.Kind -eq 'Ask') {
            $ui.StatusTitle.Text = 'Step ' + $a.StepId + ': ' + $a.Title + ' - waiting for you'
            $ui.StatusDetail.Text = 'Nothing has been changed by this step yet.'
            $ui.Busy.IsIndeterminate = $false
            Update-Stepper
            Resolve-Ask $a
            $script:Action = $null
            continue
        }
        $ui.StatusTitle.Text = 'Step ' + $a.StepId + ': ' + $a.Title
        $ui.StatusDetail.Text = ''
        $ui.Busy.IsIndeterminate = $true
        # A step marked "Destructive" in steps.json cannot be closed while it runs.
        $script:CloseLock = [bool]$a.Destructive
        Add-ConsoleLines @('', ('=== Step ' + $a.StepId + ': ' + $a.Title + ' ==='), ('> ' + [IO.Path]::GetFileName($a.ScriptPath) + ' ' + (ConvertTo-GuiArgString $a.Args)))
        try {
            $script:Child = Start-GuiChild -ScriptPath $a.ScriptPath -ArgumentList $a.Args -WorkingDirectory $script:Session.ToolRoot
        } catch {
            Add-ConsoleNote ('Could not start ' + $a.ScriptPath + ': ' + $_.Exception.Message)
            [void](Complete-GuiAction -Session $script:Session -Action $a -ExitCode 1 -Message $_.Exception.Message)
            $script:Action = $null
            continue
        }
        Update-Stepper
        return
    }
}

function Complete-Run {
    $script:Action = $null
    $script:Child = $null
    $script:CloseLock = $false
    $script:Finished = $true
    $sess = $script:Session
    $ui.Busy.IsIndeterminate = $false
    $ui.Busy.Value = 1
    $ui.StatusTitle.Text = $(if ($sess.Stopped) { 'Stopped' } else { 'Finished' })
    $ui.StatusDetail.Text = ''
    Save-Session
    Show-RunSummary $sess
    $alerts = @($sess.Results | Where-Object { $_.Status -eq 'Alert' }).Count
    $warns = @($sess.Results | Where-Object { $_.Status -eq 'Warn' -or $_.Status -eq 'Failed' }).Count
    if ($sess.Stopped) { Show-Banner ($sess.StopMessage + ' See the console output below and the log.') 'bad' }
    elseif ($alerts -gt 0) { Show-Banner (@($sess.Results | Where-Object { $_.Status -eq 'Alert' })[0].Message) 'bad' }
    elseif ((Get-GuiFinalStatus $sess) -ne 0 -or $warns -gt 0) { Show-Banner ('Finished with warnings (' + $warns + ' step(s) marked; first non-zero code ' + (Get-GuiFinalStatus $sess) + '). Review the steps marked with a warning.') 'warn' }
    else { Show-Banner ([string](Get-GuiProp $script:Tool 'DoneText' 'Finished.')) 'ok' }
    $ui.BtnNewRun.Visibility = 'Visible'
    Update-Stepper
    Update-HeaderButtons
    if ($script:TestMode) { Write-ResultFile }
    if ($script:AutoStart) { $win.Close() }
}

function Write-ResultFile {
    # Test hook only (-ResultPath): the final window state, for tests\gui.
    try {
        $steps = [ordered]@{}
        foreach ($id in @($script:StepRows.Keys | Sort-Object)) { $steps[$id] = $script:StepRows[$id].State.Text }
        $answers = [ordered]@{}
        foreach ($k in @($script:Session.Answers.Keys | Sort-Object)) { $answers[$k] = $script:Session.Answers[$k] }
        $doc = [ordered]@{
            Mode = $script:Session.Mode; Steps = $steps
            Banner = $ui.BannerText.Text; BannerVisible = ($ui.Banner.Visibility -eq 'Visible')
            Stopped = [bool]$script:Session.Stopped; FinalStatus = (Get-GuiFinalStatus $script:Session)
            RunRoot = $script:Session.RunRoot; Answers = $answers
            ConsoleChars = $ui.ConsoleBox.Text.Length; DpiMode = $script:DpiMode; Theme = $script:ThemeName
            ResultItems = @(Get-GuiResultItems -Session $script:Session | ForEach-Object { [ordered]@{ Label = $_.Label; Value = $_.Value } })
            Results = @($script:Session.Results | ForEach-Object { [ordered]@{ Step = $_.StepId; Status = $_.Status; ExitCode = $_.ExitCode; Message = $_.Message } })
        }
        ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    } catch { }
}

function Invoke-Tick {
    if ($script:InDialog -or -not $script:Child) { return }
    $u = Update-GuiChild -Child $script:Child
    if (@($u.Lines).Count -gt 0) {
        Add-ConsoleLines $u.Lines
        Update-GuiCapture -Session $script:Session -Action $script:Action -Lines $u.Lines
    }
    if ($u.Exited) {
        $a = $script:Action
        $script:CloseLock = $false
        # A call marked "Retry": true may be run again when it fails. Nothing is recorded for the
        # failed attempt until the operator decides; the console keeps its output.
        if ([int]$u.ExitCode -ne 0 -and [bool](Get-GuiProp $a.Call 'Retry' $false)) {
            $r = Show-Dialog -Id 'Retry' -Title ('Step ' + $a.StepId + ' did not finish cleanly') -Message ('"' + $a.Title + '" ended with exit code ' + $u.ExitCode + '. See the console output for why. Run this step again, or continue with the next one?') -Buttons @(
                @{ Text = 'Run it again'; Value = 'retry' }, @{ Text = 'Continue'; Value = 'continue' })
            if ($r -and $r.Value -eq 'retry') {
                Add-ConsoleLines @('', ('=== Step ' + $a.StepId + ': ' + $a.Title + ' (again) ==='))
                $script:Child = Start-GuiChild -ScriptPath $a.ScriptPath -ArgumentList $a.Args -WorkingDirectory $script:Session.ToolRoot
                $script:CloseLock = [bool]$a.Destructive
                return
            }
        }
        $o = Complete-GuiAction -Session $script:Session -Action $a -ExitCode ([int]$u.ExitCode)
        $script:Child = $null
        $script:Action = $null
        Add-ConsoleNote ('Step ' + $o.StepId + ' ended with exit code ' + $o.ExitCode + ' (' + $o.Status + ')' + $(if ($o.Message) { ': ' + $o.Message } else { '' }))
        Save-Session
        Update-Stepper
        Update-HeaderButtons
        Move-Next
        return
    }
    $elapsed = (Get-Date).ToUniversalTime() - $script:Child.StartedUtc
    $quiet = (Get-Date).ToUniversalTime() - $script:Child.LastOutputUtc
    $text = 'Running for ' + ('{0:00}:{1:00}' -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds)
    if ($quiet.TotalMinutes -ge 2) { $text += ' - no output for ' + [int][Math]::Floor($quiet.TotalMinutes) + ' minutes (information only; the tool is never stopped automatically)' }
    $ui.StatusDetail.Text = $text
    $pp = Get-GuiPendingPrompt -Child $script:Child -Catalog $script:Catalog
    if ($pp) { Resolve-Prompt $pp }
}

# ---- self-test (no window is shown, nothing runs) -------------------------------------------------
if ($SelfTest) {
    $fails = New-Object System.Collections.ArrayList
    $gates = 0
    foreach ($row in (Get-GuiPromptTable $script:Catalog)) {
        $word = [string](Get-GuiProp $row 'TypeWord' '')
        if (-not $word) { continue }
        $gates++
        $buttons = @(); $i = 0
        foreach ($b in @(ConvertTo-GuiItems $row.Buttons)) { $buttons += @{ Text = [string]$b.Text; Value = [string]$i; NeedsWord = [bool](Get-GuiProp $b 'NeedsWord' $false) }; $i++ }
        $dw = New-DialogWindow -Title 'x' -Message 'x' -TypeWord $word -Buttons $buttons
        $made = @($dw.Content.Children[$dw.Content.Children.Count - 1].Children)
        $box = $dw.Tag.Text
        $gated = @(); $free = @()
        for ($k = 0; $k -lt $made.Count; $k++) { if ($buttons[$k].NeedsWord) { $gated += $made[$k] } else { $free += $made[$k] } }
        $name = [string]$row.Id
        if ($gated.Count -eq 0) { [void]$fails.Add($name + ': has TypeWord but no button is marked NeedsWord') }
        if ($free.Count -eq 0) { [void]$fails.Add($name + ': has no refusing button') }
        foreach ($g in $gated) {
            if ($g.IsEnabled) { [void]$fails.Add($name + ': the approve button is enabled before anything is typed') }
            foreach ($wrong in @($word.ToLowerInvariant(), ($word + ' '), (' ' + $word), $word.Substring(0, $word.Length - 1))) {
                if ($wrong -ceq $word) { continue }
                $box.Text = $wrong
                if ($g.IsEnabled) { [void]$fails.Add($name + ': "' + $wrong + '" enables the approve button') }
            }
            $box.Text = $word
            if (-not $g.IsEnabled) { [void]$fails.Add($name + ': typing exactly ' + $word + ' does not enable the approve button') }
            $box.Text = ''
            if ($g.IsEnabled) { [void]$fails.Add($name + ': clearing the box leaves the approve button enabled') }
            if ($g.Style -ne $win.FindResource('Button.Danger')) { [void]$fails.Add($name + ': the approve button is not styled as Danger') }
        }
        foreach ($f in $free) { if (-not $f.IsEnabled) { [void]$fails.Add($name + ': a refusing button is disabled') } }
    }
    $plain = New-DialogWindow -Title 'Plain' -Message 'x' -Buttons @(@{ Text = 'Continue'; Value = 'go' })
    if (-not @($plain.Content.Children[$plain.Content.Children.Count - 1].Children)[0].IsEnabled) { [void]$fails.Add('a dialog without a typed word has its button disabled') }
    # Both palettes define the same tokens, and every token the script asks for exists.
    $light = @($win.Resources.Keys | Where-Object { ([string]$_).StartsWith('Brush.') } | ForEach-Object { [string]$_ } | Sort-Object)
    $dark = @($win.Resources['Theme.Dark'].Keys | Where-Object { $_ -is [string] -and $_.StartsWith('Brush.') } | Sort-Object)
    if (($light -join ',') -ne ($dark -join ',')) { [void]$fails.Add('light and dark palettes define different tokens') }
    $src = [IO.File]::ReadAllText($PSCommandPath)
    foreach ($m in [regex]::Matches($src, "Get-Brush '(\w+)'")) { if ($light -notcontains ('Brush.' + $m.Groups[1].Value)) { [void]$fails.Add('unknown token: ' + $m.Groups[1].Value) } }
    if ($fails.Count -eq 0) { Write-Host ('SELFTEST_OK gates=' + $gates + ' tokens=' + $light.Count + ' theme=' + $script:ThemeName + ' dpi=' + $script:DpiMode); exit 0 }
    $fails | ForEach-Object { Write-Host ('SELFTEST_FAIL ' + $_) }
    exit 1
}

# ---- wiring --------------------------------------------------------------------------------------
$win.Title = $script:ToolTitle
$ui.TitleText.Text = $script:ToolTitle + $(if ($script:Version) { '  v' + $script:Version } else { '' })
$footer = [string](Get-GuiProp $script:Tool 'Footer' '')
$ui.FooterText.Text = $footer
if (-not $footer) { $ui.FooterText.Visibility = 'Collapsed' }

# One selectable card per mode of steps.json.
$first = $true
foreach ($m in $script:Modes) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = 'Mode'; $rb.Tag = $m.Name; $rb.Style = $win.FindResource('ModeCard')
    $msp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $m.Label; $t1.FontSize = 14; $t1.FontWeight = 'SemiBold'
    [void]$msp.Children.Add($t1)
    if ($m.Description) {
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = $m.Description; $t2.Style = $win.FindResource('Text.Muted'); $t2.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
        [void]$msp.Children.Add($t2)
    }
    $rb.Content = $msp
    $rb.add_Checked({ param($s, $e) if (-not $script:Session -or $script:Finished) { Set-PreviewMode ([string]$s.Tag) } })
    [void]$ui.ModesHost.Children.Add($rb)
    $script:ModeButtons += $rb
    if ($first) { $rb.IsChecked = $true; $first = $false }
}
Update-HeaderButtons

$ui.BtnStart.add_Click({ Start-Run (Get-SelectedMode) })
$ui.BtnNewRun.add_Click({
        $script:Session = $null; $script:Action = $null; $script:Child = $null; $script:LogPath = ''; $script:Finished = $false
        $ui.RunText.Text = ''
        Set-PreviewMode (Get-SelectedMode); Update-HeaderButtons; Show-Panel 'Start'
    })
$ui.BtnOpenRun.add_Click({ if ($script:Session -and $script:Session.RunRoot) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:Session.RunRoot + '"') } })
$ui.BtnOpenLog.add_Click({ if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:LogPath + '"') } })
$ui.BtnCopy.add_Click({ try { [System.Windows.Clipboard]::SetText($ui.ConsoleBox.Text) } catch { } })

function Write-GuiError {
    param([string]$Text)
    $errDir = $(if ($script:Session -and $script:Session.RunRoot) { $script:Session.RunRoot } else { $env:TEMP })
    try { [IO.File]::AppendAllText((Join-Path $errDir 'gui-error.log'), (Get-Date -Format 's') + ' ' + $Text + "`r`n") } catch { }
}

# ONE timer on the UI thread polls the running child. No runspaces, no Register-ObjectEvent, no
# script blocks on thread-pool threads: a PowerShell handler that fires on another thread has no
# runspace.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.add_Tick({
        try { Invoke-Tick }
        catch {
            try { Add-ConsoleNote ('GUI error: ' + $_.Exception.Message) } catch { }
            Write-GuiError $_.ToString()
        }
    })

$win.add_Closing({
        param($s, $e)
        if ($script:Child -and -not $script:Child.Finished) {
            if ($script:CloseLock) {
                [void][System.Windows.MessageBox]::Show([string](Get-GuiProp $script:Tool 'LockedText' 'A change is in progress. Wait for this step to finish.'), $script:ToolTitle, 'OK', 'Warning')
                $e.Cancel = $true
                return
            }
            # A program the operator is driving is left open when the window closes ("KeepChildrenOnClose").
            $keep = [bool](Get-GuiProp $script:Action.Call 'KeepChildrenOnClose' $false)
            if (-not $script:AutoStart) {
                $q = $(if ($keep) { 'A program this step opened is still running. Close this window? That program stays open; finish or close it yourself.' } else { 'A step is still running. Stop it and close?' })
                $ans = [System.Windows.MessageBox]::Show($q, $script:ToolTitle, 'YesNo', 'Question')
                if ($ans -ne 'Yes') { $e.Cancel = $true; return }
            }
            if ($keep) { Stop-GuiChild $script:Child -KeepDescendants } else { Stop-GuiChild $script:Child }
        }
    })

[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($s, $e)
        try {
            Write-GuiError $e.Exception.ToString()
            [void][System.Windows.MessageBox]::Show(('The window hit an error. A running step is left untouched:' + "`n`n" + $e.Exception.Message), $script:ToolTitle, 'OK', 'Warning')
        } catch { }
        $e.Handled = $true
    })

# ---- fit the screen ---------------------------------------------------------------------------------
# A 1366x768 laptop at 150% has about 910x480 device-independent pixels of work area, so the window is
# sized to the work area and below 1000 wide / 660 high it switches to a compact layout.
$script:Compact = @{ Width = $null; Height = $null }
function Set-WindowFitToScreen {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w = [Math]::Min(1120, $wa.Width - 16); $h = [Math]::Min(760, $wa.Height - 16)
    $win.MinWidth = [Math]::Min(760, $w); $win.MinHeight = [Math]::Min(460, $h)
    $win.Width = $w; $win.Height = $h
}
function Update-CompactLayout {
    $narrow = ($win.ActualWidth -gt 0 -and $win.ActualWidth -lt 1000)
    $short = ($win.ActualHeight -gt 0 -and $win.ActualHeight -lt 660)
    if ($script:Compact.Width -ne $narrow) {
        $ui.ColStepper.Width = New-Object System.Windows.GridLength $(if ($narrow) { 212 } else { 268 })
        $script:Compact.Width = $narrow
    }
    if ($script:Compact.Height -ne $short) {
        $ui.RowConsole.Height = New-Object System.Windows.GridLength $(if ($short) { 88 } else { 170 })
        $ui.RootGrid.Margin = $(if ($short) { New-Object System.Windows.Thickness(10, 8, 10, 4) } else { New-Object System.Windows.Thickness(16, 16, 16, 8) })
        $ui.HeaderCard.Padding = $(if ($short) { New-Object System.Windows.Thickness(14, 6, 14, 6) } else { New-Object System.Windows.Thickness(18, 12, 18, 12) })
        $ui.TitleText.FontSize = $(if ($short) { 16 } else { 19 })
        $ui.StatusCard.Padding = $(if ($short) { New-Object System.Windows.Thickness(14, 6, 14, 8) } else { New-Object System.Windows.Thickness(16, 12, 16, 12) })
        $script:Compact.Height = $short
    }
}
function Update-TextMode {
    # Display text is sharpest at 100%; at higher scales Ideal text looks better. Follows the monitor.
    $scale = 1.0
    try { $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleX } catch { }
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($win, $(if ($scale -gt 1.01) { 'Ideal' } else { 'Display' }))
}
Set-WindowFitToScreen
$win.add_SizeChanged({ Update-CompactLayout })
$win.add_DpiChanged({ Update-TextMode })

$win.add_Loaded({
        Update-TextMode
        Update-CompactLayout
        $timer.Start()
        if ($script:AutoStart) { Start-Run $startMode }
    })

try {
    [void]$win.ShowDialog()
} finally {
    $timer.Stop()
    if ($script:Child -and -not $script:Child.Finished) { Stop-GuiChild $script:Child }
    Restore-GuiConsoleEncoding $script:ConsoleSaved
}
# Exit 0 after a normal close (the run's own status is in gui-session.json). A non-zero exit means
# the window itself failed, which makes the launcher pause so the error can be read.
exit 0
