Option Explicit
' OPPO Connect Launcher (windowless)
' Double-click this file. It requests UAC once, then runs Start-OppoConnect.ps1
' in a hidden window. No console/terminal window is shown.

Dim fso, shell, scriptDir, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\Start-OppoConnect.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "Start-OppoConnect.ps1 not found:" & vbCrLf & ps1, 16, "OPPO Connect Launcher"
    WScript.Quit 2
End If

' Not elevated: re-launch this same script with "runas" (one UAC prompt), window hidden
If Not IsAdmin() Then
    Dim app
    On Error Resume Next
    Set app = CreateObject("Shell.Application")
    app.ShellExecute "wscript.exe", """" & WScript.ScriptFullName & """", scriptDir, "runas", 0
    If Err.Number <> 0 Then
        MsgBox "已取消管理员权限请求，启动中止。", 48, "OPPO 互联启动器"
    End If
    On Error GoTo 0
    WScript.Quit 0
End If

' Elevated: run the PowerShell launcher completely hidden (0 = hidden, False = do not wait)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
WScript.Quit 0

Function IsAdmin()
    Dim rc
    On Error Resume Next
    Err.Clear
    rc = shell.Run("cmd.exe /c fltmc >nul 2>&1", 0, True)
    If Err.Number <> 0 Then
        IsAdmin = False
    Else
        IsAdmin = (rc = 0)
    End If
    On Error GoTo 0
End Function
