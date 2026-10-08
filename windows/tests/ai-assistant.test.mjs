import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { ADJUSTMENT_KINDS, BLEND_MODES, EFFECT_KINDS } from '../packages/comp-bridge/capabilities.mjs';
import { systemPrompt, requestBody, readResponse, checkOperations, checkOperation, canonicalOperation, styledStyle, ASSISTANT_OPERATIONS, EXCLUDED_OPERATIONS, TRANSFORM_FIELDS, DEFAULT_MODEL } from '../packages/platform/ai-assistant.mjs';
import { checkEndpoint, checkModel, getAiSettings, setAiSettings } from '../packages/platform/ai-settings.mjs';
import { IDS } from './fixtures.mjs';

const FILTERS = ['Gaussian Blur', 'Content-Aware Fill'];
const layers = [
  { id: IDS[0], name: 'Coral / 珊瑚', isVisible: true },
  { id: IDS[1], name: 'Mint / 薄荷', isVisible: false, opacity: .5, maskFile: IDS[1] + '.mask.png' },
  { id: IDS[2], name: 'Group / 组', isVisible: true, isGroup: true }
];

test('the prompt states every enumeration exactly and lists the layer ids', () => {
  const prompt = systemPrompt({ layers, filters: FILTERS });
  for (const value of [...BLEND_MODES, ...ADJUSTMENT_KINDS, ...EFFECT_KINDS, ...FILTERS]) {
    assert.ok(prompt.includes(value), `${value} missing from the prompt`);
  }
  for (const id of IDS) assert.ok(prompt.includes(id), `${id} missing from the layer list`);
  assert.match(prompt, /Coral \/ 珊瑚/);
  assert.match(prompt, /visible=false/);
  assert.match(prompt, /group=true/);
  assert.match(prompt, /hasMask=true/);
  // A project with no layers still produces a usable prompt.
  assert.match(systemPrompt({ layers: [] }), /no layers/);
});

test('the request is deterministic and carries the user turn', () => {
  const body = requestBody({ prompt: 'hide the ridge', layers, filters: FILTERS });
  assert.equal(body.temperature, 0);
  assert.equal(body.model, DEFAULT_MODEL);
  assert.equal(body.messages.length, 2);
  assert.equal(body.messages[1].content, 'hide the ridge');
  assert.equal(requestBody({ prompt: 'x', layers, filters: FILTERS, model: 'local' }).model, 'local');
});

test('answers are read whether or not the model wraps them in prose or a fence', () => {
  const op = { kind: 'rename', id: IDS[0], name: 'Renamed' };
  for (const content of [
    JSON.stringify({ reply: 'ok', ops: [op] }),
    '```json\n' + JSON.stringify({ reply: 'ok', ops: [op] }) + '\n```',
    'Sure!\n' + JSON.stringify({ reply: 'ok', ops: [op] }) + '\nHope that helps.'
  ]) {
    const answer = readResponse({ choices: [{ message: { content } }] });
    assert.equal(answer.reply, 'ok');
    assert.deepEqual(answer.operations, [op]);
  }
  assert.deepEqual(readResponse({ choices: [{ message: { content: 'no json here' } }] }).error, 'malformed');
  assert.deepEqual(readResponse({ choices: [{ message: { content: '{"reply":"a","ops":' } }] }).error, 'malformed');
  assert.deepEqual(readResponse({}).error, 'empty');
  assert.deepEqual(readResponse({ choices: [{ message: { content: '{"reply":"a"}' } }] }).operations, []);
  // Non-object entries are dropped rather than handed to the editor.
  assert.deepEqual(readResponse({ choices: [{ message: { content: '{"reply":"a","ops":[null,7,{"kind":"rename"}]}' } }] }).operations, [{ kind: 'rename' }]);
});

