' Launches the CONTEXT widget (per-session context %, JSON-only) with NO console flash.
' Runs context-widget.ps1 (sibling) hidden. Zero install — wscript + powershell.
' This widget reads session transcripts across ALL projects, so it does not depend on the
' working directory. Run the 5h widget (cuw.bat) separately for the rate-limit pool.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\context-widget.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
