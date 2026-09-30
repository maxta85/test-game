@echo off
setlocal
title Cairns After Dark

rem  ---------------------------------------------------------------
rem  Cairns After Dark - entry point.
rem
rem  This used to download the Godot editor and run the game from
rem  source, which needed Godot, Git and Python on the player's
rem  machine. It now delegates to install.ps1, which installs a real
rem  exported build. See windows\README.md.
rem
rem  Actions (optional):
rem      (none)       install if needed, then play
rem      Install      install / repair only
rem      Update       offer a newer release
rem      Uninstall    remove the game, keep your saves
rem  e.g.  CairnsAfterDark.bat Uninstall
rem  ---------------------------------------------------------------

rem Find the PowerShell half: next to this file in the source checkout,
rem or in launcher\ inside the downloaded bundle.
set "PS1=%~dp0install.ps1"
if not exist "%PS1%" set "PS1=%~dp0launcher\install.ps1"

if not exist "%PS1%" (
  echo.
  echo ERROR: install.ps1 was not found.
  echo   looked in: %~dp0install.ps1
  echo              %~dp0launcher\install.ps1
  echo.
  echo The download looks incomplete. Re-download and extract it again.
  pause
  exit /b 1
)

rem  -Action must NOT be written unconditionally. With no arguments %* expands
rem  to nothing, so the command line ends in a bare "-Action" and PowerShell
rem  fails to bind it ("Missing an argument for parameter 'Action'") before the
rem  script ever runs - the default double-click installed nothing at all.
rem  With no action we pass nothing at all and let install.ps1's own default
rem  (Play) apply.
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action %*
)

if errorlevel 1 (
  echo.
  pause
)
endlocal
