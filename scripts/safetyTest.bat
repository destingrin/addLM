@echo off
title addLM - Safety Evaluation
rem Evaluates a model's refusal behaviour against the standard
rem mlabonne/harmful_behaviors benchmark. Uses its own scratch port (8099)
rem so it does not disturb a running addLM server on 8081.
set "PS1=%~dp0safetyTest.ps1"
if not exist "%PS1%" (
  echo ERROR: safetyTest.ps1 not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
pause
