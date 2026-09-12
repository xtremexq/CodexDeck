@echo off
start "" powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex-loop\Codex-Deck.ps1" %*
