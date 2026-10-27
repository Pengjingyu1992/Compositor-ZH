import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import sharp from 'sharp';
import { encodeOutputImage, printProof, validateCMYKProfile } from '../packages/platform/image-output.mjs';

const source = await sharp({ create: { width: 8, height: 4, channels: 4, background: { r: 180, g: 60, b: 100, alpha: .5 } } }).png().toBuffer();
const directory = fileURLToPath(new URL('../playwright-report/codec-fixtures/image-output/', import.meta.url));
await mkdir(directory, { recursive: true });
for (const format of ['png', 'jpeg', 'webp', 'avif', 'tiff', 'cmyktiff']) test(`${format} output preserves dimensions, ICC and its declared channels`, async () => {
  const output = await encodeOutputImage(source, { format, resolution: 300, quality: 95, lossless: true });
  const metadata = await sharp(output).metadata();
  assert.equal(metadata.width, 8); assert.equal(metadata.height, 4); assert.ok(metadata.icc?.length);
  if (format === 'cmyktiff') { assert.equal(metadata.space, 'cmyk'); assert.equal(metadata.channels, 4); assert.equal(metadata.hasAlpha, false); validateCMYKProfile(metadata.icc); }
  else assert.equal(metadata.hasAlpha, format !== 'jpeg');
  await writeFile(path.join(directory, `sample.${format === 'cmyktiff' ? 'cmyk.tiff' : format}`), output);
});
test('long-edge resize retains aspect ratio and PDF carries its raster and print dimensions', async () => {
  const small = await encodeOutputImage(source, { format: 'png', size: 4 });
  const metadata = await sharp(small).metadata(); assert.equal(metadata.width, 4); assert.equal(metadata.height, 2);
  const pdf = await encodeOutputImage(source, { format: 'pdf', resolution: 144, quality: 95 });
  assert.equal(pdf.subarray(0, 8).toString(), '%PDF-1.4');
  assert.match(pdf.toString('latin1'), /\/MediaBox \[0 0 4 2\]/);
  await writeFile(path.join(directory, 'sample.pdf'), pdf);
});
test('JPEG composites alpha onto white and print proof is a nonmutating RGB conversion', async () => {
  const before = Buffer.from(source), jpeg = await encodeOutputImage(source, { format: 'jpeg', quality: 100 });
  const { data } = await sharp(jpeg).raw().toBuffer({ resolveWithObject: true });
  for (const [i, expected] of [217,157,177].entries()) assert.ok(Math.abs(data[i] - expected) <= 3);
  const proof = await printProof(source); const metadata = await sharp(proof).metadata();
  assert.equal(metadata.space, 'srgb'); assert.equal(metadata.width, 8); assert.equal(metadata.height, 4); assert.deepEqual(source, before);
});
test('a selected CMYK ICC is embedded and invalid profiles, inputs and allocations are rejected', async () => {
  const native = await encodeOutputImage(source, { format: 'cmyktiff' }), profile = (await sharp(native).metadata()).icc;
  const custom = await encodeOutputImage(source, { format: 'cmyktiff', profile }); assert.deepEqual((await sharp(custom).metadata()).icc, profile);
  assert.throws(() => validateCMYKProfile(Buffer.alloc(128)), e => e.code === 'asset');
  await assert.rejects(() => encodeOutputImage(source, { format: 'png', size: 30000 }), e => e.code === 'limit');
  await assert.rejects(() => encodeOutputImage(source, { format: 'png', quality: -1 }), e => e.code === 'invalid');
  await assert.rejects(() => encodeOutputImage(Buffer.from('not a PNG'), { format: 'pdf' }), e => e.code === 'asset');
  await assert.rejects(() => encodeOutputImage(source, { format: 'unknown' }), e => e.code === 'invalid');
});
