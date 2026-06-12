' Launches the COMBINED widget (5h + context) with NO console flash.
' Runs combined-widget.ps1 (sibling) hidden. Zero install — wscript + powershell.
' Reads session transcripts across ALL projects, so it does not depend on the working
' directory. Run ONE of cuw.bat (5h) / ctw.bat (context) / ccw.bat (combined).
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\combined-widget.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
