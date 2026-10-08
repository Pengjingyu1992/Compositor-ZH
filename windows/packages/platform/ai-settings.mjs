// Storage for the AI assistant settings.
//
// They live next to preferences.json in the app's user data directory. The API
// key is kept as an opaque string: the main process encrypts it with Electron's
// safeStorage before calling setAiSettings, so this module never handles a
// usable key and a settings file that leaks is not a key that leaks.

import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import path from 'node:path';
import { DEFAULT_ENDPOINT, DEFAULT_MODEL } from './ai-assistant.mjs';

const FILE = 'ai-settings.json';
const MAX_ENDPOINT = 300, MAX_MODEL = 120, MAX_KEY = 4096;

// An API key sent in clear text over the network can be read in transit, so
// only https endpoints are accepted, with loopback allowed for a local model
// server that never leaves the machine.
export function checkEndpoint(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > MAX_ENDPOINT) return 'endpoint';
  let url;
  try { url = new URL(value.trim()); }
  catch { return 'endpoint'; }
  const loopback = ['localhost', '127.0.0.1', '[::1]', '::1'].includes(url.hostname);
  if (url.protocol === 'https:') return '';
  if (url.protocol === 'http:' && loopback) return '';
  return 'endpoint';
}

export function checkModel(value) {
  return typeof value === 'string' && value.trim() && value.length <= MAX_MODEL ? '' : 'model';
}

export async function getAiSettings(directory) {
  try {
    const stored = JSON.parse(await readFile(path.join(directory, FILE), 'utf8'));
    return {
      endpoint: checkEndpoint(stored.endpoint) ? DEFAULT_ENDPOINT : stored.endpoint.trim(),
      model: checkModel(stored.model) ? DEFAULT_MODEL : stored.model.trim(),
      key: typeof stored.key === 'string' && stored.key.length <= MAX_KEY ? stored.key : ''
    };
  } catch { return { endpoint: DEFAULT_ENDPOINT, model: DEFAULT_MODEL, key: '' }; }
}

// `key` is already encrypted (or empty to clear it); validation of the endpoint
// and model happens here so a bad value can never reach the request builder.
export async function setAiSettings(directory, settings) {
  const endpoint = String(settings?.endpoint ?? '').trim();
  const model = String(settings?.model ?? '').trim();
  if (checkEndpoint(endpoint)) throw new Error('Invalid endpoint');
  if (checkModel(model)) throw new Error('Invalid model');
  const key = typeof settings?.key === 'string' ? settings.key : '';
  if (key.length > MAX_KEY) throw new Error('Invalid key');
  await mkdir(directory, { recursive: true });
  const temporary = path.join(directory, FILE + '.tmp');
  await writeFile(temporary, JSON.stringify({ endpoint, model, key }), { encoding: 'utf8', mode: 0o600 });
  await rename(temporary, path.join(directory, FILE));
  return { endpoint, model, key: key ? 'set' : '' };
}
