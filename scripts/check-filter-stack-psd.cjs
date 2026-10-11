#!/usr/bin/env node
'use strict';
// Install ag-psd 31.0.2 and pngjs 7.0.0 in a separate temporary tool directory.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const [folder, dependencies] = process.argv.slice(2);
if (!folder || !dependencies) throw Error('Usage: node scripts/check-filter-stack-psd.cjs <evidence-folder> <dependency-directory>');
const load = createRequire(path.resolve(dependencies, 'package.json'));
const { readPsd, initializeCanvas } = load('ag-psd');
const { PNG } = load('pngjs');
initializeCanvas(() => { throw Error('Unexpected canvas allocation'); },
  (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }));
const psd = readPsd(fs.readFileSync(path.join(folder, 'filters.psd')),
  { useImageData: true, skipThumbnail: true, throwForMissingFeatures: true });
const png = PNG.sync.read(fs.readFileSync(path.join(folder, 'filters.png')));
assert.equal(psd.children.length, 1);
assert.equal(psd.width, png.width);
assert.equal(psd.height, png.height);
assert.equal(psd.children[0].left, 0);
assert.equal(psd.children[0].top, 0);
// An 8-bit white matte quantizes straight RGB at soft edges; compare the displayed premultiplied pixels.
let maximumDifference = 0;
for (let i = 0; i < png.data.length; i += 4) {
  assert.equal(psd.imageData.data[i + 3], png.data[i + 3], 'Merged alpha differs');
  for (let c = 0; c < 3; c++) {
    const a = Math.round(psd.imageData.data[i + c] * png.data[i + 3] / 255);
    const b = Math.round(png.data[i + c] * png.data[i + 3] / 255);
    maximumDifference = Math.max(maximumDifference, Math.abs(a - b));
  }
}
assert.ok(maximumDifference <= 1, `PSD merged visible pixels differ by ${maximumDifference}`);
assert.equal(psd.children[0].imageData.width, png.width);
let layerDifference = 0;
for (let i = 0; i < png.data.length; i += 4) {
  assert.equal(psd.children[0].imageData.data[i + 3], png.data[i + 3]);
  for (let c = 0; c < 3; c++) {
    layerDifference = Math.max(layerDifference, Math.abs(psd.children[0].imageData.data[i + c] - png.data[i + c]));
  }
}
assert.ok(layerDifference <= 1, `Layer RGB differs by ${layerDifference}`);
console.log(JSON.stringify({ reader: 'ag-psd 31.0.2', checks: 8, layers: psd.children.length,
  previewPixels: png.width * png.height, maximumDifference, layerDifference, result: 'passed' }, null, 2));
