# gui-architecture

Design and tooling for putting a Windows window (GUI) on top of existing PowerShell technician tools
without a second engine.

- `docs/14-gui-architecture.md` - the design, written from the ScreenConnect Cleanup GUI build (its spike
  results are in section 12).
- `skills/script-gui/` - a Claude Code skill: a scaffolder (`scripts/new_script_gui.py`), a tested
  PowerShell 5.1 + WPF template (`template/`), and the method (`SKILL.md`, `references/`).

## Quick start

From the root of the tool you want to wrap:

    py <path>\skills\script-gui\scripts\new_script_gui.py --target . --title "My Tool" [--admin]

Then edit `gui\steps.json`, run `tests\gui\Test-Gui.ps1`, and read `skills\script-gui\references\gotchas.md`
before changing the kit.

Windows-only (PowerShell 5.1 + WPF). The scaffolder is stdlib Python.
