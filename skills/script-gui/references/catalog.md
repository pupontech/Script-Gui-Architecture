# gui\steps.json - the catalog

The catalog describes steps, questions and results. The working version 2 example is
`template/gui/steps.json`. When updating a version 1 catalog, add each prompt ID to the calls
that can emit it, then set `"SchemaVersion": 2`.

Paths in the catalog are relative to the tool folder (the parent of `gui\`). Backslashes are doubled
in JSON (`"gui\\demo\\Demo-Tool.ps1"`).

## Tokens

Usable in `Args`, `RequireOutput`, `SetVar` values, `Results` paths and `Exists:` conditions.

| Token | Value |
|---|---|
| `{ToolRoot}` | the tool folder, **ending with `\`** (write `{ToolRoot}tools\x.exe`) |
| `{RunRoot}` | this run's folder (empty when the mode has none) |
| `{Mode}`, `{Phase}` | the chosen mode's name and its `Phase` |
| `{PipeRc}` | the first non-zero exit code so far that counts (0 = none) |
| `{Answer:<key>}` | an answer from an Ask (text; a tick box gives `True` / `False`) |
| `{Var:<name>}` | a session variable set by `SetVar`, `Capture` or a hook |

## Conditions

Used in `When`, `Needs` and conditional argument groups. A list means all must hold.

| Condition | True when |
|---|---|
| `Answer:<key>` / `NotAnswer:<key>` | the tick box is ticked, or the text is not empty |
| `Var:<name>` / `NotVar:<name>` | the session variable is not empty |
| `Exists:<path>` / `NotExists:<path>` | the file or folder exists (tokens allowed) |
| `Phase:<name>` | the chosen mode's Phase is that name |

## Tool

```json
{
  "Tool": {
    "Title": "Student Cleanup",
    "RequireAdmin": true,
    "RunRootBase": "C:\\RIT-Cleanup",
    "VersionFile": "VERSION",
    "Footer": "",
    "DoneText": "Finished.",
    "LockedText": "..."
  }
}
```

Keep `RequireAdmin` in sync with `SG_NEED_ADMIN` in the batch launcher. `RunRootBase`
supports `%ENV%` expansion. Use an empty base only when every mode skips run-folder creation.
`VersionFile`, `Footer`, `DoneText` and `LockedText` customize the header, footer and status messages.

## Modes

What the start panel offers, in this order. One mode is fine.

```json
{
  "Modes": {
    "Check": { "Phase": "CHECK", "RunRoot": "new",  "Label": "Check only - nothing is changed", "Description": "..." },
    "Stage": { "Phase": "STAGE", "RunRoot": "none", "Label": "Download tools only", "Description": "..." }
  }
}
```

- `Phase` selects steps: a step (or a single call) runs when its `Phases` list contains it. No `Phases`
  = every mode.
- `RunRoot`: `new` creates `<RunRootBase>\<PC>-<yyyyMMdd-HHmmss>-<4 hex>`; `none` creates nothing.
  A mode that needs a folder and cannot create one does not run.

## Steps and calls

```json
{ "Id": "2", "Title": "Change", "Destructive": true, "Phases": ["FULL"],
  "Calls": [ { "Script": "Do-Change.ps1", "Args": ["-OutDir", "{RunRoot}"] } ] }
```

`Id` is what the operator sees ("2", "6a"). A step shows as one row; its calls run in order.
`Destructive: true` = the window cannot be closed while a call of this step runs.

Call fields:

| Field | Meaning | Default |
|---|---|---|
| `Script` | script to run, relative to the tool folder | required |
| `Args` | list of strings (tokens expanded) and conditional groups `{ "When": [...], "Args": [...] }` | none |
| `Phases` | limit this one call to some phases | the step's |
| `Prompts` | IDs of all prompt rows this call can emit | none |
| `Ask` | name of an Ask to show before this call (asked once per run) | none |
| `When` | conditions; false = the call is recorded as skipped | always |
| `SkipText` | what the skipped row says | "Not needed." |
| `Needs` | conditions that should hold; false = warning, call not run, run continues | none |
| `NeedsText` | the warning text | generic |
| `OnMissing` | script file absent: `Stop` or `WarnSkip` | `Stop` |
| `MissingMessage` | text for that | generic |
| `OnNonZero` | exit code not 0: `Warn` (mark the run, continue), `Ignore`, `Stop` | `Warn` |
| `NonZeroText`, `StopMessage` | texts for those | generic |
| `ExitCodes` | per-code override for an exit returned by a started script | none |
| `RequireOutput` | file that must exist after exit 0, else the run stops | none |
| `SetVar` | `{ "Name": "value with tokens" }` set after the call | none |
| `Capture` | `[ { "Var": "Url", "Pattern": "^UPLOAD: (\\S+)$" } ]` - a value the script prints (group 1) | none |
| `Retry` | on a non-zero exit, offer "Run it again / Continue" | false |
| `KeepChildrenOnClose` | closing the window ends only the script, not a program it opened | false |
| `Before`, `After` | hook names (see Hooks) | none |

`ExitCodes` - when a code is a finding or a normal answer rather than a failure:

```json
{
  "ExitCodes": {
    "1": { "Status": "Alert", "Message": "Removed items came back.", "Stop": false },
    "3": { "Status": "Done",  "Message": "Not applied - you declined.", "Counts": false }
  }
}
```

`Status`: `Done`, `Warn`, `Failed`, `Alert` (red, run continues unless `Stop`). `Counts: false` keeps the
code out of the run's final status.

**Order of checks for one call:** Ask (if its other conditions hold) -> `When` -> script exists ->
`Needs` -> `Before` hook -> run -> exit-code rule -> `RequireOutput` -> `SetVar` -> `After` hook.

A process that fails to start stops the run with a failed step and no child exit code.

## Asks - questions before a step

For choices the console launcher asked with `set /p`, and for options the scripts take as arguments.

```json
{
  "Asks": {
    "Options": {
      "Title": "Options", "Message": "Choose how it should run.",
      "Checks": [ { "Key": "Thorough", "Text": "Thorough mode", "Checked": false },
                  { "Key": "ResetGpo", "Text": "Also reset policy", "Checked": false, "DependsOn": "Thorough" } ],
      "Input":  { "Key": "Note", "Label": "Note (optional)", "Default": "" },
      "Sets": "DoChange", "Default": false,
      "AcceptText": "Continue", "RefuseText": "Skip the change"
    }
  }
}
```

- Accept: each tick box becomes `Answer:<Key>`, the text becomes `{Answer:<Key>}`, and `Sets` becomes true.
- Refuse, or closing the box: every tick box false, text empty, `Sets` false.
- No `RefuseText` = one button only (closing the box still refuses).
- `Checked` / `Default` are what a headless run (tests) uses. Keep them equal to the console launcher's
  defaults, and keep anything that changes the PC defaulting to off.
- Typical pairing: `"Ask": "Options", "When": ["Answer:DoChange"]` on the call.

An Ask is a convenience, not a safety gate: it only chooses arguments. The gate is the script's own
prompt (next section).

## Prompts - questions a script asks with Read-Host

```json
{
  "Prompts": [
    { "Id": "ApplyConfirm",
      "Needles": ["Apply the change? [y/N]"],
      "Scripts": ["Do-Change.ps1"],
      "Title": "Confirm the change", "Message": "...\r\n\r\nType APPLY to confirm.",
      "DetailLines": 6,
      "TypeWord": "APPLY",
      "Buttons": [ { "Text": "Apply", "Send": "y", "NeedsWord": true },
                   { "Text": "Do not apply", "Send": "n" } ],
      "Refuse": "n",
      "Lock": true }
  ]
}
```

- List each row's `Id` in `Prompts` on the calls that may emit it. A row matches when the active
  call declares it and the script's **unfinished output line** equals a Needle exactly (case-sensitive,
  trimmed). Print it with `Write-Host '<text>' -NoNewline` then use `Read-Host`. `Scripts` lists source
  files for the contract test. An unrecognized line receives no reply.
- `Send` is the exact line written to the script. `"Send": "{Typed}"` sends what the operator typed
  (use with `"Input": true` for free text such as a list of numbers).
- A script that itself wants a word typed (`Type REMOVE to confirm`): `"TypeWord": "REMOVE"`, button
  `{ "Send": "{Typed}", "NeedsWord": true }`, `"Refuse": ""`.
- Declare the script's exact single-line refusal in `Refuse`. For a row with `TypeWord`, every
  button that sends a different response must use `NeedsWord`; an ungated button must send
  `Refuse`. Set `Lock` when approval starts a change that cannot be interrupted.
- Three or more buttons are fine (for example Y / F / stop).

## Results - the finish panel

```json
{
  "Results": [
    { "Label": "Report", "Path": "{RunRoot}\\report.html" },
    { "Label": "Paste link", "Var": "ShareUrl" },
    { "Label": "Note", "Text": "Mode {Mode}", "When": ["Phase:FULL"] }
  ]
}
```

## Hooks - gui\Gui.Tool.psm1 (optional)

For what data cannot say. The file is imported after `Gui.Core.psm1` by the window and by the test.

```powershell
Set-StrictMode -Version 2.0

# "After": "FindFindings" on a call. Runs after the exit-code rules, unless the run is stopping.
Register-GuiHook -Name 'After:FindFindings' -Script {
    param($Session, $Action, $ExitCode)
    $d = Get-ChildItem -LiteralPath (Join-Path $Session.RunRoot 'detect') -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $d) { return @{ Status = 'Warn'; Message = 'No findings were written.' } }
    $Session.Vars['Findings'] = Join-Path $d.FullName 'findings.json'      # now usable as {Var:Findings}
    return @{ Message = 'Findings: ' + $Session.Vars['Findings'] }
}

