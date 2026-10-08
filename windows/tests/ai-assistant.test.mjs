import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { ADJUSTMENT_KINDS, BLEND_MODES, EFFECT_KINDS } from '../packages/comp-bridge/capabilities.mjs';
import { systemPrompt, requestBody, readResponse, checkOperations, checkOperation, DEFAULT_MODEL } from '../packages/platform/ai-assistant.mjs';
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
