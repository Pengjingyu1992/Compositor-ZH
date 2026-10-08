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
  'parent', 'add', 'styled', 'filter', 'adjustment', 'effect'
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

function finite(v, lo, hi) { return typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi; }

// The box a text or shape is rendered into. The editor needs every side to be
// at least 16, and the renderer refuses more than 16 million pixels, so the
// value is clamped here rather than failing later with an opaque error.
const MIN_BOX = 16, MAX_BOX_PIXELS = 16_000_000;

function boxOf(value, document) {
  const width = document?.width ?? 1920, height = document?.height ?? 1080;
  const fallback = [Math.min(600, Math.max(MIN_BOX, width)), Math.min(300, Math.max(MIN_BOX, height))];
  const wanted = pair(value) ? value : fallback;
  let [w, h] = wanted.map(v => Math.max(MIN_BOX, Math.min(30000, Math.round(v))));
  if (w * h > MAX_BOX_PIXELS) { const k = Math.sqrt(MAX_BOX_PIXELS / (w * h)); w = Math.max(MIN_BOX, Math.floor(w * k)); h = Math.max(MIN_BOX, Math.floor(h * k)); }
  return [w, h];
}

function colorOf(style) {
  const channel = (name) => style?.[name] === undefined ? 1 : style[name];
  const [red, green, blue] = [channel('red'), channel('green'), channel('blue')];
  if (![red, green, blue].every(v => finite(v, 0, 1))) return null;
  return { red, green, blue };
}

// A text or shape layer is a rendered image plus the parameters it came from.
// The model supplies only the parameters worth deciding; everything the
// renderer needs but the model should not have to invent is filled in here.
// The result is ready for renderText/renderShape and for the editor.
export function styledStyle(type, style, document) {
  const colour = colorOf(style);
  if (!colour) return { error: 'colour' };
  if (type === 'text') {
    const content = typeof style?.content === 'string' ? style.content : '';
    if (!content.trim() || content.length > 2000) return { error: 'content' };
    const fontSize = style.fontSize === undefined ? 64 : style.fontSize;
    if (!finite(fontSize, 4, 600)) return { error: 'fontSize' };
    const tracking = style.tracking === undefined ? 0 : style.tracking;
    const leading = style.leading === undefined ? 0 : style.leading;
    if (!finite(tracking, -100, 1000) || !finite(leading, 0, 5000)) return { error: 'spacing' };
    const alignment = ['Left', 'Center', 'Right'].includes(style.alignment) ? style.alignment : 'Left';
    return {
      style: {
        content, fontName: typeof style.fontName === 'string' && style.fontName.trim() && !/[\r\n]/.test(style.fontName) ? style.fontName.trim() : 'ArialMT',
        fontSize, ...colour, alignment, tracking, leading,
        boxSize: boxOf(style.boxSize, document), colorRuns: [], fontRuns: []
      }
    };
  }
  if (type === 'shape') {
    const kind = ['Rectangle', 'Ellipse', 'Line'].includes(style?.kind) ? style.kind : 'Rectangle';
    const cornerRadius = style.cornerRadius === undefined ? 0 : style.cornerRadius;
    const lineWidth = style.lineWidth === undefined ? 0 : style.lineWidth;
    if (!finite(cornerRadius, 0, 30000) || !finite(lineWidth, 0, 2000)) return { error: 'shape' };
    const unit = (value, fallback) => pair(value) && value.every(v => finite(v, 0, 1)) ? value : fallback;
    return {
      style: {
        kind, ...colour, cornerRadius, lineWidth,
        start: unit(style.start, [0, 0]), end: unit(style.end, [1, 1]),
        boxSize: boxOf(style.boxSize, document)
      }
    };
  }
  return { error: 'type' };
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
    '{"kind":"styled","type":"text","origin":[x,y],"style":{"content":"text","fontSize":96,"red":1,"green":1,"blue":1,"alignment":"Center"}}',
    '{"kind":"styled","type":"shape","origin":[x,y],"style":{"kind":"Rectangle","red":1,"green":0.3,"blue":0.3,"cornerRadius":0,"lineWidth":0,"start":[0,0],"end":[1,1]}}',
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
    '- A "styled" operation without an "id" creates a new text or shape layer; with an "id" it restyles that layer.',
    '- Text and shapes are rendered by the editor, so give the parameters, not an image.',
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
  // A text or shape layer may be created (no id) or restyled (id present), so
  // the id is only looked up when the answer supplies one.
  if (kind === 'styled') {
    if (!['text', 'shape'].includes(operation.type)) return 'type';
    if (operation.id !== undefined && (typeof operation.id !== 'string' || !ids.has(operation.id.toUpperCase()))) return 'layer';
    if (operation.origin !== undefined && !pair(operation.origin)) return 'value';
    const problem = styledStyle(operation.type, operation.style, null).error;
    if (problem) return problem === 'content' || problem === 'fontSize' ? problem : 'style';
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
