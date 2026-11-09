Option Explicit
Dim shell, fs, folder, desktop, launcher, icon, builder, command, link, name, linkPath
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
desktop = shell.SpecialFolders("Desktop")
If WScript.Arguments.Named.Exists("destination") Then desktop = WScript.Arguments.Named.Item("destination")
launcher = fs.BuildPath(folder, "Start.vbs")
icon = fs.BuildPath(folder, "assets\white-dragon-avatar-color.ico")
builder = fs.BuildPath(folder, "Build-Icon.ps1")
If Not fs.FileExists(launcher) Then Fail "Start.vbs is missing. Extract or copy the whole project folder first."
If Not fs.FolderExists(desktop) Then Fail "The destination folder does not exist: " & desktop
If Not fs.FileExists(icon) Then
 If Not fs.FileExists(builder) Then Fail "The icon and Build-Icon.ps1 are missing. Copy the whole project folder first."
 command = Quote(shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")) & " -NoProfile -ExecutionPolicy Bypass -File " & Quote(builder)
 If shell.Run(command, 0, True) <> 0 Then Fail "Could not build the icon. Check assets\white-dragon-avatar.png."
 If Not fs.FileExists(icon) Then Fail "The icon was not created."
End If
' Keep the script ASCII-compatible with Windows Script Host on all system locales.
name = ChrW(30333) & ChrW(40857) & ChrW(23064) & " Codex " & ChrW(26700) & ChrW(23456)
linkPath = fs.BuildPath(desktop, name & ".lnk")
On Error Resume Next
Set link = shell.CreateShortcut(linkPath)
link.TargetPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
link.Arguments = Quote(launcher)
link.WorkingDirectory = folder
link.IconLocation = icon & ",0"
link.Description = name
link.Save
If Err.Number <> 0 Then
 command = Err.Description
 On Error GoTo 0
 Fail "Could not create the shortcut: " & command
End If
On Error GoTo 0
If Not WScript.Arguments.Named.Exists("quiet") Then MsgBox "Desktop shortcut created:" & vbCrLf & linkPath, vbInformation, name

Function Quote(value)
 Quote = Chr(34) & value & Chr(34)
End Function

Sub Fail(message)
 If WScript.Arguments.Named.Exists("quiet") Then
  WScript.Echo message
 Else
  MsgBox message, vbExclamation, "Codex Pet Shortcut"
 End If
 WScript.Quit 1
End Sub
