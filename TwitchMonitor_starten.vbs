' Startet den Twitch Monitor ohne sichtbares Fenster (Doppelklick genuegt).
' Der Pfad wird aus dem Speicherort dieser Datei gebildet - keine Anpassung noetig.
Option Explicit
Dim sh, fso, dir, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir
cmd = "conhost.exe --headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "\twitch_monitor.ps1"""
sh.Run cmd, 0, False
