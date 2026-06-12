' Launches the usage widget with NO console window flash.
' Runs usage-widget.ps1 (sibling file) hidden. Zero install — uses wscript + powershell,
' both built into Windows. No hardcoded paths: resolves the script next to this file.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\usage-widget.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
