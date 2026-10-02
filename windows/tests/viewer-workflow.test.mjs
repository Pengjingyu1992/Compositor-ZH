import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { compatibilityReport } from '../packages/platform/compatibility-report.mjs';
import { visibleLayers } from '../packages/editor-adapter/layer-list.ts';
import { analyze } from '../packages/comp-bridge/project.mjs';
import { manifest, IDS } from './fixtures.mjs';

function data() {
  const m = manifest();
  return { name: 'personal-project-title.comp', manifest: m, analysis: analyze(m), sourceBytes: Buffer.from(JSON.stringify(m)), preview: false,
    resources: new Map([['images/' + IDS[0] + '.png', { bytes: Buffer.from('retained bytes'), mime: 'image/png' }]]) };
}
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
test('closing during folder selection prevents reading and reopening', async () => {
  const choice = deferred(); let reads = 0;
  const session = new ProjectSession(async () => { reads++; return data(); });
  const pending = session.open(() => choice.promise);
  session.close(); choice.resolve('selected.comp');
  assert.deepEqual(await pending, { canceled: true });
  assert.equal(reads, 0); assert.equal(session.current, null); assert.equal(session.pending, false);
});
test('closing during reading discards a late result and bounds parallel loads', async () => {
  const read = deferred(), began = deferred();
  const session = new ProjectSession(() => { began.resolve(); return read.promise; });
  const pending = session.open(() => 'selected.comp'); await began.promise;
  session.close();
  assert.deepEqual(await session.open(() => 'another.comp'), { error: 'busy' });
  read.resolve(data()); assert.deepEqual(await pending, { canceled: true }); assert.equal(session.current, null);
});
test('failed reload retains the current snapshot; successful reload has a new identity', async () => {
  let fail = false;
  const session = new ProjectSession(async () => { if (fail) throw Object.assign(new Error(), { code: 'missing' }); return data(); });
  const first = await session.open(() => 'selected.comp'); const before = session.current;
  fail = true; assert.deepEqual(await session.reload(first.project.id), { error: 'missing' }); assert.equal(session.current, before);
  fail = false; const second = await session.reload(first.project.id);
  assert.notEqual(second.project.id, first.project.id);
  assert.deepEqual(await session.reload(first.project.id), { error: 'stale' });
});
test('canceling a chooser retains the current project and resources', async () => {
  const session = new ProjectSession(async () => data()); await session.open(() => 'selected.comp');
  const before = session.current;
  assert.deepEqual(await session.open(() => null), { canceled: true }); assert.equal(session.current, before);
});
test('renderer project response contains no retained source path', async () => {
  const session = new ProjectSession(async () => data());
  const result = await session.open(() => 'private-location-marker');
  assert.equal(JSON.stringify(result).includes('private-location-marker'), false);
  assert.equal(session.current.location, 'private-location-marker'); session.close(); assert.equal(session.current, null);
});
test('compatibility report whitelists aggregate fields and excludes private metadata', () => {
  const project = data(); project.manifest.future = { token: 'private-metadata-marker' };
  project.manifest.layers[0].name = 'private-layer-marker';
  project.analysis = analyze(project.manifest);
  const report = compatibilityReport(project, '0.1.0-alpha.2', { source: 'none', issues: [] });
  const text = JSON.stringify(report);
  for (const secret of [project.name, 'private-layer-marker', 'private-metadata-marker', ...IDS]) assert.equal(text.includes(secret), false);
  assert.deepEqual(report.preview.reasons, ['unknown']); assert.equal(report.application.readOnly, true);
  assert.equal(report.project.layerCount, 2); assert.equal(report.resources.count, 1);
});
test('report validates display state and cannot claim absent saved previews', () => {
  const project = data();
  assert.equal(compatibilityReport(project, 'v', { source: 'saved', issues: [] }).preview.source, 'none');
  assert.equal(compatibilityReport(project, 'v', { source: 'engine', issues: ['gpu'] }).preview.source, 'none');
  assert.throws(() => compatibilityReport(project, 'v', { source: 'engine', issues: ['private-marker'] }));
  assert.throws(() => compatibilityReport(project, 'v', { source: 'invalid', issues: [] }));
});
function grouped() {
  const m = manifest();
  m.layers.unshift({ id: IDS[2], name: 'Collection', isGroup: true, isVisible: true, transform: m.layers[0].transform });
  m.layers[1].parentID = IDS[2]; m.layers[2].parentID = IDS[2];
  return analyze(m).rows;
}
test('layer list reverses siblings while keeping the group before its children', () => {
  assert.deepEqual(visibleLayers(grouped(), '', new Set()).map(l => l.id), [IDS[2], IDS[1], IDS[0]]);
});
test('group collapse is local and search temporarily reveals matching descendants', () => {
  const rows = grouped(), before = JSON.stringify(rows), collapsed = new Set([IDS[2]]);
  assert.deepEqual(visibleLayers(rows, '', collapsed).map(l => l.id), [IDS[2]]);
  assert.deepEqual(visibleLayers(rows, '薄荷', collapsed).map(l => l.id), [IDS[2], IDS[1]]);
  assert.deepEqual(visibleLayers(rows, 'COLLECTION', collapsed).map(l => l.id), [IDS[2], IDS[1], IDS[0]]);
  assert.equal(JSON.stringify(rows), before); assert.ok(collapsed.has(IDS[2]));
});
test('search is case-insensitive and an unmatched query shows no rows', () => {
  assert.deepEqual(visibleLayers(grouped(), 'mInT', new Set()).map(l => l.id), [IDS[2], IDS[1]]);
  assert.deepEqual(visibleLayers(grouped(), 'unmatched', new Set()), []);
});
