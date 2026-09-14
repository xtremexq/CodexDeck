@echo off
start "" "%SystemRoot%\System32\wscript.exe" //B //Nologo "%USERPROFILE%\.codex-loop\Deck.Background.vbs" "%USERPROFILE%\.codex-loop\Codex-Deck.ps1" %*
