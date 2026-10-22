@echo off
title addLM - Verify Config
rem Checks that OpenCode's limit.context matches the context the running
rem llama-server actually loaded.
rem
rem Exit codes:  0 = OK   1 = mismatch   2 = no server running   3 = bad config

set "PS1=%~dp0verify-config.ps1"
if not exist "%PS1%" set "PS1=%~dp0scripts\verify-config.ps1"
if not exist "%PS1%" (
  echo ERROR: verify-config.ps1 not found in the "scripts" subfolder or next to this file.
  pause
  exit /b 3
)

set "PORT=8081"
if not "%~1"=="" set "PORT=%~1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Port %PORT%
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo RESULT: OK - the OpenCode config matches the running server.
) else if "%RC%"=="1" (
  echo RESULT: MISMATCH - the OpenCode config does NOT match the running server.
  echo         Re-run addLM.bat to regenerate it.
) else if "%RC%"=="2" (
  echo RESULT: no llama-server is answering on port %PORT%.
  echo         Start it with addLM.bat first.
) else (
  echo RESULT: the OpenCode config could not be read.
)

pause
exit /b %RC%
