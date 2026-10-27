@echo off
setlocal
cd /d "%~dp0.."
python tools\build_release.py
pause
endlocal
