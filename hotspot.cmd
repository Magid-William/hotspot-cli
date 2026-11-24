@echo off
rem Thin shim so `hotspot` works from cmd, PowerShell, Windows Terminal and Win+R.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotspot.ps1" %*
exit /b %ERRORLEVEL%
