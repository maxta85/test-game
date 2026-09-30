@echo off
setlocal enabledelayedexpansion
title Cairns After Dark

rem  ---------------------------------------------------------------
rem  Cairns After Dark - Windows launcher.
rem
rem  Idempotent. Double-click this every time; it is safe to run twice.
rem  It installs Godot if missing, pulls updates if a remote is set,
rem  then starts the game. There is no separate install step.
rem  ---------------------------------------------------------------

set "GODOT_VERSION=4.3-stable"
set "GODOT_URL=https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_win64.exe.zip"
set "GODOT_EXE_NAME=Godot_v4.3-stable_win64.exe"

set "HERE=%~dp0"
set "ROOT=%HERE%.."
set "TOOLS=%ROOT%\tools\godot-%GODOT_VERSION%"

rem  --- 1. Godot -------------------------------------------------
if exist "%TOOLS%\%GODOT_EXE_NAME%" goto have_godot

echo [1/3] Downloading Godot %GODOT_VERSION% (57 MB, one time)...
if not exist "%ROOT%\tools" mkdir "%ROOT%\tools"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue';" ^
  "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
  "Invoke-WebRequest -Uri '%GODOT_URL%' -OutFile '%ROOT%\tools\godot.zip';" ^
  "Expand-Archive -Force '%ROOT%\tools\godot.zip' '%TOOLS%';"

if not exist "%TOOLS%\%GODOT_EXE_NAME%" (
  echo.
  echo ERROR: could not download or unpack Godot.
  echo This needs internet access on first run. github.com must be reachable.
  pause
  exit /b 1
)
del "%ROOT%\tools\godot.zip" >nul 2>&1

:have_godot
set "GODOT=%TOOLS%\%GODOT_EXE_NAME%"

rem  --- 2. Updates -----------------------------------------------
rem  Needs a git remote. Until one is configured this prints a note
rem  and carries on, so the game still runs offline.
if exist "%ROOT%\.git" (
  git -C "%ROOT%" pull --ff-only >nul 2>&1
  if errorlevel 1 (
    echo [2/3] No updates pulled ^(no remote configured, or offline^).
  ) else (
    echo [2/3] Updated to latest.
  )
) else (
  echo [2/3] Not a git checkout - skipping update.
)

rem  --- 3. Import, then play -------------------------------------
rem  --import is a no-op when nothing changed, but picks up new or
rem  renamed scripts after an update. Skipping it is how a pulled
rem  update ends up "not working" for no visible reason.
echo [3/3] Importing assets - slow the first time, quick after...
"%GODOT%" --path "%ROOT%" --import

echo.
echo Starting Cairns After Dark...
"%GODOT%" --path "%ROOT%"

if errorlevel 1 (
  echo.
  echo The game exited with an error. The message above is the reason.
  pause
)
endlocal
