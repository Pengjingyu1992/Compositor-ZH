import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fixture, IDS } from './fixtures.mjs';
import { readProject } from '../packages/comp-bridge/project.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { runAssistant } from '../packages/platform/assistant-runner.mjs';
import { editRejection } from '../packages/platform/edit-command.mjs';
import { styledStyle, checkOperation, systemPrompt } from '../packages/platform/ai-assistant.mjs';
import { connectionSettings } from '../packages/platform/ai-settings.mjs';

const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function setup(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'comp-ai-regression-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const location = path.join(directory, 'sample.comp');
  await fixture(location);
  const session = new ProjectSession(undefined, { codecs });
  let project = session.install(await readProject(location), null, true).project;
  const events = [], calls = [];
  const state = { busy: false, painting: false, source: 'engine', issues: [] };
  const context = {
    prompt: 'Edit', getProject: () => project,
    complete: async () => ({ operations: [] }), prepare: async op => op,
    execute: async (op, owner) => {
      calls.push(op);
      const denied = editRejection(op, owner, project, state);
      const result = denied ? { error: denied } : session.edit(owner.id, owner.revision, op);
      if (result.project) project = result.project;
      return result;
    }, report: event => events.push(event)
  };
  return { session, events, calls, state, context, sync: () => { project = session.view().project; }, set: p => { project = p; } };
}

for (const action of ['switch', 'manual edit', 'close', 'reload']) test(`a delayed answer cannot commit after ${action}`, async t => {
  const s = await setup(t), reply = deferred();
  s.context.complete = () => reply.promise;
  const running = runAssistant(s.context);
  if (action === 'switch') s.set(s.session.create(8, 8).project);
  if (action === 'manual edit') { s.session.edit(s.session.current.id, s.session.revision, { kind: 'rename', id: IDS[0], name: 'Manual' }); s.sync(); }
  if (action === 'close') { s.session.close(); s.set(undefined); }
  if (action === 'reload') { s.session.install(s.session.current.data); s.sync(); }
  reply.resolve({ operations: [{ kind: 'canvas', width: 12, height: 12 }] });
  await running;
  assert.equal(s.calls.length, 0);
  assert.equal(s.events.at(-1).error, 'stale');
});

test('a delayed styled image is revision-bound as well as the model answer', async t => {
  const s = await setup(t), image = deferred(), started = deferred();
  s.context.complete = async () => ({ operations: [{ kind: 'styled', type: 'text', style: { content: 'Title' } }] });
  s.context.prepare = async op => { started.resolve(); await image.promise; return op; };
  const running = runAssistant(s.context);
  await started.promise;
  s.session.edit(s.session.current.id, s.session.revision, { kind: 'rename', id: IDS[0], name: 'Manual' }); s.sync();
  image.resolve(); await running;
  assert.equal(s.calls.length, 0);
  assert.equal(s.events.at(-1).error, 'stale');
});

test('mask add then invert is validated against each committed result', async t => {
  const s = await setup(t);
  s.context.complete = async () => ({ operations: [
    { kind: 'mask', id: IDS[0], action: 'add' }, { kind: 'mask', id: IDS[0], action: 'invert' }
  ] });
  await runAssistant(s.context);
  assert.equal(s.events.filter(e => e.type === 'applied').length, 2);
  const mask = s.session.current.data.resources.get(`images/${IDS[0]}.mask.png`);
  assert.equal(codecs.decodePNG(mask).data[0], 0);
});

test('deleting a target cannot turn a later restyle into a newly created layer', async t => {
  const s = await setup(t);
  s.context.complete = async () => ({ operations: [
    { kind: 'delete', id: IDS[0] }, { kind: 'styled', id: IDS[0], type: 'text', style: { content: 'Wrong' } }
  ] });
  await runAssistant(s.context);
  assert.equal(s.calls.length, 1);
  assert.equal(s.session.current.data.manifest.layers.length, 1);
  assert.equal(s.events.at(-1).reason, 'layer');
});

