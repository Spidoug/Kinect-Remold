Option Explicit
Dim shell, fso, appDir, cmdPath, command, i, value, exitCode, logPath
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmdPath = fso.BuildPath(appDir, "SynKinectStudio.cmd")
If Not fso.FileExists(cmdPath) Then
  WScript.Quit 2
End If

' Mark child process so the CMD does not bounce back into WScript.
shell.Environment("Process")("REMOLD_STUDIO_HIDDEN") = "1"
command = QuoteArg(cmdPath)
For i = 0 To WScript.Arguments.Count - 1
  value = WScript.Arguments(i)
  command = command & " " & QuoteArg(value)
Next
' WindowStyle 0 keeps the command processor hidden. Waiting here does not create
' a visible window; it lets us surface a GUI error only when Studio exits abnormally.
exitCode = shell.Run(command, 0, True)
If exitCode <> 0 Then
  logPath = fso.BuildPath(fso.BuildPath(appDir, "logs"), "SynKinectStudio.log")
  MsgBox "SynKinect Studio exited with code " & exitCode & "." & vbCrLf & vbCrLf & _
         "Diagnostic log: " & logPath, vbExclamation, "SynKinect Studio"
End If

Function QuoteArg(ByVal text)
  QuoteArg = Chr(34) & Replace(text, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
