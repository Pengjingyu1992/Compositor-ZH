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

// Operations the assistant may emit. It edits layers; it never opens, saves,
// imports, or writes files, so those kinds are not on the menu at all.
export const ASSISTANT_OPERATIONS = [
  'appearance', 'rename', 'transform', 'reorder', 'duplicate', 'delete', 'parent',
  'add', 'styled', 'filter', 'adjustment', 'effect',
  'lock', 'rasterize', 'applyMask', 'ungroup', 'transformMask',
  'group', 'arrange', 'moveLayers', 'transformLayers',
  'canvas', 'imageSize', 'flipCanvas'
];

// What the editor also has, and why the assistant is deliberately not offered
// it. Each entry says what the model would have to supply and cannot. The
// prompt states these too, so a request for one is answered honestly rather
// than by quietly doing nothing.
export const EXCLUDED_OPERATIONS = {
  selection: 'a selection is made by pointing at the canvas',
  selectionMask: 'it converts an existing selection, which the model cannot see',
  fill: 'it needs a selection; without one it would fill the whole layer',
  gradient: 'it needs a selection and two points on the canvas',
  clear: 'it needs a selection; without one it would erase the whole layer',
  bucket: 'it seeds from a pixel of the canvas',
  stroke: 'it is a freehand path drawn over the canvas',
  pixels: 'it is raw pixel data, which the model cannot produce',
  guides: 'guides are dragged out of the rulers',
  merge: 'it needs the layers composited into one image, which is the editor\'s own merge path',
  batch: 'the panel already applies the operations in order',
  duplicateTree: 'duplicate already copies a group together with its children',
  importPixels: 'add with type "pixels" covers it'
};

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

// The editor validates all of this again; checking here is what lets the panel
// say which part of a request it could not carry out.
const ARRANGE_OPERATIONS = ['left', 'hcenter', 'right', 'top', 'vcenter', 'bottom', 'hspread', 'vspread', 'hgap', 'vgap'];
const ARRANGE_REFERENCES = ['selection', 'canvas', 'keyObject'];
const LOCK_FIELDS = ['content', 'position', 'appearance', 'alpha'];
const TRANSFORM_FIELDS = ['origin', 'size', 'rotation', 'flipX', 'flipY', 'sampling'];
const SURFACE_LIMIT = 30000;

// Exported so the prompt, the tests and the documentation all read the same
// enumerations rather than restating them.
export { ARRANGE_OPERATIONS, ARRANGE_REFERENCES, LOCK_FIELDS, TRANSFORM_FIELDS };

const named = (v) => v === undefined || (typeof v === 'string' && v.length > 0 && v.length <= 256);
const surface = (op) => finite(op.width, 1, SURFACE_LIMIT) && finite(op.height, 1, SURFACE_LIMIT);

// Operations that name one layer or a set of them, checked after the ids have
// been resolved. Document-wide operations name none.
const CHECKS = {
  lock: op => LOCK_FIELDS.includes(op.field) && typeof op.value === 'boolean' ? '' : 'value',
  transformMask: op => TRANSFORM_FIELDS.includes(op.field) && op.value !== undefined ? '' : 'value',
  transformLayers: op => TRANSFORM_FIELDS.includes(op.field) && op.value !== undefined ? '' : 'value',
  rasterize: () => '',
  applyMask: () => '',
  ungroup: () => '',
  group: op => named(op.name) ? '' : 'value',
  moveLayers: op => pair(op.delta) ? '' : 'value',
  arrange: op => !ARRANGE_OPERATIONS.includes(op.operation) || !ARRANGE_REFERENCES.includes(op.reference) ? 'value'
    : op.reference === 'keyObject' && typeof op.keyID !== 'string' ? 'value' : '',
  canvas: op => surface(op) && (op.x === undefined || finite(op.x, -SURFACE_LIMIT, SURFACE_LIMIT)) && (op.y === undefined || finite(op.y, -SURFACE_LIMIT, SURFACE_LIMIT)) ? '' : 'value',
  imageSize: op => surface(op) ? '' : 'value',
  flipCanvas: op => ['horizontal', 'vertical'].includes(op.axis) ? '' : 'value'
};