test('an image preparation failure is reported without claiming a commit', async t => {
  const s = await setup(t);
  s.context.complete = async () => ({ operations: [{ kind: 'styled', type: 'text', style: { content: 'Title' } }] });
  s.context.prepare = async () => { throw new Error('limit'); };
  await runAssistant(s.context);
  assert.equal(s.calls.length, 0);
  assert.equal(s.events.at(-1).type, 'rejected');
  assert.equal(s.events.at(-1).error, 'limit');
});

test('explicit targets remain explicit and each repeated failure is reported', async t => {
  const s = await setup(t);
  s.context.complete = async () => ({ operations: [{ kind: 'transform', id: IDS[1], field: 'origin', value: [10, 20] }] });
  await runAssistant(s.context);
  assert.deepEqual(s.session.current.data.manifest.layers[0].transform.origin, [0, 0]);
  assert.deepEqual(s.session.current.data.manifest.layers[1].transform.origin, [10, 20]);
  s.session.edit(s.session.current.id, s.session.revision, { kind: 'lock', id: IDS[0], field: 'content', value: true }); s.sync();
  s.events.length = 0;
  s.context.complete = async () => ({ operations: Array.from({ length: 2 }, () => ({ kind: 'filter', id: IDS[0], filter: 'Invert' })) });
  await runAssistant(s.context);
  assert.equal(s.events.filter(e => e.type === 'rejected' && e.error === 'locked').length, 2);
  assert.equal(s.events.filter(e => e.type === 'unchanged').length, 0);
});

test('GPU fallback, lost context, busy, and painting reject visual assistant edits', async t => {
  const s = await setup(t), owner = { id: s.session.current.id, revision: s.session.revision };
  for (const failure of [{ source: 'saved', issues: ['gpu'] }, { source: 'none', issues: ['gpu'] }, { busy: true }, { painting: true }]) {
    const state = { ...s.state, ...failure };
    assert.ok(editRejection({ kind: 'appearance' }, owner, s.context.getProject(), state));
  }
  assert.equal(editRejection({ kind: 'stroke' }, owner, s.context.getProject(), { ...s.state, painting: true }, true), '');
  assert.equal(editRejection({ kind: 'rename' }, owner, s.context.getProject(), { ...s.state, source: 'saved', issues: ['gpu'] }), '');
  s.state.source = 'saved'; s.state.issues = ['gpu'];
  const before = s.session.current.data, undo = s.session.undoStack.length;
  s.context.complete = async () => ({ operations: [{ kind: 'appearance', id: IDS[0], field: 'opacity', value: .1 }] });
  await runAssistant(s.context);
  assert.equal(s.events.at(-1).error, 'unsupported');
  assert.equal(s.session.current.data, before); assert.equal(s.session.undoStack.length, undo);
});