test('operations are checked against the live layer list before anything runs', () => {
  const good = [
    { kind: 'appearance', id: IDS[0], field: 'opacity', value: .5 },
    { kind: 'appearance', id: IDS[0], field: 'blendMode', value: 'Soft Light' },
    { kind: 'appearance', id: IDS[1], field: 'isVisible', value: true },
    { kind: 'rename', id: IDS[0], name: 'N' },
    { kind: 'transform', id: IDS[0], field: 'origin', value: [1, 2] },
    { kind: 'reorder', id: IDS[1], direction: -1 },
    { kind: 'duplicate', id: IDS[0] },
    { kind: 'delete', id: IDS[0] },
    { kind: 'parent', id: IDS[0], parentID: IDS[2] },
    { kind: 'parent', id: IDS[0] },
    { kind: 'add', type: 'pixels', name: 'New' },
    { kind: 'add', type: 'adjustment', adjustment: 'Curves' },
    { kind: 'filter', id: IDS[0], filter: 'Gaussian Blur' },
    { kind: 'effect', id: IDS[0], effect: 'shadow' }
  ];
  const checked = checkOperations(good, layers);
  assert.deepEqual(checked.rejected, []);
  assert.equal(checked.accepted.length, good.length);

  const bad = [
    [{ kind: 'open' }, 'operation'],
    [{ kind: 'appearance', id: 'not-a-layer', field: 'opacity', value: .5 }, 'layer'],
    [{ kind: 'appearance', id: IDS[0], field: 'opacity', value: 4 }, 'value'],
    [{ kind: 'appearance', id: IDS[0], field: 'blendMode', value: 'multiply' }, 'value'],
    [{ kind: 'appearance', id: IDS[0], field: 'colour', value: 'red' }, 'value'],
    [{ kind: 'transform', id: IDS[0], field: 'size', value: [1] }, 'value'],
    [{ kind: 'reorder', id: IDS[0], direction: 2 }, 'value'],
    [{ kind: 'add', type: 'layer' }, 'type'],
    [{ kind: 'add', type: 'adjustment', adjustment: 'Sepia' }, 'adjustment'],
    [{ kind: 'effect', id: IDS[0], effect: 'dropShadow' }, 'effect'],
    [{ kind: 'parent', id: IDS[0], parentID: IDS[1] }, 'group'],
    [{ kind: 'parent', id: IDS[0], parentID: IDS[0] }, 'group'],
    [{ kind: 'adjustment', id: IDS[0], hue: 10 }, 'adjustmentLayer']
  ];
  for (const [operation, reason] of bad) {
    assert.equal(checkOperation(operation, layers), reason, `${JSON.stringify(operation)} should report ${reason}`);
  }
  // Ids are matched case-insensitively, the same way the editor matches them.
  assert.equal(checkOperation({ kind: 'delete', id: IDS[0].toLowerCase() }, layers), '');
});

test('the accepted list never exceeds the operation budget', () => {
  const many = Array.from({ length: 40 }, () => ({ kind: 'delete', id: IDS[0] }));
  assert.equal(checkOperations(many, layers).accepted.length, 20);
});

test('every operation is either offered or explained, and never both', () => {
  const prompt = systemPrompt({ layers, filters: FILTERS });
  for (const kind of ASSISTANT_OPERATIONS) {
    assert.ok(prompt.includes(`"kind":"${kind}"`), `${kind} is offered but missing from the prompt`);
    assert.equal(EXCLUDED_OPERATIONS[kind], undefined, `${kind} is offered and refused at the same time`);
  }
  // The model is told what it cannot do, and why, so it can say so plainly.
  for (const [kind, why] of Object.entries(EXCLUDED_OPERATIONS)) {
    assert.ok(prompt.includes(kind), `${kind} is missing from the cannot list`);
    assert.ok(prompt.includes(why), `the reason for ${kind} is missing`);
  }
  assert.ok(prompt.includes(`transform fields (exactly): ${TRANSFORM_FIELDS.join(', ')}`));
  // Something the editor has but the assistant does not is still refused.
  assert.equal(checkOperation({ kind: 'merge', ids: [IDS[0]] }, layers), 'operation');
  assert.equal(checkOperation({ kind: 'stroke', id: IDS[0] }, layers), 'operation');
});

