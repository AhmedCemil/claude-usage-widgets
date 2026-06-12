@echo off
REM Claude Usage Widget launcher (no Python). Starts the widget hidden, no console flash.
REM Portable: %~dp0 = this file's folder, so it works wherever the set is unzipped.
REM To launch with a short command from anywhere, add this folder to PATH, or copy
REM cuw.bat into a folder already on PATH (then edit the path below to point back here).
start "" "%~dp0cuw.vbs"
exit
