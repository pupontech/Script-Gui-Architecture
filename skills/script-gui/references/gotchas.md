# Gotchas - each of these was a real bug once

Read before changing `Gui.Core.psm1`, `Start-Gui.ps1` or a script's prompts. Source: the ScreenConnect
Cleanup GUI build (`screenconnect-cleanup/docs/14-gui-architecture.md`, section 12) and this kit's own
tests.

## Talking to a child script

1. **Read characters, not lines.** A prompt printed with `-NoNewline` never ends its line, so a line
   reader never returns it and the window waits forever on a question it cannot see. The kit keeps one
   pending `ReadAsync(char[])` task per stream and looks at the unfinished tail.
2. **`Read-Host 'text'` prints nothing when stdin is redirected** (Windows PowerShell 5.1). The script
   must print the question itself: `Write-Host 'text' -NoNewline; $x = Read-Host`. Four of seven prompts
   in the ScreenConnect tool were invisible until this was fixed.
3. **UTF-8 console (code page 65001) corrupts the answer.** A redirected 5.1 child that inherits a 65001
   console gets U+FEFF in front of what `Read-Host` returns, so `y` never equals `y` and a y/N loop spins
   forever. Windows 11's "Use Unicode UTF-8 for worldwide language support" makes this a real field case.
   The kit switches the shared console to 437 for its lifetime (`Set-GuiConsoleEncoding`) and writes
   answers as raw bytes (`Send-GuiAnswer`). Do not replace that with `StandardInput.WriteLine`.
4. **Never pass `-NonInteractive`** to a child that may ask something: `Read-Host` throws.
5. **`powershell -File` does not split arrays.** `-Names a,b` arrives as ONE string `a,b`. Pass one
   comma-joined value and split inside the script, defensively.
6. **Quote arguments yourself, never through `cmd.exe`.** Paths have spaces and parentheses; a trailing
   backslash before a closing quote must be doubled. `ConvertTo-GuiArg` does it; the test checks it.
7. **A program the script starts can keep the output pipe open** after the script exits. Waiting for
   end-of-file then hangs the window. The kit waits 1.5 s after exit, then moves on.
8. **A quiet script is not a question.** The generic "waiting for an answer" box fires only on an
   UNFINISHED line that has been quiet for 5 s. A long scan that ends its lines must not trigger it.

## PowerShell 5.1 inside a WPF window

9. **No runspaces, no `Register-ObjectEvent`, no script blocks on other threads.** A PowerShell handler
   that fires on a thread-pool thread has no runspace. Everything runs on the UI thread from ONE
   `DispatcherTimer` that polls. Importing the tool's modules into the window's process is the same class
   of mistake (it produced `CommandAlreadyExists` in an earlier attempt).
10. **A hashtable's keys are not in `.PSObject.Properties`.** Reading a button spec that way once left the
    approve button enabled without the typed word. Use `Get-GuiProp`, which handles both hashtables and
    JSON objects. The window's `-SelfTest` guards this.
11. **Variable names are case-insensitive.** A local `$checks` overwrites a `-Checks` parameter; `$W` and
    `$w` are the same variable.
12. **One-item arrays unwrap.** `.Count` on a single result throws under strict mode or returns nothing.
    Use `@($x).Count`; for JSON use `ConvertTo-GuiItems`.
13. **An unbound `[string[]]` parameter is `$null`** and `@($null).Count` threw under strict mode in this
    kit's first test run. Test `$null -ne $x -and $x.Length -gt 0`.
14. **`return , @(...)` wraps a whole list as ONE item** at the caller. Emit items and collect with `@()`.
15. **Pure ASCII, no BOM, in every `.ps1`, `.psm1`, `.xaml`, `.json` and `.bat`.** 5.1 reads a BOM-less
    non-ASCII file as Windows-1252. No smart quotes, no dashes other than `-`, no box characters.
16. **`.bat` files need CRLF.** The scaffolder writes them that way; an editor may not.

## The window

17. **`-STA` is required** for WPF. The launcher passes it; the script restarts itself once if it is missing.
18. **DPI.** `powershell.exe` starts DPI-unaware and WPF makes it only system-aware: blurry on a second
    monitor with another scale. The kit asks for per-monitor v2 BEFORE loading WPF. Moving that call
    after `Add-Type -AssemblyName PresentationFramework` silently loses it.
19. **Small screens.** A 1366x768 laptop at 150% has about 910x480 usable units. The window sizes itself
    to the work area and switches to a compact layout; do not add fixed sizes larger than that.
20. **A dialog is its own window** and does not see the main window's resources. `New-DialogWindow`
    copies them. A dialog built any other way has no theme and throws on `DynamicResource` lookups.
21. **Colours only through tokens** (`Brush.*` in `MainWindow.xaml`, `Get-Brush` in code). Light and dark
    must define the same keys; `-SelfTest` checks it.
22. **Open web links through `explorer.exe`**, not `Start-Process <url>`, when the window is elevated:
    otherwise the browser inherits administrator rights.
23. **The console window behind the GUI stays.** If the window cannot load, the error is readable there.
24. **Exceptions in a timer tick** must be caught and logged (`gui-error.log`), never allowed to end the
    window while a step is running.

## The launcher (.bat)

25. **Capture `%~dp0` / `%~f0` before `setlocal EnableDelayedExpansion`, and use `!VAR!` afterwards.**
    A folder such as `tool (1)` (Explorer makes these on a second unzip) ends a `( ... )` block early when
    `%~dp0` is expanded inside it, and the batch dies with no message.
26. **One UAC request, never a loop.** The relaunch passes `--elevation-attempted`; if the window is
    still not elevated, stop with a message.
27. **No caret-escaped pipe inside double quotes** in a `powershell -Command "..."` line: cmd passes the
    caret through literally.

## Design mistakes to refuse

28. **Do not add `-Yes` / `-Force` / `-NoPrompt` switches to the tool so the window can skip a question.**
    Answer the question over stdin instead; the gate stays in the script, where it is tested.
29. **Do not let the window decide what is safe.** It shows what the tool found; it does not rank, colour
    or label findings as good or bad unless the tool itself says so.
30. **Do not offer "run this step again"** unless the script really can be run twice into the same run
    folder. Many refuse (they will not overwrite their own results). `Retry` is opt-in per call.
31. **Do not resume an old run.** Earlier run folders may be listed for viewing; nothing in them may
    authorize a step.