test('prompt examples match real adjustment, filter, and effect parameter storage', async t => {
  const s = await setup(t);
  const examples = systemPrompt({ layers: [], filters: [] }).split('\n').filter(l => ['filter','adjustment','effect'].some(k => l.startsWith('{"kind":"' + k + '"'))).map(l => JSON.parse(l.split('   //')[0]));
  let p = s.session.current.data;
  let result = s.session.edit(s.session.current.id, s.session.revision, { kind: 'add', type: 'adjustment', adjustment: 'Hue/Saturation', name: 'Adjust' });
  const id = result.project.manifest.layers.at(-1).id;
  const adjustment = { ...examples.find(o => o.kind === 'adjustment'), id, value: 37 };
  assert.equal(checkOperation(adjustment, result.project.manifest.layers), '');
  result = s.session.edit(s.session.current.id, s.session.revision, adjustment);
  assert.equal(result.project.manifest.layers.at(-1).adjustment.saturation, 37);
  const effect = { ...examples.find(o => o.kind === 'effect' && !o.remove), id: IDS[0], value: .73 };
  result = s.session.edit(s.session.current.id, s.session.revision, effect);
  assert.equal(result.project.manifest.layers[0].effects.shadow.opacity, .73);
  const filter = { ...examples.find(o => o.kind === 'filter'), id: IDS[0], filter: 'Gaussian Blur', settings: { radius: 20 } };
  assert.equal(checkOperation(filter, result.project.manifest.layers), '');
  assert.equal(checkOperation({ ...filter, radius: 20, settings: undefined }, result.project.manifest.layers), 'value');
  assert.equal(checkOperation({ ...filter, filter: 'Dither', settings: { levels: 4 } }, result.project.manifest.layers), '');
  assert.equal(s.session.edit(s.session.current.id, s.session.revision, filter).error, undefined);
  // Non-uniform pixels distinguish requested radii from the editor default.
  const image = { width: 32, height: 32, data: new Uint8ClampedArray(32 * 32 * 4) };
  for (let i = 3; i < image.data.length; i += 4) image.data[i] = 255;
  image.data[(16 * 32 + 16) * 4] = 255;
  const resource = codecs.encodePixels(image);
  s.session.current.data = { ...p, resources: new Map(p.resources).set(`images/${IDS[0]}.png`, resource) };
  const a = s.session.edit(s.session.current.id, s.session.revision, { ...filter, settings: { radius: 1 } });
  assert.ok(a.project);
  const one = s.session.current.data.resources.get(`images/${IDS[0]}.png`).bytes;
  s.session.history(s.session.current.id, s.session.revision, 'undo');
  const b = s.session.edit(s.session.current.id, s.session.revision, { ...filter, settings: { radius: 8 } });
  assert.ok(b.project);
  assert.notDeepEqual(s.session.current.data.resources.get(`images/${IDS[0]}.png`).bytes, one);
});

test('restyling inherits fonts, boxes, and UTF-16 runs until explicitly changed', () => {
  const original = { content: '标题 AB', fontName: 'MicrosoftYaHei', fontSize: 90, red: .1, green: .2, blue: .3, alignment: 'Right', tracking: 2, leading: 110, boxSize: [800, 200], colorRuns: [{ location: 3, length: 2, red: 1, green: 0, blue: 0 }], fontRuns: [{ location: 0, length: 2, fontName: 'SimSun' }] };
  assert.deepEqual(styledStyle('text', {}, null, original).style, original);
  const changed = styledStyle('text', { content: '标题 ABC' }, null, original).style;
  assert.equal(changed.fontName, original.fontName); assert.deepEqual(changed.boxSize, original.boxSize);
  assert.deepEqual(changed.fontRuns, original.fontRuns); assert.equal(changed.colorRuns[0].length, 3);
  assert.deepEqual(styledStyle('text', { red: .9 }, null, original).style.fontRuns, original.fontRuns);
  assert.deepEqual(styledStyle('text', { red: .9 }, null, original).style.colorRuns, []);
});

test('connection tests use unsaved drafts and never carry a key to another provider', () => {
  const current = { endpoint: 'https://example.com/v1', model: 'old', key: 'old-key' };
  assert.deepEqual(connectionSettings({ endpoint: 'http://127.0.0.1:1234/v1', model: 'new', key: 'draft-key' }, current), { endpoint: 'http://127.0.0.1:1234/v1', model: 'new', key: 'draft-key' });
  assert.equal(connectionSettings({ endpoint: current.endpoint, model: 'new', key: '' }, current).key, 'old-key');
  assert.equal(connectionSettings({ endpoint: 'https://other.example/v1', model: 'new', key: '' }, current).error, 'nokey');
  assert.equal(connectionSettings({ endpoint: 42, model: {}, key: '' }, current).error, 'settings');
  assert.deepEqual(current, { endpoint: 'https://example.com/v1', model: 'old', key: 'old-key' });
});