test('the layer, set and document operations are checked in their documented shape', () => {
  const valid = [
    { kind: 'lock', id: IDS[0], field: 'content', value: true },
    { kind: 'lock', id: IDS[1], field: 'alpha', value: false },
    { kind: 'rasterize', id: IDS[0] },
    { kind: 'applyMask', id: IDS[1] },
    { kind: 'transformMask', id: IDS[1], field: 'origin', value: [1, 2] },
    { kind: 'ungroup', id: IDS[2] },
    { kind: 'group', ids: [IDS[0], IDS[1]], name: 'G' },
    { kind: 'arrange', ids: [IDS[0], IDS[1]], operation: 'left', reference: 'selection' },
    { kind: 'arrange', ids: [IDS[0]], operation: 'vcenter', reference: 'canvas' },
    { kind: 'arrange', ids: [IDS[0], IDS[1]], operation: 'hgap', reference: 'keyObject', keyID: IDS[1] },
    { kind: 'moveLayers', ids: [IDS[0]], delta: [10, -10] },
    { kind: 'transformLayers', ids: [IDS[0], IDS[1]], field: 'size', value: [100, 50] },
    { kind: 'canvas', width: 800, height: 600 },
    { kind: 'canvas', width: 800, height: 600, x: 20, y: 30 },
    { kind: 'imageSize', width: 320, height: 240 },
    { kind: 'flipCanvas', axis: 'horizontal' }
  ];
  for (const operation of valid) assert.equal(checkOperation(operation, layers), '', JSON.stringify(operation));

  const invalid = [
    [{ kind: 'lock', id: IDS[0], field: 'size', value: true }, 'value'],
    [{ kind: 'lock', id: IDS[0], field: 'content', value: 'yes' }, 'value'],
    [{ kind: 'applyMask', id: IDS[0] }, 'noMask'],
    [{ kind: 'transformMask', id: IDS[0], field: 'origin', value: [1, 2] }, 'noMask'],
    [{ kind: 'transformMask', id: IDS[1], field: 'opacity', value: 1 }, 'value'],
    [{ kind: 'ungroup', id: IDS[0] }, 'group'],
    [{ kind: 'group', ids: [] }, 'layer'],
    [{ kind: 'group', ids: [IDS[0], 'nope'] }, 'layer'],
    [{ kind: 'group', ids: [IDS[0], IDS[1]], name: 'x'.repeat(300) }, 'value'],
    [{ kind: 'arrange', ids: [IDS[0]], operation: 'middle', reference: 'canvas' }, 'value'],
    [{ kind: 'arrange', ids: [IDS[0]], operation: 'left', reference: 'keyObject' }, 'value'],
    [{ kind: 'moveLayers', ids: [IDS[0]], delta: 5 }, 'value'],
    [{ kind: 'canvas', width: 0, height: 100 }, 'value'],
    [{ kind: 'canvas', width: 99999, height: 100 }, 'value'],
    [{ kind: 'imageSize', width: 320 }, 'value'],
    [{ kind: 'flipCanvas', axis: 'diagonal' }, 'value']
  ];
  for (const [operation, reason] of invalid) {
    assert.equal(checkOperation(operation, layers), reason, `${JSON.stringify(operation)} should report ${reason}`);
  }
});

test('grouping requires the layers to share a parent', () => {
  const parented = [
    { id: IDS[0], name: 'a', isVisible: true },
    { id: IDS[1], name: 'b', isVisible: true },
    { id: IDS[2], name: 'g', isVisible: true, isGroup: true },
    { id: '00000000-0000-4000-8000-000000000004', name: 'c', isVisible: true, parentID: IDS[2] },
    { id: '00000000-0000-4000-8000-000000000005', name: 'd', isVisible: true, parentID: IDS[2] }
  ];
  // Both at the root, or both inside the same group: allowed.
  assert.equal(checkOperation({ kind: 'group', ids: [IDS[0], IDS[1]] }, parented), '');
  assert.equal(checkOperation({ kind: 'group', ids: ['00000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000005'] }, parented), '');
  // A root layer and one inside a group: not siblings, so the editor refuses.
  assert.equal(checkOperation({ kind: 'group', ids: [IDS[0], '00000000-0000-4000-8000-000000000004'] }, parented), 'siblings');
  // A group and its own child are not siblings either.
  assert.equal(checkOperation({ kind: 'group', ids: [IDS[2], '00000000-0000-4000-8000-000000000004'] }, parented), 'siblings');
});

