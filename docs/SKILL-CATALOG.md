# Skills and catalog

Codex Deck ships the `debug-swarm` workflow and three [UIZZE](https://github.com/uizze/uizze) skills. The [Agentic Awesome Skills](https://github.com/sickn33/agentic-awesome-skills) (AAS) index is an optional integration. Install it through **Settings → Integrations**, then search it locally under **Settings → Skills**. The index contains metadata only: installing it does not install AAS skills or send search queries to a service. **Check & update** refreshes it from the current upstream commit when requested. Existing Deck installations keep their previously bundled index during upgrade.

## Use the GUI

Open **Codex Deck → Settings → Skills**. The account list combines access and editing: check which accounts or pools receive managed skills, then select a row to customize its individual skill switches. Access presets cover all current and future entries, free accounts, paid accounts, or a custom set without showing a second account picker.

The same tab installs skills in two ways. **Add skills from a plugin** accepts a marketplace source and then `plugin@marketplace`; Deck installs the plugin into a private runtime store and adds its skill trees to the managed list. **Agentic Awesome Skills** searches the optional AAS index and can install the index directly when it is missing. Select a result to read its description, risk and setup notes, inspect its pinned source, then install it. New skills appear in the managed list above and follow the selected account access. Start a new Codex session after a change.

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

Plugin marketplaces use Codex's native marketplace format:

```powershell
codex-auth plugin marketplace add owner/repository
codex-auth plugin add plugin-name@marketplace-name
codex-auth plugin list
```

Deck keeps plugin downloads and receipts under the local `.codex-loop` runtime. Plugin skills are user-installed runtime data; they are not added to Codex Deck releases. A plugin update refuses to replace a managed skill that has local edits.

`preview` fetches the selected pinned `SKILL.md` for reading. `install` fetches only the selected skill subtree from the catalog's pinned commit, preserving its support files and notices. `update` fetches a newer pinned version, verifies the installed files have not been locally edited, and keeps the previous copy in `.codex-loop/deck/skill-backups`. Refresh the AAS index before updating an AAS skill. UIZZE updates resolve its current upstream commit directly. Deck owns the adapter and metadata; the upstream skill files remain separate from Deck code.

## UIZZE

The included skills are:

- `ui-design` for designing and building web or mobile interfaces;
- `anti-ui-slop` for reviewing and finishing an interface;
- `ui-radar` for focused UI research.

Ask Codex to use one explicitly, for example: `Use $ui-design to improve our billing page. Reuse our components and cover loading, empty and error states.` All three free skill packages work without a UIZZE account. Their complete `SKILL.md`, references, playbooks, license and notice files are included. Codex Deck does not configure UIZZE's paid MCP service.

UIZZE also offers a free GitHub Action for pull-request UI checks. That is a repository CI choice, separate from Codex skills or Deck's runtime, so Deck does not add workflows to your projects automatically. See UIZZE's [action guide](https://github.com/uizze/uizze/tree/main/integrations/github-action) if you want it in a project.

UIZZE's packages contain [MIT and Apache-2.0 material with notices](https://github.com/uizze/uizze/blob/main/LICENSING.md). AAS tooling is MIT, its original documentation is CC BY 4.0, and individual skills may have their own upstream licenses and prerequisites. Deck keeps the files supplied with each selected skill.
