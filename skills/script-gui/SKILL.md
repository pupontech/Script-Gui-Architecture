---
name: script-gui
description: >
  Put a window (GUI) on top of an existing PowerShell technician tool - a staged script or a set of scripts
  run by a .bat launcher - without rewriting the tool. Scaffolds a tested PowerShell 5.1 + WPF kit (stepper,
  live console, dialogs for the script's own questions, typed-word confirmation for destructive steps, light
  and dark theme, small-screen layout) driven by one data file, gui\steps.json. Trigger on "make a GUI for
  this script", "add a window to <tool>", "GUI like the ScreenConnect cleanup one", "technicians should not
  have to use the console for <tool>". Windows-only by nature; the scaffolder runs on Windows and WSL2.
---

# script-gui

A kit for giving a console tool a window. It is the ScreenConnect Cleanup GUI
(`screenconnect-cleanup/gui`, design in its `docs/14-gui-architecture.md`) with everything specific to
that tool taken out and moved into one data file.

## The one rule

**The window is a second front end, never a second engine.** It starts the tool's own scripts as child
`powershell.exe` processes, with arguments named in `gui\steps.json`, one at a time, and shows the files
they write. It holds none of the tool's logic.

Two earlier GUI attempts on ScreenConnect Cleanup each grew past 20,000 lines and were never merged,
because they re-implemented the pipeline (and one ran the tool's code inside the window's process). If a
window feature needs a line of the tool's logic, change the tool's script and call it. A finished window
should add little beyond `steps.json`; the kit itself is about 2,100 lines (layout included) and you should rarely edit it.

## When it fits

Fits: a tool that runs steps in order, prints progress, sometimes asks a question, and reports through
exit codes and files. ScreenConnect Cleanup is the worked example for a legacy batch pipeline.
For a read-only diagnostic, start with one unelevated mode, no prompts, and a structured report.
For a backup or repair tool you own, consider one shared runner for CLI and GUI. Keep the preview
and approval in that runner or its scripts. Use PowerShell's `ShouldProcess` where `-WhatIf` and
`-Confirm` fit the operation.

Does not fit: a tool whose main screen is an editor or a form with live state (the hour grid of
`student-times-gui`, a settings editor). Those need a purpose-built window; do not bend this kit into one.

## What you get

```text
<tool>\
  Run-<Name>Gui.bat        launcher: paren-safe path capture, one UAC prompt if needed, -STA
  gui\
    steps.json             THE file you edit: modes, steps, questions, prompts, results
    Start-Gui.ps1          the window (kit - rarely edited)
    Gui.Core.psm1          logic, no WPF types, tested headless (kit - rarely edited)
    MainWindow.xaml        layout + design tokens (kit - edit text and colours only)
    Gui.Tool.psm1          OPTIONAL, yours: hooks for what the catalog cannot say
    demo\Demo-Tool.ps1     stand-in script so the window runs out of the box - delete when done
  tests\gui\Test-Gui.ps1   house rules, catalog checks, prompt handling, window checks
```

## Procedure

1. **Read the tool first.** List, from the real code: every script the launcher runs and in what order,
   with which arguments; every question (`set /p` in a `.bat`, `Read-Host` in a script); what each exit
   code means; which files each step writes; which steps change the PC. Do not design the window before
   this list exists.

