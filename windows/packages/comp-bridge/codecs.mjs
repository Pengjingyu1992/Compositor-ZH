import { PNG } from 'pngjs';
import { readPsd, writePsdBuffer, getLayerImageData, getLayerMaskImageData, getCompositeImageData, initializeCanvas } from 'ag-psd';
import { randomUUID } from 'node:crypto';
import { pngDimensions, BLEND_MODES, ProjectError, LIMITS } from './project.mjs';
import { projectData, placement } from './edit.mjs';

const bound = (w, h) => {
  if (![w, h].every(v => Number.isInteger(v) && v >= 1 && v <= LIMITS.side) || w * h > 16_000_000) throw new ProjectError('limit');
};
initializeCanvas(() => { throw new ProjectError('psdConversion'); }, (w, h) => {
  if (w || h) bound(w, h);
  return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) };
});
function bytes(v) {
  if (!(v instanceof Uint8Array) || v.byteLength > LIMITS.asset) throw new ProjectError('limit');
  return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
}
function encoded(pixels, gray = false) {
  bound(pixels.width, pixels.height);
  const png = PNG.sync.write({ width: pixels.width, height: pixels.height, data: Buffer.from(pixels.data) }, { colorType: gray ? 0 : 6, inputColorType: 6, inputHasAlpha: true });
  if (png.length > LIMITS.asset) throw new ProjectError('limit');
  return { bytes: png, mime: 'image/png', width: pixels.width, height: pixels.height };
}
export function validatePNG(value, mask = false) {
  const b = bytes(value), dim = pngDimensions(b); bound(dim.width, dim.height);
  const image = PNG.sync.read(b, { checkCRC: true });
  if (mask) {
    for (let i = 0; i < image.data.length; i += 4) image.data[i + 1] = image.data[i + 2] = image.data[i], image.data[i + 3] = 255;
    return encoded(image, true);
  }
  return { bytes: Buffer.from(b), mime: 'image/png', ...dim };
}
export function blankPNG(w, h, mask, value = 0) {
  bound(w, h); const data = Buffer.alloc(w * h * 4);
  if (mask) for (let i = 0; i < data.length; i += 4) { data[i] = data[i + 1] = data[i + 2] = value; data[i + 3] = 255; }
  return encoded({ width: w, height: h, data }, mask);
}
export function invertMask(r) {
  const image = PNG.sync.read(r.bytes);
  for (let i = 0; i < image.data.length; i += 4) { image.data[i] = image.data[i + 1] = image.data[i + 2] = 255 - image.data[i]; image.data[i + 3] = 255; }
  return encoded(image, true);
}
const PSD_MODES = ['normal', 'darken', 'multiply', 'color burn', 'linear burn', 'lighten', 'screen', 'color dodge', 'linear dodge', 'overlay', 'soft light', 'hard light', 'vivid light', 'linear light', 'pin light', 'hard mix', 'difference', 'exclusion', 'subtract', 'divide', 'hue', 'saturation', 'color', 'luminosity'];
function inspectPsd(psd) {
  bound(psd.width, psd.height);
  if (psd.bitsPerChannel !== 8 || psd.colorMode !== 3) throw new ProjectError('psdFormat');
  let count = 0, pixels = psd.width * psd.height;
  function visit(layers, depth = 0) {
    if (depth > 64 || !Array.isArray(layers)) throw new ProjectError('limit');
    for (const l of layers) {
      if (++count > 1000) throw new ProjectError('limit');
      if (l.mask) pixels += psd.width * psd.height;
      for (const box of [l, l.mask, l.realMask].filter(Boolean)) {
        const w = (box.right ?? box.left ?? 0) - (box.left ?? 0), h = (box.bottom ?? box.top ?? 0) - (box.top ?? 0);
        if (![w, h].every(v => Number.isInteger(v) && v >= 0 && v <= LIMITS.side) || w * h > 16_000_000) throw new ProjectError('limit');
        pixels += w * h;
      }
      if (pixels * 16 > 512 * 1024 ** 2) throw new ProjectError('limit');
      if (l.children) visit(l.children, depth + 1);
    }
  }
  visit(psd.children ?? []);
}
export function importPSD(value, flatten = false) {
  const input = bytes(value);
  if (input.length < 26 || input.toString('ascii', 0, 4) !== '8BPS' || input.readUInt16BE(4) !== 1) throw new ProjectError('psdFormat');
  const psd = readPsd(input, { useRawData: true, useImageData: true, useRawThumbnail: true, skipThumbnail: true, skipLinkedFilesData: true, totalMemoryLimit: 512 * 1024 ** 2 });
  inspectPsd(psd);
  const m = { format: 'com.compositor.project', version: 11, colorSpace: 'sRGB', documentID: randomUUID().toUpperCase(), width: psd.width, height: psd.height, layers: [] }, resources = new Map(), warnings = [];
  const addPixels = (l, parentID) => {
    const id = randomUUID().toUpperCase(), index = PSD_MODES.indexOf(l.blendMode ?? 'normal');
    if (index < 0 && !l.children) throw new ProjectError('psdConversion');
    const row = { id, name: String(l.name ?? 'Layer').slice(0, 256), isVisible: !l.hidden, opacity: l.opacity ?? 1, blendMode: l.children ? 'Normal' : BLEND_MODES[index], transform: placement(m.width, m.height) };
    if (parentID) row.parentID = parentID;
    if (l.children) {
      if (!['pass through', 'normal', undefined].includes(l.blendMode) || l.effects || l.vectorMask) throw new ProjectError('psdConversion');
      row.isGroup = true; m.layers.push(row); visit(l.children, id);
    } else {
      const ranges = l.blendingRanges, normalRange = r => Array.isArray(r) && r.length === 4 && r.every((v,i) => v === [0,0,255,255][i]);
      const blendIf = ranges && (!normalRange(ranges.compositeGrayBlendSource) || !normalRange(ranges.compositeGraphBlendDestinationRange) || ranges.ranges.some(r => !normalRange(r.sourceRange) || !normalRange(r.destRange)));
      if (l.adjustment || l.effects || l.vectorMask || l.vectorFill || l.vectorStroke || l.filterMask || blendIf || l.placedLayer || l.smartFilters) throw new ProjectError('psdConversion');
      const image = getLayerImageData(l);
      if (image && image.width > 0 && image.height > 0) {
        row.imageFile = `${id}.png`; row.transform = { ...placement(image.width, image.height), origin: [l.left ?? 0, l.top ?? 0] };
        resources.set(`images/${row.imageFile}`, encoded(image));
        if (l.text) warnings.push('textRasterized');
      } else if (l.text) throw new ProjectError('psdConversion');
      else { row.imageFile = `${id}.png`; row.transform = placement(1, 1); resources.set(`images/${row.imageFile}`, blankPNG(1, 1, false)); }
      m.layers.push(row);
    }
    if (l.mask) {
      if (l.mask.userMaskDensity !== undefined || l.mask.userMaskFeather || l.mask.vectorMaskDensity !== undefined || l.mask.vectorMaskFeather || l.realMask) throw new ProjectError('psdConversion');
      const image = getLayerMaskImageData(l);
      if (!image) throw new ProjectError('psdConversion');
      // PSD masks may use white outside their rectangle. Place them over a
      // document-sized grayscale surface so that defaultColor is conserved.
      const data = Buffer.alloc(m.width * m.height * 4);
      const defaultColor = l.mask.defaultColor ?? 0;
      for (let i = 0; i < data.length; i += 4) { data[i] = data[i + 1] = data[i + 2] = defaultColor; data[i + 3] = 255; }
      for (let y = 0; y < image.height; y++) for (let x = 0; x < image.width; x++) {
        const dx = x + (l.mask.left ?? 0), dy = y + (l.mask.top ?? 0);
        if (dx < 0 || dy < 0 || dx >= m.width || dy >= m.height) continue;
        const at = (dy * m.width + dx) * 4; data[at] = data[at + 1] = data[at + 2] = image.data[(y * image.width + x) * 4];
      }
      row.maskFile = `${id}.mask.png`; row.maskEnabled = !l.mask.disabled; row.maskLinked = false; row.maskPlacement = placement(m.width, m.height);
      resources.set(`images/${row.maskFile}`, encoded({ width: m.width, height: m.height, data }, true));
    }
    return row;
  };
  function visit(children, parentID) {
    let base;
    for (const layer of children) {
      const row = addPixels(layer, parentID);
      if (layer.clipping) { if (!base || row.isGroup) throw new ProjectError('psdConversion'); row.maskSourceID = base.id; }
      else base = row;
    }
  }
  if (flatten) {
    const image = getCompositeImageData(psd);
    if (!image) throw new ProjectError('psdConversion');
    const id = randomUUID().toUpperCase(), imageFile = `${id}.png`;
    m.layers.push({ id, imageFile, name: 'PSD composite', isVisible: true, transform: placement(m.width, m.height) });
    resources.set(`images/${imageFile}`, encoded(image)); warnings.push('psdFlattened');
  } else visit(psd.children ?? []);
  if (!m.layers.length) throw new ProjectError('psdConversion');
  return { data: projectData(m, resources, 'Imported.comp'), warnings: [...new Set(warnings)] };
}
function pixels(value, w, h) {
  const r = validatePNG(value); if (w !== undefined && (r.width !== w || r.height !== h)) throw new ProjectError('invalid');
  const decoded = PNG.sync.read(r.bytes); return { width: r.width, height: r.height, data: new Uint8ClampedArray(decoded.data) };
}
export function exportPSD(data, payload) {
  const { width, height, layers } = data.manifest;
  bound(width, height);
  let allocated = width * height * 24;
  const encodedInputs = [payload.composite, ...(payload.flatten ? [] : [...(payload.layers ?? []), ...(payload.masks ?? [])].map(v=>v.image))];
  for (const input of encodedInputs) {
    const b=bytes(input),d=pngDimensions(b);bound(d.width,d.height);
    allocated += d.width*d.height*16+b.length;
    if (allocated > 512 * 1024 ** 2) throw new ProjectError('limit');
  }
  const composite = pixels(payload.composite, width, height);
  if (payload.flatten) return writePsdBuffer({ width, height, imageData: composite }, { noBackground: true });
  if (!Array.isArray(payload.layers) || payload.layers.length !== layers.filter(l => l.imageFile).length || payload.layers.length * width * height * 8 > 512 * 1024 ** 2) throw new ProjectError('limit');
  if (layers.some(l => l.adjustment || l.effects && Object.values(l.effects).some(e => e.enabled !== false))) throw new ProjectError('psdConversion');
  const inputs = new Map(payload.layers.map(l => [l.id, l]));
  const convert = l => {
    const ps = { name: l.name, hidden: !l.isVisible, opacity: l.opacity ?? 1, blendMode: l.isGroup ? 'pass through' : PSD_MODES[BLEND_MODES.indexOf(l.blendMode ?? 'Normal')], top: 0, left: 0, bottom: height, right: width };
    if (l.isGroup) ps.children = layers.filter(c => c.parentID === l.id).map(convert);
    else if (l.imageFile) { const input = inputs.get(l.id); if (!input || !Number.isInteger(input.left) || !Number.isInteger(input.top) || Math.abs(input.left)>1_000_000 || Math.abs(input.top)>1_000_000) throw new ProjectError('invalid'); ps.imageData = pixels(input.image); ps.left=input.left; ps.top=input.top; ps.right=ps.left+ps.imageData.width; ps.bottom=ps.top+ps.imageData.height; }
    if (l.maskFile) {
      const value = payload.masks?.find(v => v.id === l.id);
      if (!value) throw new ProjectError('invalid');
      const imageData=pixels(value.image),left=value.left,top=value.top;
      if(!Number.isInteger(left)||!Number.isInteger(top)||Math.abs(left)>1_000_000||Math.abs(top)>1_000_000)throw new ProjectError('invalid');
      ps.mask = { top, left, bottom:top+imageData.height, right:left+imageData.width, disabled:l.maskEnabled===false, defaultColor:0, imageData };
    }
    if (l.maskSourceID) ps.clipping = true;
    return ps;
  };
  // PSD clipping is a contiguous sibling stack. Refuse unrelated relationships.
  for (const l of layers.filter(l => l.maskSourceID)) {
    const siblings = layers.filter(s => s.parentID === l.parentID), index = siblings.indexOf(l);
    let i = index - 1; while (i >= 0 && siblings[i].maskSourceID) i--;
    if (i < 0 || siblings[i].id !== l.maskSourceID) throw new ProjectError('psdConversion');
  }
  return writePsdBuffer({ width, height, children: layers.filter(l => !l.parentID).map(convert), imageData: composite }, { noBackground: true, trimImageData: false });
}
