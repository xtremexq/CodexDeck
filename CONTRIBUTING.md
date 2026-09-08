# Contributing

Use Windows PowerShell 5.1. Keep runtime data outside your checkout, and never copy a live `.codex-loop` directory into a pull request.

## Checks

Run repository checks, the regression suite and the WPF smoke test from the checkout root:

```powershell
./Test-Repository.ps1
Get-ChildItem ./suite/Test-*.ps1 | ForEach-Object {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ./suite/Codex-Deck.ps1 -SmokeTest
```

For changes to window lifetime, also run `powershell.exe -NoProfile -STA -File ./suite/Codex-Deck.ps1 -LifecycleTest`. Fixtures must be synthetic; do not add real account responses or screenshots.

`Test-Repository.ps1` is intentional project tooling, used by CI and `Build-Release.ps1`. Keep it, the regression tests, installer, release builder and contributor/security documentation in source control. Generated release archives, credentials, caches, backups and local editor settings do not belong in Git.

## UI previews

Regenerate the desktop screenshot from the committed code using synthetic state:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ./suite/Codex-Deck.ps1 -SmokeTest -PreviewMode Panel -PreviewExpanded -ScreenshotPath "$PWD/docs/panel.png"
```

`docs/terminal.png` is a synthetic rendering of `Get-DeckTerminalFrame` from `suite/Deck.Terminal.ps1`, with the frame's text and console colors. Keep its caption explicit about this being a rendered preview. Use example account identities and project paths only.

`-Demo` opens a synthetic widget; add `-PreviewMode Panel` for the panel. Install the app for normal use rather than treating the source checkout as a portable installation.

## Changes and releases

Preserve UTF-8 BOM in PowerShell scripts for Windows PowerShell 5.1. Batch files must have no BOM. Git attributes normalize line endings automatically.

Explain the behavior change and validation in your pull request. Changes to polling, credential handling, process lifetime or warm-up need regression coverage. UI changes should include a synthetic preview.

After committing, `./Build-Release.ps1 -Version <major.minor.patch>` creates a source ZIP and SHA-256 checksum in `dist/` using `git archive`. Only committed files enter the archive. Installable archives include the suite tests referenced by the installer.
