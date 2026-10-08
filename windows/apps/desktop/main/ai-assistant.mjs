// The AI assistant's main-process side: it owns the API key, makes the request,
// and answers the renderer's IPC calls.
//
// The request is made here rather than in the renderer because the renderer
// runs under `connect-src 'self'`, so it cannot reach an outside host at all.
//
// The key is encrypted with Electron's safeStorage (DPAPI on Windows) before it
// is written to disk, and it is never sent back to the renderer: the renderer
// only learns whether a key is set.

import { safeStorage } from 'electron';
import { getAiSettings, setAiSettings } from '../../../packages/platform/ai-settings.mjs';
import { requestBody, readResponse, DEFAULT_ENDPOINT, DEFAULT_MODEL, MAX_REQUEST } from '../../../packages/platform/ai-assistant.mjs';
// The canonical filter identifiers. The renderer's label list uses display
// names ("Content Repair" for "Content-Aware Fill"), so the prompt has to read
// them from the module the editor validates against.
import { FILTERS } from '../../../packages/comp-bridge/raster-tools.mjs';

const TIMEOUT = 60_000;

function encrypt(value) {
  if (!value) return '';
  if (!safeStorage.isEncryptionAvailable()) return '';
  return safeStorage.encryptString(value).toString('base64');
}

function decrypt(value) {
  if (!value) return '';
  if (!safeStorage.isEncryptionAvailable()) return '';
  try { return safeStorage.decryptString(Buffer.from(value, 'base64')); }
  catch { return ''; }
}

async function readSettings(directory) {
  const stored = await getAiSettings(directory);
  // A key that cannot be decrypted was written by another Windows account or
  // another machine; report it as unset so the panel asks for it again.
  const key = decrypt(stored.key);
  return {
    endpoint: stored.endpoint, model: stored.model,
    hasKey: !!key,
    encryption: safeStorage.isEncryptionAvailable()
  };
}

async function writeSettings(directory, incoming) {
  const current = await getAiSettings(directory);
  // An empty key keeps the stored one; null clears it.
  const key = incoming?.key === null ? ''
    : typeof incoming?.key === 'string' && incoming.key ? encrypt(incoming.key)
    : current.key;
  await setAiSettings(directory, { endpoint: incoming?.endpoint, model: incoming?.model, key });
  return readSettings(directory);
}

// Errors travel back as codes so the panel can translate them; a thrown error
// would only reach the renderer as an opaque message string.
async function complete({ directory, prompt, layers }) {
  if (typeof prompt !== 'string' || !prompt.trim()) return { error: 'empty' };
  if (prompt.length > MAX_REQUEST) return { error: 'toomuch' };
  const stored = await getAiSettings(directory);
  const key = decrypt(stored.key);
  if (!key) return { error: 'nokey' };

  const url = stored.endpoint.replace(/\/+$/, '') + '/chat/completions';
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), TIMEOUT);
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
      body: JSON.stringify(requestBody({
        prompt: prompt.trim(),
        layers: Array.isArray(layers) ? layers : [],
        filters: FILTERS,
        model: stored.model
      })),
      signal: stop.signal
    });
    if (!response.ok) return { error: 'http', status: response.status };
    return readResponse(await response.json());
  } catch (error) {
    return { error: error?.name === 'AbortError' ? 'timeout' : 'network' };
  } finally { clearTimeout(timer); }
}

export function registerAiAssistant({ handler, directory }) {
  handler('ai:settings', () => readSettings(directory));
  handler('ai:save', (settings) => writeSettings(directory, settings));
  handler('ai:complete', (prompt, layers) => complete({ directory, prompt, layers }));
}

export { DEFAULT_ENDPOINT, DEFAULT_MODEL };
