@echo off
rem CarPlay HUD Wizard - double-click this file to start.
rem It opens a window that guides you step by step. Nothing in the car changes until you confirm a step.
setlocal
cd /d "%~dp0"
if not exist "%~dp0app\CarPlayHudWizard.ps1" (
  echo The app folder is missing. Extract the WHOLE download first, then start Start-Wizard.cmd again.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\CarPlayHudWizard.ps1"