2. **Scaffold** (from the repo root; `python3` on WSL2):

   ```
   py "<skill folder>/scripts/new_script_gui.py" --target "<tool folder>" --title "<Tool Name>"
   ```

   Replace `<skill folder>` with the directory containing this `SKILL.md`. Add `--admin` if the tool
   needs administrator rights (one UAC prompt and an elevated window).
   Existing files are never overwritten without `--force`. Then run the tests once to see the demo pass:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tests\gui\Test-Gui.ps1` (not elevated).

3. **Write `gui\steps.json`** from the list in step 1. Schema and every field: `references/catalog.md`.
   - One **Step** per thing the operator thinks of as a step; each has one or more **Calls** (script +
     arguments). Mark steps that change the PC `"Destructive": true`.
   - Questions the **launcher** asked (`set /p`) become **Asks**: a dialog before the step, whose tick
     boxes and text feed `When` conditions and arguments.
   - Questions a **script** asks (`Read-Host`) become **Prompts**: the window recognises the question in
     the script's output only when the active call lists that prompt ID. The window shows a dialog
     and sends the selected answer. The script keeps its gate. Use distinct prompt text for each
     question within a call and test it with redirected input.
   - Copy each step's failure rule from the launcher exactly (`OnNonZero`, `ExitCodes`, `RequireOutput`).
     Distinguish failure to start a process from any exit code returned by the script.
   - Keep passwords, tokens and other secrets out of arguments, prompts and script output. The window
     saves child output to the run log. For an elevated workflow that reads prior artifacts, have the
     engine create and validate a protected run folder (see the ScreenConnect reference).
   - Delete `gui\demo` once nothing points at it.

4. **Fix the scripts' prompts** (this is usually the only change to the tool). Every question must be
   printed by the script itself, without a line end, and read with a bare `Read-Host`:

   ```powershell
   Write-Host 'Apply the change? [y/N]' -NoNewline
   $answer = Read-Host
   ```

   `Read-Host 'text'` shows nothing when the window runs the script, so the window could not see the
   question. If the script must keep passing the text to `Read-Host` (tests that mock it), add
   `if ([Console]::IsInputRedirected) { Write-Host 'text' -NoNewline }` before it. The test checks this.

5. **Destructive confirmations.** For every prompt that approves a change to the PC, set `"TypeWord"`
   (for example `REMOVE`) and mark the approving button `"NeedsWord": true`, set `"Refuse"` to the
   script's own "no", and `"Lock": true`. Never add an auto-approve switch to the tool for the window's
   sake.

6. **Hooks, only if needed.** When a step's result depends on something the catalog cannot express
   (find the newest output folder, read a status out of a JSON file), write `gui\Gui.Tool.psm1` and call
   `Register-GuiHook`. Example in `references/catalog.md`. No WPF types and none of the tool's logic in it.

7. **Tests.** Parts A-D of `tests\gui\Test-Gui.ps1` are generic and must stay green. Replace part E
   (the demo run) with runs of the real catalog against **stub** copies of the tool's scripts - stubs
   that record `script|arguments` and write the one file the next step needs - and compare the calls with
   what the launcher makes. That call-parity test is what stops the window drifting from the console
   flow. Include launch failure, output missing, declined changes, prompt wording drift, and exit codes
   that indicate findings. Never drive the real scripts from a test. Model:
   `screenconnect-cleanup/tests/gui/Test-GuiCallParity.ps1`.

8. **Keep the console launcher.** The `.bat` the tool already has stays, unchanged, as the fallback.

9. **Verify on a real PC what the tests cannot**: the UAC relaunch, a real destructive step through the
   dialog on a disposable Windows machine with known fixtures, a 125% / 150% scaled laptop screen, and
   any program a step opens. State which checks were run in the handover.

10. **Apply the target repository's conventions.** The supplied kit targets Windows PowerShell 5.1
    and uses ASCII source files, fixed GUI filenames and CRLF for the launcher. Set `Tool.VersionFile`
    if the tool publishes a version file.

## Rules the kit enforces - do not weaken them

- An approving answer reaches a script only as the direct result of the operator's click or typing in a
  dialog that names what is approved. Closing a recognized prompt dialog sends its explicit refusing
  answer. An unfinished line that was not recognized receives no response.
- Each run collects fresh answers. Automated answers live in the headless stub tests.
- One child process at a time; the window sets no timeouts and never kills a step on its own.
- A `Destructive` step cannot be closed while it runs.
- `gui-session.json` in the run folder is display data. Nothing reads it to decide what may run.
- Every state has a word, not only a colour. Colours come only from the tokens in `MainWindow.xaml`.

## Before changing the kit files

Read `references/gotchas.md` first. Each item there is a bug that was already hit once (invisible
prompts, the byte order mark on UTF-8 consoles, script-block handlers on other threads, hashtable keys,
DPI). After any change to `template\`, scaffold into a scratch folder whose name has a space and
parentheses and run its `Test-Gui.ps1`. Profile a noisy child before tuning the dispatcher, log
batching or console updates.

## Verification status

The original demo passed 47 checks on Windows 11 with Windows PowerShell 5.1 in an unelevated
interactive session. The current revision adds prompt-contract and process-start checks, and moves
scripted demo runs into the headless harness. Re-run `Test-Gui.ps1` on Windows for current results.
UAC, Windows 10, scaled screens and adoption by another tool still need field verification.
ScreenConnect keeps its own implementation.
