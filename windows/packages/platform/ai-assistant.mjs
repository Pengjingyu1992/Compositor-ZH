// Support for the AI assistant panel: it turns a natural-language request into
// a short list of layer operations for the project that is open.
//
// Everything here is pure. The network call lives in the main process and the
// UI lives in the renderer, so the parts worth testing stay testable without
// Electron, a window, or an API key.

import { ADJUSTMENT_KINDS, BLEND_MODES, EFFECT_KINDS } from '../comp-bridge/capabilities.mjs';

export const DEFAULT_ENDPOINT = 'https://api.deepseek.com/v1';
export const DEFAULT_MODEL = 'deepseek-flash';
export const MAX_REQUEST = 4000;
export const MAX_OPERATIONS = 20;

// Operations the assistant may emit. Deliberately narrower than what the
// editor accepts: the assistant edits layers, it never opens, saves, imports,
// or writes files, so those kinds are simply not on the menu.
export const ASSISTANT_OPERATIONS = [
  'appearance', 'rename', 'transform', 'reorder', 'duplicate', 'delete',
  'parent', 'add', 'filter', 'adjustment', 'effect'
];

// Fields the editor accepts per operation, with the shape of their value.
// This mirrors packages/comp-bridge/edit.mjs; a value that does not match is
// reported before it reaches the editor so the panel can explain why.
const FIELDS = {
  appearance: { isVisible: v => typeof v === 'boolean', opacity: v => typeof v === 'number' && v >= 0 && v <= 1, blendMode: v => BLEND_MODES.includes(v) },
  transform: {
    origin: pair, size: pair, rotation: v => typeof v === 'number' && Number.isFinite(v),
    flipX: v => typeof v === 'boolean', flipY: v => typeof v === 'boolean'
  }
};

function pair(v) {
  return Array.isArray(v) && v.length === 2 && v.every(n => typeof n === 'number' && Number.isFinite(n));
}

function layerLine(layer, index) {
  const details = [`${index + 1}. id=${layer.id}`, `name="${layer.name}"`, `visible=${layer.isVisible !== false}`];
  if (typeof layer.opacity === 'number' && layer.opacity !== 1) details.push(`opacity=${layer.opacity}`);
  if (layer.blendMode && layer.blendMode !== 'Normal') details.push(`blend="${layer.blendMode}"`);
  if (layer.isGroup) details.push('group=true');
  if (layer.adjustment) details.push(`adjustment=${layer.adjustment.kind}`);
  if (layer.maskFile) details.push('hasMask=true');
  return details.join(' ');
}

export function describeLayers(layers) {
  if (!layers.length) return 'The project has no layers.';
  return `The project has ${layers.length} layer(s), listed bottom to top:\n` +
    layers.map(layerLine).join('\n');
}

// The schema is spelled out with the exact enumerations the editor validates
// against, because a near miss ("Gaussian blur", "multiply") is rejected.
function schema() {
  return [
    'Available operations. Every one takes "id" copied verbatim from the layer list.',
    '{"kind":"appearance","id":"<layer id>","field":"isVisible","value":true}',
    '{"kind":"appearance","id":"<layer id>","field":"opacity","value":0.5}',
    '{"kind":"appearance","id":"<layer id>","field":"blendMode","value":"<one of the blend modes>"}',
    '{"kind":"rename","id":"<layer id>","name":"new name"}',
    '{"kind":"transform","id":"<layer id>","field":"origin","value":[x,y]}',
    '{"kind":"transform","id":"<layer id>","field":"size","value":[width,height]}',
    '{"kind":"transform","id":"<layer id>","field":"rotation","value":degrees}',
    '{"kind":"transform","id":"<layer id>","field":"flipX","value":true}',
    '{"kind":"reorder","id":"<layer id>","direction":1}   // 1 moves up one, -1 moves down one',
    '{"kind":"duplicate","id":"<layer id>"}',
    '{"kind":"delete","id":"<layer id>"}',
    '{"kind":"parent","id":"<layer id>","parentID":"<group id>"}   // omit parentID to move to the root',
    '{"kind":"add","type":"pixels","name":"new layer"}   // type is "pixels", "group", or "adjustment"',
    '{"kind":"add","type":"adjustment","adjustment":"<one of the adjustment kinds>","name":"new adjustment"}',
    '{"kind":"filter","id":"<layer id>","filter":"<one of the filters>","radius":4}',
    '{"kind":"adjustment","id":"<adjustment layer id>","hue":0,"saturation":0,"lightness":0}',
    '{"kind":"effect","id":"<layer id>","effect":"shadow","opacity":0.6}',
    '{"kind":"effect","id":"<layer id>","effect":"shadow","remove":true}',
    '',
    `Blend modes (exactly): ${BLEND_MODES.join(', ')}`,
    `Adjustment kinds (exactly): ${ADJUSTMENT_KINDS.join(', ')}`,
    `Layer effects (exactly): ${EFFECT_KINDS.join(', ')}`,
    `Blend modes, adjustment kinds, and effects must be spelled exactly as listed.`
  ].join('\n');
}

