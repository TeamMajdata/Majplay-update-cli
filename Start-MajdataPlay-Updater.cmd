@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-MajdataPlay.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
exit /b %EXITCODE%
