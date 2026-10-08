// Models are deliberately discovered from accounts rather than frozen in a release.
export const providers = [
  { id: 'openai', name: 'OpenAI', mark: 'OA', color: '#647d71', baseUrl: 'https://api.openai.com/v1', dialect: 'openai', capabilities: ['chat','responses','embeddings','images','audio'], docs: 'https://platform.openai.com/api-keys' },
  { id: 'google', name: 'Google AI Studio', mark: 'G', color: '#6485af', baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', dialect: 'openai', capabilities: ['chat','embeddings'], docs: 'https://aistudio.google.com/apikey' },
  { id: 'anthropic', name: 'Anthropic', mark: 'A', color: '#bd7c5a', baseUrl: 'https://api.anthropic.com/v1', dialect: 'anthropic', capabilities: ['chat','messages'], docs: 'https://console.anthropic.com/settings/keys' },
  { id: 'deepseek', name: 'DeepSeek', mark: 'DS', color: '#557cbb', baseUrl: 'https://api.deepseek.com/v1', dialect: 'openai', capabilities: ['chat'], docs: 'https://platform.deepseek.com/api_keys' },
  { id: 'xai', name: 'xAI', mark: 'X', color: '#626260', baseUrl: 'https://api.x.ai/v1', dialect: 'openai', capabilities: ['chat','responses','images','audio'], docs: 'https://console.x.ai' },
  { id: 'cloudflare', name: 'Cloudflare Workers AI', mark: 'CF', color: '#df864d', baseUrl: '', dialect: 'openai', capabilities: ['chat','embeddings'], docs: 'https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/' },
  { id: 'openrouter', name: 'OpenRouter', mark: 'OR', color: '#8580a9', baseUrl: 'https://openrouter.ai/api/v1', dialect: 'openai', capabilities: ['chat'], docs: 'https://openrouter.ai/settings/keys' },
  { id: 'mistral', name: 'Mistral', mark: 'M', color: '#d49a3d', baseUrl: 'https://api.mistral.ai/v1', dialect: 'openai', capabilities: ['chat','embeddings'], docs: 'https://console.mistral.ai/api-keys' },
  { id: 'custom', name: 'OpenAI-compatible', mark: '+', color: '#829484', baseUrl: '', dialect: 'openai', capabilities: ['chat','responses','embeddings','images','audio'], docs: 'https://github.com/ollama/ollama/blob/main/docs/openai.md' }
];
export const providerById = id => providers.find(p => p.id === id);
export const endpoints = new Map([
  ['/chat/completions','chat'], ['/responses','responses'], ['/embeddings','embeddings'],
  ['/images/generations','images'], ['/audio/speech','audio'], ['/audio/transcriptions','audio'],
  ['/audio/translations','audio'], ['/messages','messages']
]);
