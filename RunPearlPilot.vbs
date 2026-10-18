Option Explicit

Dim fso, shell, appRoot, scriptPath, powershellPath, command, argument
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

appRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(appRoot, "PearlPilot.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

Function Quote(value)
    Quote = Chr(34) & CStr(value) & Chr(34)
End Function

command = Quote(powershellPath) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(scriptPath)
For Each argument In WScript.Arguments
    command = command & " " & Quote(argument)
Next

WScript.Quit shell.Run(command, 0, True)