// Operations that act on a whole set of layers rather than one.
const SET_OPERATIONS = ['group', 'arrange', 'moveLayers', 'transformLayers'];
// Operations that act on the document and name no layers.
const DOCUMENT_OPERATIONS = ['canvas', 'imageSize', 'flipCanvas'];

// The editor matches ids exactly (comp-bridge/edit.mjs: `m.layers.find(l => l.id
// === op.id)`), so an id the model re-cased would come back as an opaque
// 'stale'. Every id the operation names is mapped back to the spelling the
// project uses. `id` is always present in the result, including when it is
// undefined: the editor's own edit() fills in the selected layer when that key
// is missing, which would retarget the operation.
export function canonicalOperation(operation, layers) {
  const exact = new Map(layers.map(l => [l.id.toUpperCase(), l.id]));
  const one = id => typeof id === 'string' ? exact.get(id.toUpperCase()) : undefined;
  const copy = { ...operation, id: one(operation.id) };
  if (Array.isArray(operation.ids)) copy.ids = operation.ids.map(one).filter(Boolean);
  if (operation.parentID !== undefined) copy.parentID = one(operation.parentID);
  if (operation.maskSourceID !== undefined) copy.maskSourceID = one(operation.maskSourceID);
  if (operation.keyID !== undefined) copy.keyID = one(operation.keyID);
  return copy;
}

// The layer ids an operation names, whether it names one or a set.
function namedIds(operation) {
  if (Array.isArray(operation.ids)) return operation.ids;
  return operation.id === undefined ? [] : [operation.id];
}

// A set operation needs at least one layer, and every id in it has to exist.
function checkSet(operation, layers) {
  const ids = namedIds(operation);
  if (!ids.length || ids.length > 10000) return 'layer';
  const known = new Set(layers.map(l => l.id.toUpperCase()));
  return ids.every(id => typeof id === 'string' && known.has(id.toUpperCase())) ? '' : 'layer';
}

// Grouping and merging also require the layers to be siblings.
function checkSiblings(operation, layers) {
  const ids = namedIds(operation).map(id => layers.find(l => l.id.toUpperCase() === String(id).toUpperCase()));
  if (ids.some(l => !l)) return 'layer';
  const parents = new Set(ids.map(l => l.parentID?.toUpperCase() ?? ''));
  if (parents.size > 1) return 'siblings';
  return '';
}

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
    '{"kind":"lock","id":"<layer id>","field":"content","value":true}   // also "position", "appearance", "alpha"',
    '{"kind":"rasterize","id":"<layer id>"}   // turns text or a shape into plain pixels',
    '{"kind":"applyMask","id":"<layer id>"}   // bakes the mask into the pixels and drops it',
    '{"kind":"ungroup","id":"<group id>"}',
    '{"kind":"transformMask","id":"<layer id>","field":"origin","value":[x,y]}   // the layer must already have a mask',
    '{"kind":"group","ids":["<layer id>","<layer id>"],"name":"new group"}   // the layers must share a parent',
    '{"kind":"arrange","ids":[".","."],"operation":"left","reference":"selection"}',
    '{"kind":"moveLayers","ids":["<layer id>"],"delta":[dx,dy]}',
    '{"kind":"transformLayers","ids":[".","."],"field":"size","value":[w,h]}',
    '{"kind":"canvas","width":1920,"height":1080}   // x, y optional; shifts all layers to match the new origin',
    '{"kind":"imageSize","width":960,"height":540}   // resamples every layer; nearest optional',
    '{"kind":"flipCanvas","axis":"horizontal"}   // or "vertical"',
    '',
    `Blend modes (exactly): ${BLEND_MODES.join(', ')}`,
    `Adjustment kinds (exactly): ${ADJUSTMENT_KINDS.join(', ')}`,
    `Layer effects (exactly): ${EFFECT_KINDS.join(', ')}`,
    `arrange operations (exactly): ${ARRANGE_OPERATIONS.join(', ')}`,
    `arrange references (exactly): ${ARRANGE_REFERENCES.join(', ')}`,
    `transform fields (exactly): ${TRANSFORM_FIELDS.join(', ')}`,
    `lock fields (exactly): ${LOCK_FIELDS.join(', ')}`,
    'Every enumeration must be spelled exactly as listed, or the editor rejects the operation.'
  ].join('\n');
}

