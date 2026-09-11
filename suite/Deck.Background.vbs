Option Explicit

If WScript.Arguments.Count < 1 Then WScript.Quit 64

Dim shell, powerShell, command, index
Set shell = CreateObject("WScript.Shell")
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

command = QuoteArgument(powerShell) & " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArgument(WScript.Arguments(0))
For index = 1 To WScript.Arguments.Count - 1
    command = command & " " & QuoteArgument(WScript.Arguments(index))
Next

WScript.Quit shell.Run(command, 0, True)
