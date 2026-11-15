@echo off
rem ============================================================================
rem  __LAUNCHER_NAME__ - opens the window for __TOOL_TITLE__ (script-gui kit).
rem  The window runs the tool's own scripts, one at a time (gui\steps.json).
rem
rem  SG_NEED_ADMIN=1 : ask for administrator rights ONCE (one UAC prompt), then
rem                    open the window elevated. Keep it equal to
rem                    Tool.RequireAdmin in gui\steps.json.
rem  This console stays open behind the window on purpose: if the window cannot
rem  load, the error is readable here. Never add -NonInteractive: it makes
rem  Read-Host throw in the child scripts.
rem  Pure ASCII, no BOM, CRLF.
rem ============================================================================
set "SG_NEED_ADMIN=__NEED_ADMIN__"

rem ---- Capture our own path/args BEFORE enabling delayed expansion --------
rem A folder name such as "tool (1)" breaks cmd when %~dp0 / %~f0 are expanded
rem inside a ( ... ) block: they expand at PARSE time and the ( ) end the block
rem early. Delayed expansion (!VAR!) is substituted at RUN time, so it is safe.
set "SG_DP0=%~dp0"
set "SG_F0=%~f0"
set "SG_ARGS=%*"
setlocal EnableDelayedExpansion
title __TOOL_TITLE__

set "SG_ELEV_ATTEMPTED=0"
for %%A in (!SG_ARGS!) do (
    if /i "%%~A"=="--elevation-attempted" set "SG_ELEV_ATTEMPTED=1"
)

if not "!SG_NEED_ADMIN!"=="1" goto :open_window

rem ---- Self-elevate: at most ONE UAC prompt, decided by the real admin token ---
rem The path travels via SG_SELF so quotes in it cannot break the command line,
rem and --elevation-attempted stops a second prompt (never loop UAC).
set "SG_SELF=!SG_F0!"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
    if "!SG_ELEV_ATTEMPTED!"=="1" (
        echo.
        echo  [ERROR] This window is still not elevated after the UAC request, so
        echo          it will not ask again. Right-click this file and choose
        echo          "Run as administrator".
        pause
        exit /b 1
    )
    echo  Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SG_SELF -ArgumentList '--elevation-attempted' -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo  [ERROR] Elevation could not be launched or was cancelled.
        pause
        exit /b 1
    )
    exit /b
)
set "SG_SELF="

:open_window
cd /d "!SG_DP0!"
if not exist "!SG_DP0!gui\Start-Gui.ps1" (
    echo [ERROR] gui\Start-Gui.ps1 is missing next to this file.
    pause
    exit /b 1
)
echo.
echo  __TOOL_TITLE__ - opening the window. Leave this console open.
echo.
rem -STA is required for WPF.
powershell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "!SG_DP0!gui\Start-Gui.ps1"
set "SG_GUI_RC=!errorlevel!"
if not "!SG_GUI_RC!"=="0" (
    echo.
    echo  [ERROR] The window ended with an error ^(exit !SG_GUI_RC!^). Read the message above.
    pause
)
exit /b !SG_GUI_RC!
