import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { decodeSourceImage } from '../packages/platform/image-pipeline.mjs';
import { readProject, pngDimensions } from '../packages/comp-bridge/project.mjs';
import { placement, editProject } from '../packages/comp-bridge/edit.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { RecoveryStore, saveProject } from '../packages/platform/save-project.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';

async function original() {
  return sharp({ create: { width: 2, height: 3, channels: 4, background: { r: 180, g: 100, b: 60, alpha: .5 } } })
    .withMetadata({ orientation: 6, density: 300 }).withIccProfile('p3').toColourspace('rgb16').png().toBuffer();
}
async function sample(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'comp-original-png-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const location = path.join(directory, 'original.comp'), id = randomUUID().toUpperCase(), bytes = await original();
  await mkdir(path.join(location, 'images'), { recursive: true });
  await writeFile(path.join(location, 'images', `${id}.png`), bytes);
  await writeFile(path.join(location, 'manifest.json'), JSON.stringify({ format: 'com.compositor.project', version: 17,
    documentID: randomUUID().toUpperCase(), colorSpace: 'sRGB', width: 3, height: 2, activeLayerID: id,
    layers: [{ id, name: 'Original PNG', imageFile: `${id}.png`, isVisible: true, transform: placement(3, 2) }] }));
  return { directory, location, id, bytes, data: await readProject(location) };
}

test('16-bit ICC PNG keeps immutable bytes while its edit proxy applies orientation and color management', async () => {
  const bytes = await original(); assert.equal(bytes[24], 16);
  assert.throws(() => pngDimensions(bytes), e => e.code === 'asset');
  const result = await decodeSourceImage(bytes);
  assert.equal(result.originalPNG, true); assert.deepEqual(result.bytes, bytes);
  assert.equal(result.width, 3); assert.equal(result.height, 2); assert.equal(result.proxyBytes[24], 8);
  const proxy = await sharp(result.proxyBytes).metadata(); assert.equal(proxy.orientation, undefined); assert.equal(proxy.icc, undefined);
  const rgba = codecs.decodePNG(result).data;
  for (let i = 0; i < rgba.length; i += 4) for (const [channel, expected] of [180, 100, 60, 128].entries()) assert.ok(Math.abs(rgba[i + channel] - expected) <= 3);
});

test('v17 transform, save, recovery, pixels and undo retain or replace the correct original resource', async t => {
  const { directory, id, bytes, data } = await sample(t), key = `images/${id}.png`;
  const moved = editProject(data, { kind: 'transform', id, field: 'origin', value: [12, 5] }, codecs);
  assert.deepEqual(moved.resources.get(key).bytes, bytes);
  const copy = path.join(directory, 'copy.comp'); await saveProject(moved, copy);
  assert.deepEqual(await readFile(path.join(copy, key)), bytes);
  const loaded = await readProject(copy); assert.deepEqual(loaded.resources.get(key).proxyBytes, moved.resources.get(key).proxyBytes);
  const recovery = new RecoveryStore(path.join(directory, 'recovery'));
  await recovery.write(moved, randomUUID()); const [snapshot] = await recovery.list();
  assert.deepEqual((await recovery.restore(snapshot.key)).resources.get(key).bytes, bytes);
  const session = new ProjectSession(undefined, { codecs }); session.install(loaded, copy, true);
  const pixels = codecs.decodePNG(loaded.resources.get(key)); pixels.data[0] = 0;
  assert.ok(session.edit(session.current.id, session.revision, { kind: 'pixels', id, png: codecs.encodePixels(pixels).bytes }).project);
  assert.equal(session.current.data.resources.get(key).proxyBytes, undefined);
  assert.notDeepEqual(session.current.data.resources.get(key).bytes, bytes);
  session.history(session.current.id, session.revision, 'undo'); assert.deepEqual(session.current.data.resources.get(key).bytes, bytes);
  session.close();
});

test('corrupt, multi-page and over-budget inputs do not produce editing proxies', async () => {
  await assert.rejects(() => decodeSourceImage(Buffer.from('not an image')), e => e.code === 'asset');
  await assert.rejects(() => decodeSourceImage(awaitablePNG, { maxPixels: 1 }), e => e.code === 'limit');
  const pages = await sharp([awaitablePNG, awaitablePNG], { join: { animated: true } }).tiff().toBuffer();
  await assert.rejects(() => decodeSourceImage(pages), e => e.code === 'asset');
});

const awaitablePNG = await sharp({ create: { width: 2, height: 2, channels: 4, background: '#ffffff' } }).png().toBuffer();
