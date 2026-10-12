import { PNG } from 'pngjs';
import { readPsd, writePsdBuffer, getLayerImageData, getLayerMaskImageData, getCompositeImageData, initializeCanvas } from 'ag-psd';
import { randomUUID } from 'node:crypto';
import { pngDimensions, BLEND_MODES, ProjectError, LIMITS } from './project.mjs';
import { projectData, placement } from './edit.mjs';
import omggif from 'omggif';
import gifenc from 'gifenc';
import { encodeRasterEPS, decodeRasterEPS } from './eps-raster.mjs';
import { gifSize, inspectGIF, validateGIF } from './gif-validation.mjs';

const { GIFEncoder, quantize, applyPalette } = gifenc;

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
export function encodePixels(pixels, gray = false) {
  bound(pixels.width, pixels.height);
  const png = PNG.sync.write({ width: pixels.width, height: pixels.height, data: Buffer.from(pixels.data) }, { colorType: gray ? 0 : 6, inputColorType: 6, inputHasAlpha: true });
  if (png.length > LIMITS.asset) throw new ProjectError('limit');
  return { bytes: png, mime: 'image/png', width: pixels.width, height: pixels.height };
}
export function decodePNG(resource) {
  const dim=pngDimensions(resource.bytes,resource.bytes[25]===0);bound(dim.width,dim.height);
  const image=PNG.sync.read(resource.bytes,{checkCRC:true});return {...dim,data:new Uint8ClampedArray(image.data)};
}
export function validatePNG(value, mask = false) {
  const b = bytes(value), dim = pngDimensions(b,mask && b[25]===0); bound(dim.width, dim.height);
  const image = PNG.sync.read(b, { checkCRC: true });
  if (mask) {
    for (let i = 0; i < image.data.length; i += 4) image.data[i + 1] = image.data[i + 2] = image.data[i], image.data[i + 3] = 255;
    return encodePixels(image, true);
  }
  return { bytes: Buffer.from(b), mime: 'image/png', ...dim };
}
export function importPNG(value) {
  const b=bytes(value);
  if(b.length<33||!b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))||b.toString('ascii',12,16)!=='IHDR'||![1,2,4,8,16].includes(b[24])||![0,2,3,4,6].includes(b[25]))throw new ProjectError('asset');
  bound(b.readUInt32BE(16),b.readUInt32BE(20));
  // External PNGs may be grayscale, indexed or 16-bit. Stored assets are RGBA8.
  return encodePixels(PNG.sync.read(b,{checkCRC:true}));
}
function gifReader(value) {
  const b = bytes(value);
  if (b.length < 14 || !['GIF87a', 'GIF89a'].includes(b.toString('ascii', 0, 6))) throw new ProjectError('gifInvalid');
  gifSize(b.readUInt16LE(6), b.readUInt16LE(8));
  const info = inspectGIF(b);
  let reader;
  try { reader = new omggif.GifReader(b); } catch { throw new ProjectError('gifInvalid'); }
  if (reader.numFrames() !== info.frames.length) throw new ProjectError('gifInvalid');
  for (let i = 0; i < info.frames.length; i++) Object.assign(reader.frameInfo(i), info.frames[i]);
  reader.loopCount = () => info.loopCount;
  validateGIF(reader, b);
  return reader;
}
export function gifInfo(value) {
  const reader = gifReader(value);
  return { width: reader.width, height: reader.height, frames: reader.numFrames() };
}
function blitGIF(reader, index, data) {
  const frame = reader.frameInfo(index);
  if (!frame.interlaced) { reader.decodeAndBlitFrameRGBA(index, data); return; }
  // omggif advances only one interlace pass per row; short images can skip
  // past their bounds. Decode sequential rows, then apply all four GIF passes.
  const patch = new Uint8ClampedArray(data.length);
  frame.interlaced = false;
  try { reader.decodeAndBlitFrameRGBA(index, patch); }
  finally { frame.interlaced = true; }
  let sourceRow = 0;
  for (const [start, step] of [[0, 8], [4, 8], [2, 4], [1, 2]]) {
    for (let y = start; y < frame.height; y += step, sourceRow++) {
      let from = ((frame.y + sourceRow) * reader.width + frame.x) * 4;
      let to = ((frame.y + y) * reader.width + frame.x) * 4;
      for (let x = 0; x < frame.width; x++, from += 4, to += 4) {
        if (patch[from + 3]) data.set(patch.subarray(from, from + 4), to);
      }
    }
  }
}
export function importGIF(value, language = 'en') {
  const reader = gifReader(value), data = new Uint8ClampedArray(reader.width * reader.height * 4), input = bytes(value);
  const background = [0, 0, 0, 0];
  if (input[10] & 0x80) {
    const size = 1 << ((input[10] & 7) + 1), index = input[11];
    if (index < size && 13 + size * 3 <= input.length) background.splice(0, 4, input[13 + index * 3], input[14 + index * 3], input[15 + index * 3], 255);
  }
  if (reader.frameInfo(0).transparent_index === null) for (let at = 0; at < data.length; at += 4) data.set(background, at);
  const m = { format: 'com.compositor.project', version: 16, colorSpace: 'sRGB', documentID: randomUUID().toUpperCase(), width: reader.width, height: reader.height,
    layers: [], animation: { frames: [], loopCount: reader.loopCount() ?? -1 } }, resources = new Map();
  let encoded = 0;
  for (let i = 0; i < reader.numFrames(); i++) {
    const f = reader.frameInfo(i), previous = f.disposal === 3 ? data.slice() : null;
    blitGIF(reader, i, data);
    const groupID = randomUUID().toUpperCase(), id = randomUUID().toUpperCase(), imageFile = `${id}.png`;
    const resource = encodePixels({ width: reader.width, height: reader.height, data });
    encoded += resource.bytes.length; if (encoded > 192 * 1024 ** 2) throw new ProjectError('gifLimit');
    resources.set(`images/${imageFile}`, resource);
    m.layers.push({ id: groupID, name: `${language === 'zh-Hans' ? '帧' : 'Frame'} ${i + 1}`, isVisible: true, isGroup: true, transform: placement(m.width, m.height) },
      { id, name: `${language === 'zh-Hans' ? '帧' : 'Frame'} ${i + 1}`, parentID: groupID, isVisible: true, imageFile, transform: placement(m.width, m.height) });
    m.animation.frames.push({ groupID, durationMS: f.delay ? f.delay * 10 : 100 });
    m.activeLayerID ??= id;
    if (f.disposal === 2) {
      const fill = f.transparent_index === null ? background : [0, 0, 0, 0];
      for (let y = f.y; y < f.y + f.height; y++) for (let x = f.x; x < f.x + f.width; x++) data.set(fill, (y * reader.width + x) * 4);
    } else if (previous) data.set(previous);
  }
  return projectData(m, resources, 'Animation.comp');
}
export function exportGIF(payload) {
  const frames = payload.frames, gif = GIFEncoder();
  if (!Array.isArray(frames) || !frames.length || frames.length > 500 || !Number.isInteger(payload.loopCount) || payload.loopCount < -1 || payload.loopCount > 65535) throw new ProjectError('gifInvalid');
  let width, height, encoded = 0;
  for (const frame of frames) {
    if (!Number.isInteger(frame.durationMS) || frame.durationMS < 10 || frame.durationMS > 655350 || frame.durationMS % 10) throw new ProjectError('gifInvalid');
    const image = decodePNG({ bytes: bytes(frame.png) });
    width ??= image.width; height ??= image.height;
    if (image.width !== width || image.height !== height || width * height * frames.length > 64_000_000) throw new ProjectError('gifLimit');
    encoded += frame.png.byteLength; if (encoded > 192 * 1024 ** 2) throw new ProjectError('gifLimit');
    for (let at = 0; at < image.data.length; at += 4) {
      if (payload.keepTransparency !== false) {
        if (image.data[at + 3] < 128) image.data.fill(0, at, at + 4); else image.data[at + 3] = 255;
      } else {
        const alpha = image.data[at + 3];
        for (let c = 0; c < 3; c++) image.data[at + c] = Math.round((image.data[at + c] * alpha + 255 * (255 - alpha)) / 255);
        image.data[at + 3] = 255;
      }
    }
    // A transparent global background makes disposal 2 deterministic, even
    // when the first frame is opaque and a later frame introduces transparency.
    const palette = [[0, 0, 0, 0], ...quantize(image.data, 255, { format: 'rgba4444', oneBitAlpha: true }).filter(c => c[3] !== 0)];
    const indexed = applyPalette(image.data, palette, 'rgba4444');
    const transparentIndex = 0;
    gif.writeFrame(indexed, width, height, { palette, repeat: payload.loopCount, delay: frame.durationMS, dispose: 2,
      transparent: transparentIndex >= 0, transparentIndex: Math.max(0, transparentIndex) });
    if (gif.bytesView().length > 64 * 1024 ** 2) throw new ProjectError('gifLimit');
  }
  gif.finish(); return Buffer.from(gif.bytes());
}
export function importRasterEPS(value) {
  const image = decodeRasterEPS(value);
  return image ? { ...encodePixels(image), resolution: image.resolution } : null;
}
export function exportEPS(value, resolution = 72) {
  return encodeRasterEPS(decodePNG(validatePNG(value)), resolution);
}
export function blankPNG(w, h, mask, value = 0) {
  bound(w, h); const data = Buffer.alloc(w * h * 4);
  if (mask) for (let i = 0; i < data.length; i += 4) { data[i] = data[i + 1] = data[i + 2] = value; data[i + 3] = 255; }
  return encodePixels({ width: w, height: h, data }, mask);
}
export function invertMask(r) {
  const image = PNG.sync.read(r.bytes);
  for (let i = 0; i < image.data.length; i += 4) { image.data[i] = image.data[i + 1] = image.data[i + 2] = 255 - image.data[i]; image.data[i + 3] = 255; }
  return encodePixels(image, true);
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
      if (l.blendMode !== 'pass through' || l.effects || l.vectorMask) throw new ProjectError('psdConversion');
      row.isGroup = true; m.layers.push(row); visit(l.children, id);
    } else {
      const ranges = l.blendingRanges, normalRange = r => Array.isArray(r) && r.length === 4 && r.every((v,i) => v === [0,0,255,255][i]);
      const blendIf = ranges && (!normalRange(ranges.compositeGrayBlendSource) || !normalRange(ranges.compositeGraphBlendDestinationRange) || ranges.ranges.some(r => !normalRange(r.sourceRange) || !normalRange(r.destRange)));
      if (l.adjustment || l.effects || l.vectorMask || l.vectorFill || l.vectorStroke || l.filterMask || blendIf || l.placedLayer || l.smartFilters) throw new ProjectError('psdConversion');
      const image = getLayerImageData(l);
      if (image && image.width > 0 && image.height > 0) {
        row.imageFile = `${id}.png`; row.transform = { ...placement(image.width, image.height), origin: [l.left ?? 0, l.top ?? 0] };
        resources.set(`images/${row.imageFile}`, encodePixels(image));
        if (l.text) warnings.push('textRasterized');
      } else if (l.text) throw new ProjectError('psdConversion');
      else { row.imageFile = `${id}.png`; row.transform = placement(1, 1); resources.set(`images/${row.imageFile}`, blankPNG(1, 1, false)); }
      m.layers.push(row);
    }
    if (l.mask) {
      if (l.mask.positionRelativeToLayer || l.mask.userMaskDensity !== undefined || l.mask.userMaskFeather || l.mask.vectorMaskDensity !== undefined || l.mask.vectorMaskFeather || l.realMask) throw new ProjectError('psdConversion');
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
      resources.set(`images/${row.maskFile}`, encodePixels({ width: m.width, height: m.height, data }, true));
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
    resources.set(`images/${imageFile}`, encodePixels(image)); warnings.push('psdFlattened');
  } else visit(psd.children ?? []);
  if (!m.layers.length) throw new ProjectError('psdConversion');
  return { data: projectData(m, resources, 'Imported.comp'), warnings: [...new Set(warnings)] };
}
function pixels(value, w, h) {
  const r = validatePNG(value); if (w !== undefined && (r.width !== w || r.height !== h)) throw new ProjectError('invalid');
  const decoded = PNG.sync.read(r.bytes); return { width: r.width, height: r.height, data: new Uint8ClampedArray(decoded.data) };
}
export function exportPSD(data, payload) {
  const { width, height } = data.manifest;
  let layers = data.manifest.layers;
  if (data.manifest.animation) {
    const track = data.manifest.animation;
    if (!track.frames.some(f => f.groupID === payload.frameID)) throw new ProjectError('gifInvalid');
    const hidden = new Set(track.frames.filter(f => f.groupID !== payload.frameID).map(f => f.groupID));
    layers = layers.map(l => hidden.has(l.id) ? { ...l, isVisible: false } : l);
  }
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
    if (l.isGroup) ps.children = layers.filter(c => c.parentID?.toUpperCase() === l.id.toUpperCase()).map(convert);
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
    const siblings = layers.filter(s => s.parentID?.toUpperCase() === l.parentID?.toUpperCase()), index = siblings.indexOf(l);
    let i = index - 1; while (i >= 0 && siblings[i].maskSourceID) i--;
    if (i < 0 || siblings[i].id !== l.maskSourceID) throw new ProjectError('psdConversion');
  }
  return writePsdBuffer({ width, height, children: layers.filter(l => !l.parentID).map(convert), imageData: composite }, { noBackground: true, trimImageData: false });
}
