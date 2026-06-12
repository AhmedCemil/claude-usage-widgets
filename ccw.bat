@echo off
REM Claude Combined Widget launcher (5h + context). Starts hidden, no console flash.
REM Portable: %~dp0 = this file's folder. Reads transcripts across all projects, so it does
REM not matter which directory you launch from. Run ONE of cuw / ctw / ccw.
start "" "%~dp0ccw.vbs"
exit
