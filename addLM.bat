@echo off
title addLM - Model Selector
rem Locate addLM.ps1: in the "scripts" subfolder, or next to this file.
set "PS1=%~dp0scripts\addLM.ps1"
if not exist "%PS1%" set "PS1=%~dp0addLM.ps1"
if not exist "%PS1%" (
  echo ERROR: addLM.ps1 not found in the "scripts" subfolder or next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
pause