// The editor offers more than the assistant is given. Saying so keeps the model
// from promising something it cannot deliver, and from inventing a substitute
// that appears to work but means nothing.
function cannot() {
  const lines = Object.entries(EXCLUDED_OPERATIONS).map(([kind, why]) => `- ${kind}: ${why}`);
  return [
    '',
    'You cannot do the following, because the editor needs information that is not',
    'in this conversation. Say so plainly if you are asked for one:',
    ...lines
  ].join('\n');
}

export function systemPrompt({ layers = [], filters = [] }) {
  return [
    'You are the assistant inside Compositor, a layered image editor.',
    'Turn the request into operations on the layers of the project described below.',
    '',
    schema(),
    cannot(),
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
  const byId = new Map(layers.map(l => [l.id.toUpperCase(), l]));
  const named = operation.id ?? namedIds(operation)[0];

  if (kind === 'add') {
    if (!['pixels', 'group', 'adjustment'].includes(operation.type)) return 'type';
    if (operation.type === 'adjustment' && !ADJUSTMENT_KINDS.includes(operation.adjustment)) return 'adjustment';
    return '';
  }
  // A text or shape layer may be created (no id) or restyled (id present), so
  // the id is only looked up when the answer supplies one.
  if (kind === 'styled') {
    if (!['text', 'shape'].includes(operation.type)) return 'type';
    if (operation.id !== undefined && (typeof operation.id !== 'string' || !byId.has(operation.id.toUpperCase()))) return 'layer';
    if (operation.origin !== undefined && !pair(operation.origin)) return 'value';
    const problem = styledStyle(operation.type, operation.style, null).error;
    if (problem) return problem === 'content' || problem === 'fontSize' ? problem : 'style';
    return '';
  }
  // Canvas-wide operations name no layers at all.
  if (DOCUMENT_OPERATIONS.includes(kind)) return CHECKS[kind](operation);
  // Grouping, merging, aligning and moving act on a set of layers.
  if (SET_OPERATIONS.includes(kind)) {
    const missing = checkSet(operation, layers);
    if (missing) return missing;
    if (kind === 'group') {
      const siblings = checkSiblings(operation, layers);
      if (siblings) return siblings;
    }
    return CHECKS[kind](operation);
  }

  if (typeof named !== 'string' || !byId.has(named.toUpperCase())) return 'layer';
  const layer = byId.get(named.toUpperCase());
  if (kind === 'appearance' || kind === 'transform') {
    const test = FIELDS[kind]?.[operation.field];
    if (!test || !test(operation.value)) return 'value';
  }
  if (kind === 'filter' && typeof operation.filter !== 'string') return 'value';
  if (kind === 'effect' && !EFFECT_KINDS.includes(operation.effect)) return 'effect';
  if (kind === 'reorder' && ![1, -1].includes(operation.direction)) return 'value';
  if (kind === 'parent' && operation.parentID !== undefined) {
    const group = byId.get(String(operation.parentID).toUpperCase());
    if (!group || !group.isGroup || group.id.toUpperCase() === named.toUpperCase()) return 'group';
  }
  if (kind === 'adjustment' && !layer.adjustment) return 'adjustmentLayer';
  if ((kind === 'applyMask' || kind === 'transformMask') && !layer.maskFile) return 'noMask';
  if (kind === 'ungroup' && !layer.isGroup) return 'group';
  return CHECKS[kind] ? CHECKS[kind](operation) : '';
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
