import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, mkdir, readFile, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseManifest, readProject, analyze, pngDimensions, resourceDigests, writeSnapshotNew, BLEND_MODES } from '../packages/comp-bridge/project.mjs';
import { getLanguage, setLanguage } from '../packages/platform/preferences.mjs';
import { fixture, manifest, IDS, png } from './fixtures.mjs';

const encode = m => Buffer.from(JSON.stringify(m));
const rejects = (mutate, code = 'invalid') => { const m = manifest(); mutate(m); assert.throws(() => parseManifest(encode(m)), e => e.code === code); };
test('all supported versions accept a basic project without newer metadata', () => {
  for (let version = 1; version <= 13; version++) {
    const m = manifest(); m.version = version; delete m.layers[1].opacity; delete m.layers[1].maskFile;
    assert.equal(parseManifest(encode(m)).version, version);
  }
});
test('current blend enumeration has all 24 names', () => { assert.equal(BLEND_MODES.length, 24); assert.equal(new Set(BLEND_MODES).size, 24); });
test('unknown manifest/layer fields remain immutable and visible as unsupported', () => {
  const m = manifest(); m.future = { nested: ['keep', 123] }; m.layers[0].futureField = { answer: 42 };
  const parsed = parseManifest(encode(m)); assert.deepEqual(parsed, m); assert.ok(Object.isFrozen(parsed.layers[0]));
  assert.ok(analyze(parsed).issues.includes('unknown'));
});
test('unsupported version is rejected, never coerced', () => { rejects(m => m.version = 14, 'version'); rejects(m => m.version = 0, 'version'); });
test('unsafe image paths rejected', () => { for (const name of ['../x.png', 'C:\\secret.png', 'a.png', IDS[0] + '.PNG']) rejects(m => m.layers[0].imageFile = name); });
test('duplicate IDs are case-insensitive', () => rejects(m => m.layers[1].id = m.layers[0].id.toLowerCase()));
test('missing parents and cycles rejected', () => { rejects(m => m.layers[1].parentID = IDS[2]); rejects(m => { delete m.layers[0].imageFile; m.layers[0].isGroup = true; m.layers[0].parentID = IDS[0]; }); });
test('live mask references must exist and be acyclic', () => { rejects(m => m.layers[0].maskSourceID = IDS[2]); rejects(m => { m.layers[0].maskSourceID = IDS[1]; m.layers[1].maskSourceID = IDS[0]; }); });
test('invalid dimensions, opacity, color space and transform rejected', () => { rejects(m => m.width = 30001); rejects(m => m.width = 2.2); rejects(m => m.layers[0].opacity = -1); rejects(m => m.layers[0].transform.size = [0, 10]); rejects(m => m.colorSpace = 'Display P3', 'colorSpace'); });
test('version gates on masks and text runs', () => { rejects(m => m.version = 3); rejects(m => { m.version = 9; m.layers[0].text = { colorRuns: [] }; }); });
test('supported blends and clipping are renderable; malformed effects need fallback', () => {
  for (const mode of BLEND_MODES) { const m = manifest(); m.layers[0].blendMode = mode; assert.ok(!analyze(m).issues.includes('blend')); }
  const m = manifest(); m.layers[0].effects = { shadow: { unknownContour: 123 } }; assert.ok(analyze(m).issues.includes('effects'));
});
test('inherited visibility and pass-through opacity follow group ancestors', () => {
  const m = manifest(); m.layers.unshift({ id: IDS[2], name: 'Group', isVisible: false, isGroup: true, opacity: .4, transform: m.layers[0].transform });
  m.layers[2].parentID = IDS[2]; const r = analyze(m).rows.find(l => l.id === IDS[1]);
  assert.equal(r.effectiveVisible, false); assert.equal(r.effectiveOpacity, .2);
});
test('large canvases are reported, not silently downscaled', () => { const m = manifest(); m.width = 8192; m.height = 8192; assert.ok(analyze(m).issues.includes('memory')); assert.equal(m.width, 8192); });
test('placed full-canvas inputs count toward the memory budget', () => { const m = manifest(); m.width = 4000; m.height = 4000; assert.ok(analyze(m).issues.includes('memory')); });
test('PNG dimensions and mask bit depth validated before decoding', () => { assert.deepEqual(pngDimensions(png(2, 3, [255], true), true), { width: 2, height: 3 }); assert.throws(() => pngDimensions(png(2, 3, [0, 0, 0, 255]), true)); });
test('round trip preserves manifest bytes and ALL resources, refusing overwrite', async t => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-roundtrip-')); t.after(() => rm(temp, { recursive: true, force: true }));
  const original = path.join(temp, 'original.comp'), copy = path.join(temp, 'copy.comp');
  await fixture(original, m => { m.future = { version: 99 }; m.layers[0].futureFile = 'future/opaque.bin'; return m; });
  await mkdir(path.join(original, 'future')); await writeFile(path.join(original, 'future/opaque.bin'), Buffer.from([0, 3, 255]));
  const a = await readProject(original); await writeSnapshotNew(a, copy); const b = await readProject(copy);
  assert.deepEqual(a.manifest, b.manifest); assert.deepEqual(resourceDigests(a), resourceDigests(b)); assert.deepEqual(a.sourceBytes, b.sourceBytes);
  await assert.rejects(() => writeSnapshotNew(a, copy), e => e.code === 'EEXIST');
  assert.deepEqual(await readFile(path.join(original, 'manifest.json')), a.sourceBytes);
});
test('missing layer assets reject the whole load', async t => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-missing-')); t.after(() => rm(temp, { recursive: true, force: true }));
  const location = path.join(temp, 'sample.comp'); await fixture(location); await rm(path.join(location, 'images', IDS[0] + '.png'));
  await assert.rejects(() => readProject(location), e => e.code === 'missing');
});
test('directory junctions cannot redirect project resources', async t => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-link-')); t.after(() => rm(temp, { recursive: true, force: true }));
  const location = path.join(temp, 'sample.comp'); await fixture(location);
  await mkdir(path.join(temp, 'outside')); await symlink(path.join(temp, 'outside'), path.join(location, 'link'), 'junction');
  await assert.rejects(() => readProject(location), e => e.code === 'path');
});
test('language persists across fresh reads without retaining project paths', async t => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-settings-')); t.after(() => rm(temp, { recursive: true, force: true }));
  assert.equal(await getLanguage(temp), 'zh-Hans'); await setLanguage(temp, 'en'); assert.equal(await getLanguage(temp), 'en');
  await setLanguage(temp, 'zh-Hans'); assert.equal(await getLanguage(temp), 'zh-Hans');
  assert.deepEqual(JSON.parse(await readFile(path.join(temp, 'preferences.json'), 'utf8')), { language: 'zh-Hans' });
});

