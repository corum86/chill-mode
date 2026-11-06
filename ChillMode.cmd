@echo off
rem Chill Mode launcher - double-click to open the battery optimizer panel.
rem Pass /max to apply the "Optimize for battery" preset without opening the window.
if /i "%~1"=="/max" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ChillMode.ps1" -Preset MaxBattery
  goto :eof
)
if /i "%~1"=="/restore" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ChillMode.ps1" -Restore
  goto :eof
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ChillMode.ps1"