test('ids are put back to the spelling the project uses before they are sent', () => {
  // The editor matches ids exactly, so a re-cased id would come back as 'stale'.
  const grouped = canonicalOperation({ kind: 'group', ids: [IDS[0].toLowerCase(), IDS[1].toLowerCase()], name: 'G' }, layers);
  assert.deepEqual(grouped.ids, [IDS[0], IDS[1]]);
  assert.ok('id' in grouped, 'id stays present so the editor cannot retarget the operation');
  assert.equal(grouped.id, undefined);

  const parented = canonicalOperation({ kind: 'parent', id: IDS[0].toLowerCase(), parentID: IDS[2].toLowerCase() }, layers);
  assert.equal(parented.id, IDS[0]);
  assert.equal(parented.parentID, IDS[2]);

  const arranged = canonicalOperation({ kind: 'arrange', ids: [IDS[0].toLowerCase()], operation: 'left', reference: 'keyObject', keyID: IDS[1].toLowerCase() }, layers);
  assert.equal(arranged.keyID, IDS[1]);

  const created = canonicalOperation({ kind: 'styled', type: 'text', style: { content: 'x' } }, layers);
  assert.ok('id' in created);
  assert.equal(created.id, undefined);

  // An id that is not in the project is left unresolved, and then refused.
  assert.equal(canonicalOperation({ kind: 'delete', id: 'nope' }, layers).id, undefined);
  assert.equal(checkOperation({ kind: 'delete', id: 'nope' }, layers), 'layer');
  // Operations that already use exact ids are untouched.
  assert.equal(canonicalOperation({ kind: 'rename', id: IDS[0], name: 'N' }, layers).id, IDS[0]);
});

test('a text layer is normalised into everything the renderer needs', () => {
  const document = { width: 1920, height: 1080 };
  const built = styledStyle('text', { content: '标题 / Title', fontSize: 96, alignment: 'Center', red: .2 }, document);
  assert.deepEqual(built.style, {
    content: '标题 / Title', fontName: 'ArialMT', fontSize: 96,
    red: .2, green: 1, blue: 1, alignment: 'Center', tracking: 0, leading: 0,
    boxSize: [600, 300], colorRuns: [], fontRuns: []
  });
  // A box the model asks for is honoured, and clamped to what can be rendered.
  assert.deepEqual(styledStyle('text', { content: 'x', boxSize: [400, 120] }, document).style.boxSize, [400, 120]);
  const huge = styledStyle('text', { content: 'x', boxSize: [30000, 30000] }, document).style.boxSize;
  assert.ok(huge[0] * huge[1] <= 16_000_000, 'the box must stay inside the render budget');
  const tiny = styledStyle('text', { content: 'x', boxSize: [1, 1] }, document).style.boxSize;
  assert.deepEqual(tiny, [16, 16], 'every side has a floor of 16');

  assert.equal(styledStyle('text', { content: '' }, document).error, 'content');
  assert.equal(styledStyle('text', { content: '   ' }, document).error, 'content');
  assert.equal(styledStyle('text', { content: 'x', fontSize: 5000 }, document).error, 'fontSize');
  assert.equal(styledStyle('text', { content: 'x', red: 5 }, document).error, 'colour');
  assert.equal(styledStyle('text', { content: 'x', tracking: 99999 }, document).error, 'spacing');
  // An unknown alignment falls back rather than failing the whole request.
  assert.equal(styledStyle('text', { content: 'x', alignment: 'Justify' }, document).style.alignment, 'Left');
  assert.equal(styledStyle('blob', {}, document).error, 'type');
});

test('a shape layer is normalised the same way', () => {
  const document = { width: 1920, height: 1080 };
  assert.deepEqual(styledStyle('shape', {}, document).style, {
    kind: 'Rectangle', red: 1, green: 1, blue: 1, cornerRadius: 0, lineWidth: 0,
    start: [0, 0], end: [1, 1], boxSize: [600, 300]
  });
  const line = styledStyle('shape', { kind: 'Line', lineWidth: 8, start: [.1, .1], end: [.9, .9], boxSize: [200, 200] }, document).style;
  assert.equal(line.kind, 'Line');
  assert.equal(line.lineWidth, 8);
  assert.deepEqual(line.start, [.1, .1]);
  assert.equal(styledStyle('shape', { kind: 'Star' }, document).style.kind, 'Rectangle');
  assert.equal(styledStyle('shape', { lineWidth: -5 }, document).error, 'shape');
  // Out-of-range unit coordinates fall back instead of being passed through.
  assert.deepEqual(styledStyle('shape', { start: [5, 5] }, document).style.start, [0, 0]);
});

