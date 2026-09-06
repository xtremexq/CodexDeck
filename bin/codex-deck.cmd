@echo off
start "" /b powershell.exe -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex-loop\Codex-Deck.ps1" %*
