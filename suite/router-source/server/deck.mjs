import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { HttpError, requireThat } from './errors.mjs';

const harnesses = { Codex: ['ChatGPT'], Claude: ['Claude'], Antigravity: ['Gemini'], OpenCode: ['ChatGPT','Claude','Gemini','Custom'] };
export function deckAccounts(settings) {
  const root = path.join(settings.deckRoot,'accounts');
  const result = { available: fs.existsSync(root), scriptAvailable: fs.existsSync(settings.deckScript), harnessModuleAvailable: fs.existsSync(path.join(settings.deckRoot,'Deck.Harnesses.ps1')), accounts: [], harnesses };
  if (!result.available) return result;
  requireThat(!fs.lstatSync(root).isSymbolicLink(), 'Deck accounts root cannot be a symbolic link.');
  for (const item of fs.readdirSync(root,{ withFileTypes: true })) {
    if (!item.isDirectory() || !/^[a-zA-Z][a-zA-Z0-9_-]{0,39}$/.test(item.name)) continue;
    const directory = path.join(root,item.name); const metadata = path.join(directory,'deck-account.json');
    let identity = { Harness: 'Codex', Provider: 'ChatGPT' };
    try {
      if (fs.existsSync(metadata)) {
        requireThat(!fs.lstatSync(metadata).isSymbolicLink() && fs.statSync(metadata).size < 16384, 'Invalid Deck metadata.');
        identity = JSON.parse(fs.readFileSync(metadata,'utf8').replace(/^\uFEFF/,''));
      }
      requireThat(harnesses[identity.Harness]?.includes(identity.Provider), 'Invalid Deck harness/provider.');
      // Credential contents and account emails never enter the gateway.
      result.accounts.push({ id: item.name, harness: identity.Harness, provider: identity.Provider, runner: !!identity.RunnerSid });
    } catch { result.accounts.push({ id: item.name, error: 'Invalid account metadata' }); }
  }
  return result;
}
export async function launchDeck(settings, input) {
  requireThat(process.platform === 'win32', 'Deck terminal integration currently requires Windows.', 501);
  requireThat(path.resolve(settings.deckRoot).toLowerCase() === path.join(os.homedir(),'.codex-loop').toLowerCase(), 'The current codex-auth wrapper launches accounts from your home .codex-loop only.');
  const snapshot = deckAccounts(settings);
  requireThat(snapshot.scriptAvailable, 'Deck wrapper is missing. Set its path in Settings.', 404);
  requireThat(/^[a-zA-Z][a-zA-Z0-9_-]{0,39}$/.test(input.account || '') && !/^(skills|con|prn|aux|nul|com[0-9]|lpt[0-9])$/i.test(input.account), 'Choose a valid Deck account (letter first, up to 40 letters, numbers, underscores or dashes).');
  requireThat(['open','login','create'].includes(input.action), 'Choose open, login, or create.');
  const account = snapshot.accounts.find(a => a.id === input.account);
  if (input.action === 'create') {
    requireThat(!account, 'That Deck account already exists.', 409);
    requireThat(harnesses[input.harness]?.includes(input.provider), 'Invalid harness/provider selection.');
    if (input.harness !== 'Codex') requireThat(snapshot.harnessModuleAvailable, 'Deploy the Harnesses-enabled Deck build first.', 409);
  } else {
    requireThat(account && !account.error, 'Deck account does not exist or has invalid metadata.', 404);
    if (account.harness !== 'Codex') requireThat(snapshot.harnessModuleAvailable, 'Deploy the Harnesses-enabled Deck build first.', 409);
  }
  requireThat(['Off','Ordered','Best',undefined].includes(input.failover), 'Invalid Deck failover mode.');
  requireThat(!(input.pool || input.failover && input.failover !== 'Off') || account?.harness === 'Codex' && input.action === 'open', 'Deck pools and failover apply to existing Codex accounts only.');
  const spec = { script: path.resolve(settings.deckScript), account: input.account, action: input.action, harness: input.action === 'create' ? input.harness : account.harness, provider: input.action === 'create' ? input.provider : account.provider, pool: input.pool === true, failover: input.failover || 'Off' };
  const helper = fileURLToPath(new URL('../scripts/launch-deck.ps1',import.meta.url));
  await new Promise((resolve,reject) => {
    const child = execFile('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helper],{ windowsHide: true, timeout: 15000 },(error) => error ? reject(new HttpError(500,'Deck terminal could not be opened. Check the configured wrapper path.')) : resolve());
    child.stdin.end(JSON.stringify(spec));
  });
  return { opened: true, account: input.account };
}
