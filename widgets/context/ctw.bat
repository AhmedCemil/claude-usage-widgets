@echo off
REM Claude Context Widget launcher (per-session context %, JSON-only). Starts hidden.
REM Portable: %~dp0 = this file's folder. Reads transcripts across all projects, so it does
REM not matter which directory you launch from. Run cuw.bat separately for the 5h pool.
start "" "%~dp0ctw.vbs"
exit
