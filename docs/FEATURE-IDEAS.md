# Codex Deck: 50 possible next features

Ideas for review, not promised work. The current local changes already include encrypted export/import, About, pinning, concurrent checks and compact picker details; those are not counted again below.

## Best next candidates

1. **Account rename** — change a profile name safely, updating pins, warm-up selection and saved state.
2. **Recovery browser** — inspect deleted profiles and restore them from a themed screen.
3. **Account search** — instantly narrow panel and widget entries by name, email or plan.
4. **Groups and labels** — separate personal, work and project profiles without renaming folders.
5. **Quota alerts** — configurable notices before a five-hour, weekly or monthly limit is exhausted.
6. **Reset notifications** — notify when fresh data confirms quota has reset.
7. **Scheduled encrypted backups** — opt-in backups with retention and a secure key-unlock workflow.
8. **Selective restore** — choose individual accounts, rename collisions and preview preference changes.
9. **Config validation and diff** — catch TOML errors and show the exact changes before saving.
10. **Terminal preferences** — select Windows Terminal profiles and per-account launch folders.
11. **Keyboard command palette** — launch, check, pin and switch views without the mouse.
12. **Redacted diagnostics export** — collect app/version/error information with a preview and secret removal.
13. **Optional update checker** — show release notes and verify downloads before installing.
14. **Multi-monitor placement** — per-monitor view positions, DPI-aware bounds and recovery after unplugging a screen.
15. **Connection diagnostics** — distinguish an expired sign-in, offline network, rate limit and provider failure.

## More possibilities

16. Custom account display names separate from folder identity.
17. Per-account accent colors and small avatars.
18. Drag ordering within pinned and unpinned groups.
19. Smart sorting by remaining quota or nearest reset.
20. Saved filters such as paid, low quota, unchecked or disconnected.
21. Multi-select actions with a clear scope preview.
22. Recently launched accounts and folders.
23. Favorite project folders shared across profiles.
24. Per-account launch presets for model and reasoning effort.
25. Config templates for new accounts.
26. Shared-instruction editor with per-account override visibility.
27. Settings search across tabs.
28. Settings reset with a reversible snapshot.
29. Undo for pinning, sorting and other reversible UI actions.
30. A searchable local activity timeline for checks, launches and config changes.
31. Optional quota history graphs with a configurable retention period.
32. Freshness badges that show age without replacing quota health.
33. Manual retry controls with provider-aware retry timing.
34. Adaptive polling that slows when accounts are idle.
35. Configurable concurrency for slow machines or constrained networks.
36. Quiet hours for notifications and scheduled warm-up.
37. Per-account warm-up enablement, model and schedule overrides.
38. A warm-up event preview explaining why an account will run or be skipped.
39. Metered-network behavior and offline mode.
40. Windows sign-in startup as a separate option from terminal autostart.
41. Global shortcut to summon or hide Deck.
42. Screen-edge docking with optional auto-hide.
43. High-contrast and color-vision-friendly palettes.
44. Full keyboard focus and screen-reader audit.
45. Reduced-motion and text-scaling controls.
46. Screenshot privacy mode that masks names, folders and emails together.
47. App lock for viewing account details and exporting credentials.
48. Signed installer and an uninstall flow that preserves account data by default.
49. A cross-platform desktop port for Linux and macOS.
50. Localization with locale-aware dates and an explicit time-zone preference.

## Suggested order

Start with rename, recovery, search and connection diagnostics. Follow with selective restore and config validation. Add alerts and backup scheduling only with clear opt-in controls. A cross-platform port and signed distribution deserve separate projects rather than small UI patches.