test('a styled operation may create a layer or restyle one, and is checked either way', () => {
  const create = { kind: 'styled', type: 'text', style: { content: 'Hi' } };
  assert.equal(checkOperation(create, layers), '');
  // With an id it restyles, and that id has to exist.
  assert.equal(checkOperation({ ...create, id: IDS[0] }, layers), '');
  assert.equal(checkOperation({ ...create, id: IDS[0].toLowerCase() }, layers), '');
  assert.equal(checkOperation({ ...create, id: 'not-a-layer' }, layers), 'layer');
  assert.equal(checkOperation({ ...create, type: 'blob' }, layers), 'type');
  assert.equal(checkOperation({ ...create, style: { content: '' } }, layers), 'content');
  assert.equal(checkOperation({ ...create, style: { content: 'x', fontSize: 9000 } }, layers), 'fontSize');
  assert.equal(checkOperation({ ...create, style: { content: 'x', red: -1 } }, layers), 'style');
  assert.equal(checkOperation({ ...create, origin: [1] }, layers), 'value');
  assert.equal(checkOperation({ ...create, origin: [10, 20] }, layers), '');
  // Both forms survive the checker with the style the panel will render.
  const checked = checkOperations([create], layers);
  assert.deepEqual(checked.rejected, []);
  assert.equal(checked.accepted.length, 1);
});

test('an endpoint must be https, or plain http on the loopback only', () => {
  assert.equal(checkEndpoint('https://api.deepseek.com/v1'), '');
  assert.equal(checkEndpoint('http://127.0.0.1:11434/v1'), '');
  assert.equal(checkEndpoint('http://localhost:1234/v1'), '');
  // Sending a key in clear text to a remote host is refused.
  assert.equal(checkEndpoint('http://api.example.com/v1'), 'endpoint');
  assert.equal(checkEndpoint('ftp://example.com'), 'endpoint');
  assert.equal(checkEndpoint('not a url'), 'endpoint');
  assert.equal(checkEndpoint(''), 'endpoint');
  assert.equal(checkEndpoint('https://example.com/' + 'a'.repeat(400)), 'endpoint');
  assert.equal(checkModel('deepseek-flash'), '');
  assert.equal(checkModel(''), 'model');
  assert.equal(checkModel('x'.repeat(200)), 'model');
});

test('settings round-trip, and the stored key is never handed back', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'comp-ai-'));
  t.after(() => rm(directory, { recursive: true, force: true }));

  assert.deepEqual(await getAiSettings(directory), { endpoint: 'https://api.deepseek.com/v1', model: 'deepseek-flash', key: '' });

  const saved = await setAiSettings(directory, { endpoint: 'https://example.com/v1', model: 'my-model', key: 'encrypted-blob' });
  assert.deepEqual(saved, { endpoint: 'https://example.com/v1', model: 'my-model', key: 'set' });
  assert.deepEqual(await getAiSettings(directory), { endpoint: 'https://example.com/v1', model: 'my-model', key: 'encrypted-blob' });

  await assert.rejects(() => setAiSettings(directory, { endpoint: 'http://remote.example.com', model: 'm', key: '' }), /Invalid endpoint/);
  await assert.rejects(() => setAiSettings(directory, { endpoint: 'https://example.com', model: '', key: '' }), /Invalid model/);
  // The rejected writes left the good file in place.
  assert.equal((await getAiSettings(directory)).model, 'my-model');

  // A damaged file falls back to the defaults instead of throwing.
  await writeFile(path.join(directory, 'ai-settings.json'), '{ not json');
  assert.equal((await getAiSettings(directory)).endpoint, 'https://api.deepseek.com/v1');
  await writeFile(path.join(directory, 'ai-settings.json'), JSON.stringify({ endpoint: 'http://remote.example.com', model: 'm', key: 'x' }));
  assert.equal((await getAiSettings(directory)).endpoint, 'https://api.deepseek.com/v1');

  // The file is written whole and never in place.
  const raw = await readFile(path.join(directory, 'ai-settings.json'), 'utf8');
  assert.deepEqual(Object.keys(JSON.parse(raw)).sort(), ['endpoint', 'key', 'model']);
});
