#!/usr/bin/env python3
"""Scaffold a script-gui window into a tool folder.

Copies the kit's template (launcher, gui/, tests/gui/) into the target folder and fills in the
tool's name. Stdlib only; runs the same on Windows (py) and WSL2/Linux (python3). The window it
creates is Windows-only by nature (PowerShell 5.1 + WPF).

  py .claude/skills/script-gui/scripts/new_script_gui.py --target <tool folder> --title "My Tool"
     [--id my-tool] [--admin] [--launcher Run-MyToolGui.bat] [--force] [--dry-run]

Existing files are never overwritten unless --force is given. Text files are written as pure
ASCII. Batch files get CRLF line endings. The catalog is serialized as JSON, and placeholders
in other text files are substituted.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(os.path.dirname(HERE), "template")
TEXT_EXT = {".ps1", ".psm1", ".xaml", ".json", ".bat"}


def main() -> int:
    ap = argparse.ArgumentParser(description="Scaffold a script-gui window into a tool folder.")
    ap.add_argument("--target", required=True, help="the tool's folder (created if missing)")
    ap.add_argument("--title", required=True, help='window title, e.g. "Student Cleanup"')
    ap.add_argument("--id", default="", help="short kebab-case id (default: from the title)")
    ap.add_argument("--admin", action="store_true", help="the tool needs administrator rights (one UAC prompt)")
    ap.add_argument("--launcher", default="", help="launcher file name (default: Run-<Title>Gui.bat)")
    ap.add_argument("--force", action="store_true", help="overwrite existing files")
    ap.add_argument("--dry-run", action="store_true", help="only list what would be written")
    args = ap.parse_args()

    title = args.title.strip()
    if not title or any(not 32 <= ord(c) <= 126 for c in title):
        print("ERROR: --title must be printable ASCII text (PowerShell 5.1 house rule).", file=sys.stderr)
        return 2
    if any(c in title for c in '"%!^&|<>'):
        print('ERROR: --title must not contain " % ! ^ & | < > (it is written into a .bat file).', file=sys.stderr)
        return 2
    tool_id = args.id or re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", tool_id):
        print("ERROR: --id must be kebab-case (a-z, 0-9, -).", file=sys.stderr)
        return 2
    launcher = args.launcher or ("Run-" + re.sub(r"[^A-Za-z0-9]+", "", title.title()) + "Gui.bat")
    if not re.fullmatch(r"Run-[A-Za-z0-9]+Gui\.bat", launcher):
        print("ERROR: --launcher must look like Run-<Name>Gui.bat (the tests find it by that pattern).", file=sys.stderr)
        return 2

    repl = {
        "__TOOL_TITLE__": title,
        "__TOOL_ID__": tool_id,
        "__NEED_ADMIN__": "1" if args.admin else "0",
        "__LAUNCHER_NAME__": launcher,
    }
    tokens = re.compile("|".join(re.escape(key) for key in repl))
    target = os.path.abspath(args.target)
    planned = []
    for root, _dirs, files in os.walk(TEMPLATE):
        for name in sorted(files):
            src = os.path.join(root, name)
            rel = os.path.relpath(src, TEMPLATE)
            if rel == "Run-Gui.bat":
                rel = launcher
            planned.append((src, os.path.join(target, rel), rel))

    clashes = [rel for _s, dst, rel in planned if os.path.exists(dst)]
    if clashes and not args.force:
        print("ERROR: these files already exist (use --force to overwrite):", file=sys.stderr)
        for rel in clashes:
            print("  " + rel, file=sys.stderr)
        return 1

    rendered = []
    try:
        for src, dst, rel in planned:
            with open(src, "rb") as f:
                data = f.read()
            if rel == os.path.join("gui", "steps.json"):
                catalog = json.loads(data.decode("ascii"))
                tool = catalog["Tool"]
                tool["Title"] = title
                tool["RequireAdmin"] = args.admin
                tool["RunRootBase"] = tool["RunRootBase"].replace("__TOOL_ID__", tool_id)
                data = (json.dumps(catalog, indent=2) + "\n").encode("ascii")
            elif os.path.splitext(src)[1].lower() in TEXT_EXT:
                text = tokens.sub(lambda match: repl[match.group()], data.decode("ascii"))
                if rel == launcher:
                    text = text.replace("\r\n", "\n").replace("\n", "\r\n")
                data = text.encode("ascii")
            rendered.append((dst, rel, data))
        if not rendered:
            raise ValueError(f"no template files found in {TEMPLATE}")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: could not render the template: {exc}", file=sys.stderr)
        return 1

    for dst, rel, data in rendered:
        if args.dry_run:
            print("would write " + rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb" if args.force else "xb") as f:
            f.write(data)
        print("wrote " + rel)

    if not args.dry_run:
        print()
        print("Next:")
        print("  1. Run the demo:   " + launcher + "   (it drives gui\\demo\\Demo-Tool.ps1)")
        print("  2. Run the tests:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\\gui\\Test-Gui.ps1")
        print("  3. Point gui\\steps.json at the tool's real scripts, then delete gui\\demo.")
        print("     Method: " + os.path.join(os.path.dirname(HERE), "SKILL.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