test('v12 fill, effects and vertical text stay preserved and require a cached preview', async t => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-v12-')); t.after(() => rm(temp, { recursive: true, force: true }));
  const source = path.join(temp, 'v12.comp'), copy = path.join(temp, 'copy.comp');
  await fixture(source, m => {
    m.version = 12; m.layers[0].fill = { kind: 'Linear', futureStops: ['keep'] };
    m.layers[0].effects = { gradientOverlay: { fill: { kind: 'Linear' }, opacity: .5 } };
    m.layers[1].text = { content: '中文', vertical: true, alignment: 'Justified' }; return m;
  });
  const original = await readProject(source); const report = analyze(original.manifest);
  assert.ok(report.issues.includes('unknown')); assert.ok(report.issues.includes('effects'));
  await writeSnapshotNew(original, copy); const saved = await readProject(copy);
  assert.deepEqual(saved.sourceBytes, original.sourceBytes);
  assert.deepEqual(saved.manifest, original.manifest);
  assert.deepEqual(resourceDigests(saved), resourceDigests(original));
});

test('v13 path and text layout records survive save, rename and older-version gates', async t => {
  const { editProject } = await import('../packages/comp-bridge/edit.mjs');
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-v13-')); t.after(() => rm(temp, { recursive: true, force: true }));
  const source = path.join(temp, 'v13.comp'), copy = path.join(temp, 'copy.comp');
  await fixture(source, m => {
    m.version = 13;
    m.layers[0].shape = { kind: 'Path', vector: { contours: [{ anchors: [{ point: [.1,.1], outgoing: [.3,0] }, { point: [.9,.9] }], closed: false }], future: 'retain' } };
    m.layers[1].text = { content: '中文', pathLayout: { path: structuredClone(m.layers[0].shape.vector), offset: 4, reversed: false } };
    m.layers[1].vectorMask = structuredClone(m.layers[0].shape.vector); return m;
  });
  const original = await readProject(source);
  assert.ok(analyze(original.manifest).issues.includes('unknown'));
  await writeSnapshotNew(original, copy); const saved = await readProject(copy);
  assert.deepEqual(saved.manifest, original.manifest);
  assert.deepEqual(resourceDigests(saved), resourceDigests(original));
  const renamed = editProject(original, { kind: 'rename', id: IDS[0], name: 'Renamed' });
  assert.equal(renamed.manifest.version, 13);
  assert.deepEqual(renamed.manifest.layers[0].shape, original.manifest.layers[0].shape);
  assert.deepEqual(renamed.manifest.layers[1].vectorMask, original.manifest.layers[1].vectorMask);
  const old = structuredClone(original.manifest); old.version = 12;
  assert.throws(() => parseManifest(encode(old)), e => e.code === 'invalid');
});
