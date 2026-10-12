import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes, createCipheriv, createDecipheriv, createHash, timingSafeEqual } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const tokenHash = token => createHash('sha256').update(token).digest('hex');
export const equalToken = (a, b) => typeof a === 'string' && typeof b === 'string' && timingSafeEqual(Buffer.from(tokenHash(a)), Buffer.from(tokenHash(b)));
const protector = fileURLToPath(new URL('../scripts/protect-key.ps1', import.meta.url));
function protect(mode, bytes) {
  return Buffer.from(execFileSync('powershell.exe', ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',protector,'-Mode',mode], { input: bytes.toString('base64'), windowsHide: true, encoding: 'utf8' }).trim(), 'base64');
}
export function defaultConfig() {
  return { version: 1, accounts: [], routes: [], clients: [], settings: { defaultRoute: '', timeoutMs: 120000, cooldownMs: 30000, allowedOrigins: [], deckRoot: path.join(os.homedir(), '.codex-loop'), deckScript: fileURLToPath(new URL('../../CodexDeck/bin/codex-auth.ps1', import.meta.url)) } };
}
export class Store {
  constructor(directory, { masterKey } = {}) {
    this.directory = directory;
    this.allowWebProviders = true;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const keyFile = path.join(directory, process.platform === 'win32' ? 'key.dpapi' : 'key.bin');
    if (masterKey) this.key = masterKey;
    else if (fs.existsSync(keyFile)) {
      const encoded = fs.readFileSync(keyFile);
      this.key = process.platform === 'win32' ? protect('Unprotect', encoded) : encoded;
    } else {
      this.key = randomBytes(32);
      fs.writeFileSync(keyFile, process.platform === 'win32' ? protect('Protect', this.key) : this.key, { mode: 0o600, flag: 'wx' });
    }
    if (this.key.length !== 32) throw new Error('Invalid vault key. Keep the original Windows identity and data directory.');
    this.file = path.join(directory, 'state.json');
    if (fs.existsSync(this.file)) {
      const state = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      const encrypted = Buffer.from(state.vault, 'base64');
      const decipher = createDecipheriv('aes-256-gcm', this.key, encrypted.subarray(0,12));
      decipher.setAuthTag(encrypted.subarray(12,28));
      this.secrets = JSON.parse(Buffer.concat([decipher.update(encrypted.subarray(28)), decipher.final()]).toString('utf8'));
      this.config = state.config;
    } else {
      this.config = defaultConfig();
      this.secrets = { adminToken: randomBytes(32).toString('base64url'), accounts: {} };
      this.save();
    }
  }
  save() {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(this.secrets), 'utf8'), cipher.final()]);
    const vault = Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64');
    const temporary = this.file + '.tmp';
    fs.writeFileSync(temporary, JSON.stringify({ config: this.config, vault }, null, 2), { mode: 0o600 });
    fs.renameSync(temporary, this.file);
  }
  publicConfig() { return { ...structuredClone(this.config), clients: this.config.clients.map(({hash,pairingExtension,...client}) => client), accounts: this.config.accounts.map(a => ({ ...a, hasKey: !!this.secrets.accounts[a.id] })) }; }
}
