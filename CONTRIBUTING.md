# Contributing

Use Windows PowerShell 5.1. Keep runtime data outside your checkout, and never copy a live `.codex-loop` directory into a pull request.

Run the four `suite/Test-*.ps1` scripts and `powershell.exe -NoProfile -STA -File suite/Codex-Deck.ps1 -SmokeTest`. See the README for lifecycle testing. Use synthetic fixtures only; do not add real account responses or screenshots.

Preserve UTF-8 BOM in PowerShell scripts for Windows PowerShell 5.1. Batch files must have no BOM. Git attributes normalize line endings automatically.

Explain the behavior change and validation in your pull request. Changes to polling, credential handling, process lifetime, or warmup need regression coverage. UI changes should include a synthetic preview.
