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
export function accountInput(input, current = {}, allowWebProviders = false) {
  const provider = providerById(input.provider || current.provider);
  requireThat(provider, 'Choose a supported provider.');
  requireThat(!provider.webSession || allowWebProviders, 'Web session providers are not enabled for this Router configuration.');
  const id = input.id || current.id || randomUUID();
  requireThat(identifier(id), 'Invalid account identifier.');
  requireThat(typeof input.name === 'string' && input.name.trim().length > 0 && input.name.length <= 100, 'Account name must be 1–100 characters.');
  const capabilities = input.capabilities || provider.capabilities;
  requireThat(Array.isArray(capabilities) && capabilities.length && capabilities.every(c => provider.capabilities.includes(c)), 'Invalid account capabilities.');
  if (provider.webSession) {
    requireThat(!input.proxyUrl, 'Web session providers do not support per-account proxies.');
    const requestedUrl = validUrl(input.baseUrl || provider.baseUrl);
    requireThat(new URL(requestedUrl).origin === new URL(provider.baseUrl).origin, 'Web session providers use their fixed website origin.');
  }
  let webOptions;
  if (provider.webSession) {
    const requested = input.webOptions || current.webOptions || {};
    const transport = requested.transport === undefined ? 'api-v2' : requested.transport;
    requireThat(['api-v2','ui-v1'].includes(transport), 'Choose Web API v2 or UI bridge v1.');
    const model = requested.model === undefined ? 'auto' : requested.model;
    requireThat(typeof model === 'string' && model.trim().length > 0 && model.length <= 200 && !/[\r\n]/.test(model), 'Enter a valid preferred web model.');
    requireThat(requested.images === undefined || typeof requested.images === 'boolean', 'Invalid web image setting.');
    requireThat(requested.tools === undefined || typeof requested.tools === 'boolean', 'Invalid web tool setting.');
    webOptions = { transport, model: model.trim(), images: requested.images !== false, tools: requested.tools !== false };
  }
  return { id, name: input.name.trim(), provider: provider.id, enabled: input.enabled !== false, baseUrl: provider.webSession ? provider.baseUrl : validUrl(input.baseUrl || provider.baseUrl), proxyUrl: provider.webSession ? '' : input.proxyUrl ? validUrl(input.proxyUrl, { proxy: true }) : '', capabilities: [...new Set(capabilities)], ...(webOptions ? { webOptions } : {}) };
}
export function routeInput(input, accounts, deckAccounts = []) {
  requireThat(identifier(input.id), 'Route alias must use letters, numbers, dots, underscores, or dashes.');
  requireThat(['ordered','round-robin'].includes(input.strategy), 'Choose ordered failover or round robin.');
  requireThat(Array.isArray(input.targets) && input.targets.length > 0 && input.targets.length <= 16, 'Add 1–16 route targets.');
  const targets = input.targets.map(t => {
    const native = typeof t?.account === 'string' && t.account.startsWith('deck:')
      ? deckAccounts.find(a => `deck:${a.id}` === t.account && a.routable)
      : null;
    const configured = accounts.find(a => a.id === t?.account);
    requireThat(configured || native, 'Route target account does not exist or is not signed in.');
    requireThat(typeof t.model === 'string' && t.model.trim().length && t.model.length <= 200 && !/[\r\n]/.test(t.model), 'Enter an upstream model identifier.');
    if (providerById(configured?.provider)?.webSession) requireThat(t.model.trim().length <= 200, 'Web provider model names must be 200 characters or fewer.');
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