# Extra lines for the finish panel, read from the run's own files.
Register-GuiHook -Name 'Summary' -Script {
    param($Session)
    $r = Read-GuiJson -Path (Join-Path $Session.RunRoot 'result.json')
    if (-not $r.Ok) { return @(@{ Label = 'Result'; Value = 'not available (' + $r.Error + ')'; Tone = 'WarningFg' }) }
    return @(@{ Label = 'Items changed'; Value = [string]@(ConvertTo-GuiItems $r.Data.Items).Count })
}
```

- `After:` may return a hashtable with `Status`, `Message`, `Stop`. `Before:<name>` gets `($Session, $Action)`.
- `Summary` returns items with `Label`, `Value`, optional `Path` (adds an Open button) and `Tone`
  (`Foreground`, `Muted`, `SuccessFg`, `WarningFg`, `DangerFg`).
- Use `Read-GuiJson`, `Get-GuiProp` and `ConvertTo-GuiItems` to read files: they survive missing files,
  half-written JSON and the one-item-array trap.
- A hook reads files and sets variables. It must not do the tool's work and must not use WPF types.

## Tool-specific panels

If the tool needs a real review screen (the ScreenConnect window's Keep / Remove cards), that is code in
`Start-Gui.ps1`: build controls into `$ui.CardsHost`, using `Get-Brush '<token>'` and the XAML styles
(`Card`, `Text.Overline`, `Button.Primary` ...). Model: `New-InstanceCard`, `Show-Findings` and
`Complete-Review` in `screenconnect-cleanup/gui/Start-CleanupGui.ps1`. Keep the reading of the file in
`Gui.Tool.psm1` (testable) and only the controls in the window script.
