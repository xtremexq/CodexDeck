# Skills and catalog

Codex Deck ships the `debug-swarm` workflow and three [UIZZE](https://github.com/uizze/uizze) skills. It also ships a pinned, searchable snapshot of the [Agentic Awesome Skills](https://github.com/sickn33/agentic-awesome-skills) (AAS) index. Searching the index does not install its 2,451 skills into Codex or send a query to a service. **Refresh catalog** is an explicit network action that replaces Deck's cached index with one pinned to the current upstream commit.

## Use the GUI

Open **Codex Deck → Settings → Skills**. The top section shows installed Deck skills and lets you enable or disable each for the selected account or pool. The AAS section below it has text, category and risk filters. Select a result to read its description and setup notes, inspect the exact pinned source, then press **Install selected**. A selected install is linked into all existing accounts and pools and future ones by default. The same button offers an update for an already installed AAS skill. Start a new Codex session after a change.

Deck stores one managed copy under `.codex-loop/skills` and uses verified junctions in each `CODEX_HOME/skills` directory. It leaves an existing user-owned skill of the same name alone and reports the collision. Account and pool switches remain independent; skill content is shared, not authentication or conversation history. AAS skills may include commands, scripts, network setup or licensed third-party material. Inspect the source and risk label before enabling one for a session.
The risk labels and setup notes come from AAS metadata; they are aids for review, not a security guarantee from Deck.

## Use the CLI

`deck-skills` and `codex-auth skills` accept the same commands:

```powershell
deck-skills search "frontend testing"
deck-skills search "frontend" -Category testing -Risk safe
deck-skills show <exact-aas-id>
deck-skills preview <exact-aas-id>
deck-skills install <exact-aas-id>
deck-skills installed
deck-skills disable <installed-name> account2
deck-skills enable <installed-name> account2
deck-skills refresh
deck-skills update <installed-name>
```

`preview` fetches the selected pinned `SKILL.md` for reading. `install` fetches only the selected skill subtree from the catalog's pinned commit, preserving its support files and notices. `update` fetches a newer pinned version, verifies the installed files have not been locally edited, and keeps the previous copy in `.codex-loop/deck/skill-backups`. Refresh the AAS index before updating an AAS skill. UIZZE updates resolve its current upstream commit directly. Deck owns the adapter and metadata; the upstream skill files remain separate from Deck code.

## UIZZE

The included skills are:

- `ui-design` for designing and building web or mobile interfaces;
- `anti-ui-slop` for reviewing and finishing an interface;
- `ui-radar` for focused UI research.

Ask Codex to use one explicitly, for example: `Use $ui-design to improve our billing page. Reuse our components and cover loading, empty and error states.` All three free skill packages work without a UIZZE account. Their complete `SKILL.md`, references, playbooks, license and notice files are included. The main UIZZE reference search is a separate paid MCP service; its two tools find UI references and design materials. To opt in, create an agent token in UIZZE, set `UIZZE_AGENT_TOKEN` in the environment that launches Deck, restart Deck, and enable **Settings → Integrations → Enable UIZZE reference search**. The token stays in the environment and is never written to Deck settings. The free skills remain usable with this switch off.

UIZZE also offers a free GitHub Action for pull-request UI checks. That is a repository CI choice, separate from Codex skills or Deck's runtime, so Deck does not add workflows to your projects automatically. See UIZZE's [action guide](https://github.com/uizze/uizze/tree/main/integrations/github-action) if you want it in a project.

UIZZE's packages contain [MIT and Apache-2.0 material with notices](https://github.com/uizze/uizze/blob/main/LICENSING.md). AAS tooling is MIT, its original documentation is CC BY 4.0, and individual skills may have their own upstream licenses and prerequisites. Deck keeps the files supplied with each selected skill.
