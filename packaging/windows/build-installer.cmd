@echo off
REM Convenience wrapper so the installer can be built by double-click or from cmd.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-installer.ps1" %*
exit /b %ERRORLEVEL%
