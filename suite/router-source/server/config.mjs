const randomUUID = () => globalThis.crypto.randomUUID();
import { providerById } from './catalog.mjs';
import { requireThat } from './errors.mjs';

export const identifier = value => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$/.test(value);
export function validUrl(value, { proxy = false } = {}) {
  let url; try { url = new URL(value); } catch { requireThat(false, 'Enter a valid URL.'); }
  requireThat(['https:','http:'].includes(url.protocol), 'Use an HTTP or HTTPS URL.');
  requireThat(!url.username && !url.password && !url.search && !url.hash, 'URLs cannot contain credentials, query strings, or fragments.');
  requireThat(proxy || url.protocol === 'https:' || ['localhost','127.0.0.1','[::1]'].includes(url.hostname), 'Remote provider endpoints require HTTPS.');
  return url.href.replace(/\/$/, '');
}
export function accountInput(input, current = {}) {
  const provider = providerById(input.provider || current.provider);
  requireThat(provider, 'Choose a supported provider.');
  const id = input.id || current.id || randomUUID();
  requireThat(identifier(id), 'Invalid account identifier.');
  requireThat(typeof input.name === 'string' && input.name.trim().length > 0 && input.name.length <= 100, 'Account name must be 1–100 characters.');
  const capabilities = input.capabilities || provider.capabilities;
  requireThat(Array.isArray(capabilities) && capabilities.length && capabilities.every(c => provider.capabilities.includes(c)), 'Invalid account capabilities.');
  return { id, name: input.name.trim(), provider: provider.id, enabled: input.enabled !== false, baseUrl: validUrl(input.baseUrl || provider.baseUrl), proxyUrl: input.proxyUrl ? validUrl(input.proxyUrl, { proxy: true }) : '', capabilities: [...new Set(capabilities)] };
}
export function routeInput(input, accounts) {
  requireThat(identifier(input.id), 'Route alias must use letters, numbers, dots, underscores, or dashes.');
  requireThat(['ordered','round-robin'].includes(input.strategy), 'Choose ordered failover or round robin.');
  requireThat(Array.isArray(input.targets) && input.targets.length > 0 && input.targets.length <= 16, 'Add 1–16 route targets.');
  const targets = input.targets.map(t => {
    requireThat(accounts.some(a => a.id === t.account), 'Route target account does not exist.');
    requireThat(typeof t.model === 'string' && t.model.trim().length && t.model.length <= 200 && !/[\r\n]/.test(t.model), 'Enter an upstream model identifier.');
    return { account: t.account, model: t.model.trim() };
  });
  return { id: input.id, name: String(input.name || input.id).slice(0,100), enabled: input.enabled !== false, strategy: input.strategy, failover: input.failover !== false, retryAuthErrors: input.retryAuthErrors === true, targets };
}
export function settingsInput(input, current) {
  const result = { ...current };
  if ('defaultRoute' in input) result.defaultRoute = String(input.defaultRoute);
  for (const [key,min,max] of [['timeoutMs',1000,600000],['cooldownMs',1000,300000]]) {
    if (key in input) { requireThat(Number.isInteger(input[key]) && input[key] >= min && input[key] <= max, `${key} must be ${min}–${max}.`); result[key] = input[key]; }
  }
  if ('allowedOrigins' in input) {
    requireThat(Array.isArray(input.allowedOrigins) && input.allowedOrigins.length <= 40, 'At most 40 website origins are allowed.');
    result.allowedOrigins = input.allowedOrigins.map(value => {
      const url = new URL(validUrl(value));
      requireThat(url.pathname === '/', 'Allow a website origin, without a path.');
      return url.origin;
    });
  }
  for (const key of ['deckRoot','deckScript']) if (key in input) {
    requireThat(typeof input[key] === 'string' && input[key].length < 1024 && !/[\r\n\0]/.test(input[key]), 'Invalid Deck path.');
    result[key] = input[key];
  }
  return result;
}
