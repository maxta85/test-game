@echo off
setlocal
title Cairns After Dark

rem  ---------------------------------------------------------------
rem  Cairns After Dark - graphical launcher.
rem
rem  A separate file on purpose. CairnsAfterDark.bat is the runbook's
rem  entry point and must stay exactly as it is; adding a switch to it
rem  would put the no-argument double-click back one edit away from the
rem  bug this launcher already shipped once. See windows\README.md.
rem
rem  This is a window, not an engine. Every action it offers is
rem  install.ps1 -Action <name>, run in a child process, and install.ps1
rem  is not modified in any way. The GUI adds the download progress bar
rem  and a state panel; it does not install, hash or delete anything.
rem
rem  CAD_GUI_HEADLESS=1 runs the launcher's wiring and exits without
rem  opening a window. That is how Tools\verify_launcher.py tests the
rem  wiring on a machine with no Windows.
rem  ---------------------------------------------------------------

rem Find the GUI half: next to this file in the source checkout, or in
rem launcher\ inside the downloaded bundle.
set "GUI=%~dp0launcher-gui.ps1"
if not exist "%GUI%" set "GUI=%~dp0launcher\launcher-gui.ps1"

if not exist "%GUI%" (
  echo.
  echo ERROR: launcher-gui.ps1 was not found.
  echo   looked in: %~dp0launcher-gui.ps1
  echo              %~dp0launcher\launcher-gui.ps1
  echo.
  echo The download looks incomplete. Re-download and extract it again,
  echo or use CairnsAfterDark.bat, which does not need this file.
  pause
  exit /b 1
)

rem powershell.exe is Windows PowerShell 5.1; PowerShell 7 renamed it pwsh.exe.
rem A machine with only PowerShell 7 has no 'powershell', and install.ps1
rem already had to learn that difference for its own re-launch.
set "PSEXE=powershell"
where powershell >nul 2>&1
if errorlevel 1 set "PSEXE=pwsh"

rem -STA is not optional. WinForms needs a single-threaded apartment and
rem PowerShell 7 defaults to MTA, where the window can fail to appear at all.
rem /min starts the console minimised: the form is its own window and comes
rem up normally, and the console stays one click away if anything is wrong.
start "" /min "%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%GUI%"

endlocal