export function systemPrompt({ layers = [], filters = [] }) {
  return [
    'You are the assistant inside Compositor, a layered image editor.',
    'Turn the request into operations on the layers of the project described below.',
    '',
    schema(),
    filters.length ? `\nFilters (exactly): ${filters.join(', ')}` : '',
    '',
    describeLayers(layers),
    '',
    'Rules:',
    '- Answer with one JSON object and nothing else: {"reply":"...","ops":[...]}',
    `- "ops" holds at most ${MAX_OPERATIONS} operations, applied in order.`,
    '- Copy every id from the layer list above. Never invent an id.',
    '- "reply" is one short sentence in the same language as the request.',
    '- If the request cannot be expressed with these operations, return {"reply":"why not","ops":[]}.'
  ].join('\n');
}

export function requestBody({ prompt, layers = [], filters = [], model = DEFAULT_MODEL }) {
  return {
    model,
    temperature: 0,
    messages: [
      { role: 'system', content: systemPrompt({ layers, filters }) },
      { role: 'user', content: prompt }
    ]
  };
}

// Models occasionally wrap JSON in a code fence or add a sentence around it, so
// the outermost braces are used rather than trusting the whole string.
export function readResponse(payload) {
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content !== 'string') return { error: 'empty' };
  const text = content.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/, '').trim();
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end < start) return { error: 'malformed' };
  let parsed;
  try { parsed = JSON.parse(text.slice(start, end + 1)); }
  catch { return { error: 'malformed' }; }
  if (!parsed || typeof parsed !== 'object') return { error: 'malformed' };
  const operations = Array.isArray(parsed.ops)
    ? parsed.ops.filter(op => op && typeof op === 'object' && !Array.isArray(op))
    : [];
  return { reply: typeof parsed.reply === 'string' ? parsed.reply : '', operations };
}

// The editor validates everything again, but an operation that is checked here
// produces a message the panel can show, instead of an opaque failure later.
export function checkOperation(operation, layers) {
  const kind = operation?.kind;
  if (!ASSISTANT_OPERATIONS.includes(kind)) return 'operation';
  const ids = new Set(layers.map(l => l.id.toUpperCase()));
  if (kind === 'add') {
    if (!['pixels', 'group', 'adjustment'].includes(operation.type)) return 'type';
    if (operation.type === 'adjustment' && !ADJUSTMENT_KINDS.includes(operation.adjustment)) return 'adjustment';
    return '';
  }
  const known = operation.id ?? operation.ids?.[0];
  if (typeof known !== 'string' || !ids.has(known.toUpperCase())) return 'layer';
  if (kind === 'appearance' || kind === 'transform') {
    const test = FIELDS[kind]?.[operation.field];
    if (!test || !test(operation.value)) return 'value';
  }
  if (kind === 'filter' && typeof operation.filter !== 'string') return 'value';
  if (kind === 'effect' && !EFFECT_KINDS.includes(operation.effect)) return 'effect';
  if (kind === 'reorder' && ![1, -1].includes(operation.direction)) return 'value';
  if (kind === 'parent' && operation.parentID !== undefined) {
    const group = layers.find(l => l.id.toUpperCase() === String(operation.parentID).toUpperCase());
    if (!group || !group.isGroup || group.id.toUpperCase() === known.toUpperCase()) return 'group';
  }
  if (kind === 'adjustment') {
    const layer = layers.find(l => l.id.toUpperCase() === known.toUpperCase());
    if (!layer?.adjustment) return 'adjustmentLayer';
  }
  return '';
}

// Splits a model answer into what the panel may run and what it should report.
export function checkOperations(operations, layers) {
  const accepted = [], rejected = [];
  for (const [index, operation] of operations.slice(0, MAX_OPERATIONS).entries()) {
    const reason = checkOperation(operation, layers);
    if (reason) rejected.push({ index, operation, reason });
    else accepted.push(operation);
  }
  return { accepted, rejected };
}
