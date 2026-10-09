#!/usr/bin/env node
'use strict';
// Dependencies belong in a temporary tool directory, not the app's source tree.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const [folder, dependencyDirectory] = process.argv.slice(2);
if (!folder || !dependencyDirectory) throw Error('Usage: node scripts/check-editable-psd.cjs <fixture-folder> <dependency-directory>');
const load = createRequire(path.resolve(dependencyDirectory, 'package.json'));
const { readPsd, initializeCanvas } = load('ag-psd');
const { PNG } = load('pngjs');
initializeCanvas(() => { throw Error('Unexpected canvas allocation'); }, (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }));
const bytes = fs.readFileSync(path.join(folder, 'editable.psd'));
// A permissive reader accepts malformed block lengths that Photoshop rejects.
let offset = 26;
offset += 4 + bytes.readUInt32BE(offset);
offset += 4 + bytes.readUInt32BE(offset);
offset += 4;
assert.equal(bytes.readUInt32BE(offset) % 4, 0, 'Layer info must be aligned');
const count = Math.abs(bytes.readInt16BE(offset + 4));
offset += 6;
for (let i = 0; i < count; i++) {
  offset += 16;
  const channels = bytes.readUInt16BE(offset); offset += 2 + channels * 6;
  assert.ok(bytes[offset + 10] & 8, 'Layer flags must be meaningful');
  offset += 12;
  const end = offset + 4 + bytes.readUInt32BE(offset); offset += 4;
  offset += 4 + bytes.readUInt32BE(offset);
  offset += 4 + bytes.readUInt32BE(offset);
  offset += Math.ceil((1 + bytes[offset]) / 4) * 4;
  while (offset + 12 <= end) {
    const key = bytes.toString('ascii', offset + 4, offset + 8), size = bytes.readUInt32BE(offset + 8);
    assert.equal(size % 2, 0, `${key} declared length includes padding`);
    if (['luni', 'vmsk', 'vsms', 'GdFl', 'curv', 'vogk'].includes(key)) assert.equal(size % 4, 0, `${key} length alignment`);
    offset += 12 + size + size % 2;
  }
  assert.equal(offset, end, 'Layer extra data length');
}
const psd = readPsd(bytes, { useImageData: true, skipThumbnail: true, throwForMissingFeatures: true });
const flatten = layers => (layers || []).flatMap(l => [l, ...flatten(l.children)]);
const layers = flatten(psd.children);
const shape = layers.find(l => l.name === 'Bezier');
const text = layers.find(l => l.name === 'Editable Chinese');
const gradient = layers.find(l => l.name === 'Gradient');
assert.ok(shape?.vectorMask?.paths?.length, 'Editable vector path is missing');
assert.equal(shape.vectorMask.paths[0].knots.length, 4);
assert.ok(shape.vectorFill?.type === 'color', 'Vector solid fill is missing');
assert.equal(text?.text?.text, '叠绘 ABC');
assert.equal(text.text.shapeType, 'box');
assert.ok(text.text.styleRuns[0].style.font?.name && text.text.styleRuns[0].style.font.name !== 'Helvetica', 'Explicit CJK fallback font is missing');
assert.ok(text.text.styleRuns?.some(r => r.style.fillColor?.r === 255), 'Text color run is missing');
assert.ok(text.effects?.dropShadow?.length, 'Editable drop shadow is missing');
assert.ok(text.effects?.solidFill?.length, 'Editable color overlay is missing');
assert.equal(gradient?.vectorFill?.style, 'linear');
assert.equal(gradient.vectorFill.colorStops.length, 2);
assert.equal(gradient.vectorFill.opacityStops.length, 2);
assert.ok(layers.some(l => l.adjustment?.type === 'curves'), 'Curves adjustment is missing');
const png = PNG.sync.read(fs.readFileSync(path.join(folder, 'editable.png')));
assert.equal(psd.width, png.width); assert.equal(psd.height, png.height);
assert.equal(psd.imageData.data.length, png.data.length);
assert.deepEqual(Buffer.from(psd.imageData.data), png.data, 'Merged preview differs from the native export');
console.log(JSON.stringify({ reader: 'ag-psd 31.0.2', layers: layers.length, text: text.text.text,
  paths: shape.vectorMask.paths.length, colorRuns: text.text.styleRuns.length, gradient: gradient.vectorFill.type,
  previewPixels: png.width * png.height, checks: 'passed' }, null, 2));
