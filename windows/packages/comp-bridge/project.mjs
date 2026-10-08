import { open, lstat, readdir, realpath, mkdir, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { supportsAdjustment, supportsEffects } from './capabilities.mjs';

export const LIMITS = Object.freeze({ manifest: 4 * 1024 ** 2, asset: 64 * 1024 ** 2, encoded: 256 * 1024 ** 2, pixels: 100_000_000, layers: 10_000, side: 30_000 });
export const BLEND_MODES = Object.freeze(['Normal', 'Darken', 'Multiply', 'Color Burn', 'Linear Burn', 'Lighten', 'Screen', 'Color Dodge', 'Linear Dodge (Add)', 'Overlay', 'Soft Light', 'Hard Light', 'Vivid Light', 'Linear Light', 'Pin Light', 'Hard Mix', 'Difference', 'Exclusion', 'Subtract', 'Divide', 'Hue', 'Saturation', 'Color', 'Luminosity']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KNOWN_LAYER = new Set(['id', 'name', 'isVisible', 'transform', 'imageFile', 'parentID', 'isGroup', 'opacity', 'blendMode', 'maskFile', 'maskEnabled', 'maskSourceID', 'adjustment', 'maskPlacement', 'maskLinked', 'shape', 'effects', 'text']);
const KNOWN_TOP = new Set(['format', 'version', 'colorSpace', 'resolution', 'documentID', 'width', 'height', 'activeLayerID', 'layers', 'guides']);
const KNOWN_TRANSFORM = new Set(['origin', 'size', 'rotation', 'flipX', 'flipY', 'sampling']);

export class ProjectError extends Error {
  constructor(code) { super(code); this.code = code; }
}
function requireValue(condition, code = 'invalid') { if (!condition) throw new ProjectError(code); }
function record(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
function finite(v, min, max) { return typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max; }
function optionalBool(v) { return v === undefined || typeof v === 'boolean'; }
function optionalID(v) { return v === undefined || (typeof v === 'string' && UUID.test(v)); }
function pair(v, min, max) { return Array.isArray(v) && v.length === 2 && v.every(n => finite(n, min, max)); }
function transform(v) {
  requireValue(record(v) && pair(v.origin, -1_000_000, 1_000_000) && pair(v.size, 1, 300_000) && finite(v.rotation, -Infinity, Infinity));
  requireValue(optionalBool(v.flipX) && optionalBool(v.flipY) && ['Nearest', 'Smooth', 'High quality'].includes(v.sampling));
}
function freezeDeep(v) {
  if (v && typeof v === 'object') { Object.values(v).forEach(freezeDeep); Object.freeze(v); }
  return v;
}

// Retain every source field. Rendering uses a separate, derived model.
export function parseManifest(bytes) {
  requireValue(bytes.byteLength <= LIMITS.manifest, 'limit');
  let m;
  try { m = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { throw new ProjectError('invalid'); }
  requireValue(record(m) && m.format === 'com.compositor.project');
  requireValue(Number.isInteger(m.version) && m.version >= 1 && m.version <= 12, 'version');
  requireValue(m.colorSpace === 'sRGB', 'colorSpace');
  requireValue(UUID.test(m.documentID) && optionalID(m.activeLayerID));
  requireValue([m.width, m.height].every(n => Number.isInteger(n) && n >= 1 && n <= LIMITS.side));
  requireValue(m.resolution === undefined || finite(m.resolution, 1, 9600));
  requireValue(Array.isArray(m.layers) && m.layers.length <= LIMITS.layers, 'limit');
  const ids = new Map();
  for (const l of m.layers) {
    requireValue(record(l) && typeof l.id === 'string' && UUID.test(l.id) && !ids.has(l.id.toUpperCase()));
    requireValue(typeof l.name === 'string' && l.name.length <= 65536 && typeof l.isVisible === 'boolean');
    requireValue(optionalBool(l.isGroup) && optionalBool(l.maskEnabled) && optionalBool(l.maskLinked));
    requireValue(optionalID(l.parentID) && optionalID(l.maskSourceID));
    requireValue(l.opacity === undefined || finite(l.opacity, 0, 1));
    requireValue(l.blendMode === undefined || BLEND_MODES.includes(l.blendMode));
    transform(l.transform);
    if (l.maskPlacement !== undefined) transform(l.maskPlacement);
    requireValue(l.imageFile === undefined || l.imageFile === `${l.id.toUpperCase()}.png`);
    requireValue(l.maskFile === undefined || l.maskFile === `${l.id.toUpperCase()}.mask.png`);
    requireValue(!l.isGroup || (!l.imageFile && !l.adjustment && !l.text && (l.blendMode ?? 'Normal') === 'Normal'));
    requireValue(!l.adjustment || (!l.imageFile && !l.text && record(l.adjustment)));
    requireValue(!(l.maskPlacement || l.maskLinked !== undefined || l.maskEnabled !== undefined) || !!l.maskFile);
    for (const key of ['text', 'shape', 'effects']) requireValue(l[key] === undefined || record(l[key]));
    // Honor format version gates rather than silently accepting a mislabeled document.
    requireValue(m.version >= 2 || (!l.parentID && !l.isGroup));
    requireValue(m.version >= 3 || ((l.opacity ?? 1) === 1 && (l.blendMode ?? 'Normal') === 'Normal'));
    requireValue(m.version >= 4 || !l.maskFile);
    requireValue(m.version >= 5 || !l.maskSourceID);
    requireValue(m.version >= 6 || !(l.isGroup && l.maskFile));
    requireValue(m.version >= 7 || !l.adjustment);
    requireValue(m.version >= 8 || !(l.isGroup && (l.opacity ?? 1) !== 1));
    requireValue(m.version >= 9 || !['Gaussian Blur', 'Motion Blur', 'Add Noise'].includes(l.adjustment?.kind));
    requireValue(m.version >= 10 || !l.text?.colorRuns);
    requireValue(m.version >= 11 || !l.text?.fontRuns);
    ids.set(l.id.toUpperCase(), l);
  }
  requireValue(m.activeLayerID === undefined || ids.has(m.activeLayerID.toUpperCase()));
  for (const l of m.layers) {
    const seen = new Set([l.id.toUpperCase()]);
    let p = l.parentID, depth = 0;
    while (p) {
      const key = p.toUpperCase(), parent = ids.get(key);
      requireValue(parent?.isGroup && !seen.has(key) && ++depth <= 64);
      seen.add(key); p = parent.parentID;
    }
    const masks = new Set([l.id.toUpperCase()]);
    let s = l.maskSourceID, chain = 0;
    while (s) {
      const key = s.toUpperCase(), source = ids.get(key);
      requireValue(source && !source.isGroup && !l.isGroup && !masks.has(key) && ++chain <= 256);
      masks.add(key); s = source.maskSourceID;
    }
  }
  if (m.guides !== undefined) {
    requireValue(m.version >= 8 && Array.isArray(m.guides) && m.guides.length <= 1000);
    for (const g of m.guides) requireValue(record(g) && UUID.test(g.id) && ['horizontal', 'vertical'].includes(g.axis) && finite(g.position, -1_000_000, 1_000_000));
  }
  return freezeDeep(m);
}

export function pngDimensions(b, mask = false) {
  requireValue(b.length >= 33 && b.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) && b.toString('ascii', 12, 16) === 'IHDR', 'asset');
  const w = b.readUInt32BE(16), h = b.readUInt32BE(20);
  requireValue(w >= 1 && h >= 1 && w <= LIMITS.side && h <= LIMITS.side && b[24] === 8 && (mask ? b[25] === 0 : [2, 6].includes(b[25])) && b[26] === 0 && b[27] === 0 && b[28] <= 1, 'asset');
  return { width: w, height: h };
}
export function jpegDimensions(b) {
  requireValue(b[0] === 255 && b[1] === 216, 'asset');
  let p = 2;
  while (p + 4 < b.length) {
    requireValue(b[p] === 255, 'asset');
    while (b[p] === 255) p++;
    const marker = b[p++];
    if (marker === 0xD9 || marker === 0xDA) break;
    const size = b.readUInt16BE(p);
    requireValue(size >= 2 && p + size <= b.length, 'asset');
    if ([0xC0, 0xC1, 0xC2].includes(marker)) {
      requireValue(size >= 8, 'asset');
      const h = b.readUInt16BE(p + 3), w = b.readUInt16BE(p + 5);
      requireValue(w > 0 && h > 0 && w * h <= 16_000_000, 'limit');
      return { width: w, height: h };
    }
    p += size;
  }
  throw new ProjectError('asset');
}
export async function safeDirectory(p) {
  // Windows TEMP may use an 8.3 short name. Validate ancestors as directory
  // entries, then canonicalize; string equality would reject legitimate paths.
  let current = path.resolve(p);
  while (true) {
    const st = await lstat(current);
    requireValue(st.isDirectory() && !st.isSymbolicLink(), 'path');
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return realpath(p);
}
export async function safeRead(p, limit) {
  const st = await lstat(p);
  requireValue(st.isFile() && !st.isSymbolicLink(), 'path');
  requireValue(st.size <= limit, 'limit');
  requireValue(path.resolve(p).toLowerCase() === (await realpath(p)).toLowerCase(), 'path');
  const handle = await open(p, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const before = await handle.stat();
    requireValue(before.isFile() && before.ino === st.ino && before.dev === st.dev && before.size === st.size, 'changed');
    const b = Buffer.alloc(st.size);
    let offset = 0;
    while (offset < b.length) {
      const { bytesRead } = await handle.read(b, offset, b.length - offset, offset);
      requireValue(bytesRead > 0, 'changed'); offset += bytesRead;
    }
    const after = await handle.stat();
    requireValue(after.size === before.size && after.mtimeMs === before.mtimeMs, 'changed');
    return b;
  } finally { await handle.close(); }
}
function parentID(l) { return l.parentID?.toUpperCase(); }
export function analyze(manifest, sourcePixels = 0, maskPixels = 0) {
  const issues = new Set();
  const rows = [];
  const children = new Map();
  for (const l of manifest.layers) {
    const k = parentID(l) ?? '';
    if (!children.has(k)) children.set(k, []);
    children.get(k).push(l);
  }
  const unknownTop = Object.keys(manifest).some(k => !KNOWN_TOP.has(k));
  if (unknownTop) issues.add('unknown');
  let pixelFallback = 0, previewOnly = 0, simple = 0;
  const visit = (parent, opacity, visible, depth) => {
    for (const l of children.get(parent) ?? []) {
      const shown = visible && l.isVisible, alpha = opacity * (l.opacity ?? 1);
      const unknown = Object.keys(l).some(k => !KNOWN_LAYER.has(k)) || Object.keys(l.transform).some(k => !KNOWN_TRANSFORM.has(k)) || Object.keys(l.maskPlacement ?? {}).some(k => !KNOWN_TRANSFORM.has(k));
      const reasons = [];
      if (unknown || l.text?.vertical === true || l.text?.alignment === 'Justified') reasons.push('unknown');
      if (l.adjustment && !supportsAdjustment(l.adjustment)) reasons.push('adjustment');
      if (l.effects && (!supportsEffects(l.effects) || l.isGroup || l.adjustment)) reasons.push('effects');
      // Adjustments and effects are now explicitly evaluated by the adapter.
      // Complex, noncontiguous live-alpha relationships require a saved preview.
      if (l.maskSourceID) {
        const siblings = children.get(parent) ?? [], index = siblings.indexOf(l), source = manifest.layers.find(s => s.id.toUpperCase() === l.maskSourceID.toUpperCase());
        const base = siblings.indexOf(source);
        if (!source?.imageFile || source.maskSourceID || source.parentID?.toUpperCase() !== l.parentID?.toUpperCase() || base < 0 || base >= index || siblings.slice(base + 1, index).some(s => s.maskSourceID?.toUpperCase() !== source.id.toUpperCase())) reasons.push('clipping');
      }
      if (shown && alpha > 0) reasons.forEach(r => issues.add(r));
      const category = reasons.length ? 'preview' : l.text || l.shape ? 'pixels' : 'simple';
      if (category === 'preview') previewOnly++; else if (category === 'pixels') pixelFallback++; else simple++;
      rows.push({ ...l, depth, effectiveVisible: shown, effectiveOpacity: alpha, category });
      if (l.isGroup) visit(l.id.toUpperCase(), alpha, shown, depth + 1);
    }
  };
  visit('', 1, true, 0);
  const canvasPixels = manifest.width * manifest.height;
  // Conservative peak estimate: three float targets, presentation/readback,
  // encoded resources, source canvases, uploaded textures, and flip copies.
  const placedInputs = rows.filter(l => l.effectiveVisible && l.effectiveOpacity > 0 && l.imageFile && !l.isGroup).reduce((n, l) => n + 1 + (l.maskFile && l.maskEnabled !== false ? 1 : 0), 0);
  // npm Pentrado 0.1.1 consumes full-canvas placed textures (unlike the newer
  // repository quad API). Include CPU and GPU copies of each placed input.
  const placedMasks = rows.filter(l => l.maskFile).length;
  const estimatedBytes = canvasPixels * (192 + placedInputs * 12 + placedMasks * 4) + sourcePixels * 8 + maskPixels * 8;
  if (canvasPixels > 16_000_000 || estimatedBytes > 768 * 1024 ** 2) issues.add('memory');
  return { rows, issues: [...issues], estimatedBytes, coverage: { simple, pixelFallback, previewOnly, total: rows.length } };
}

export async function readProject(root) {
  try {
    requireValue(typeof root === 'string' && path.extname(root).toLowerCase() === '.comp', 'path');
    root = await safeDirectory(root);
    const sourceBytes = await safeRead(path.join(root, 'manifest.json'), LIMITS.manifest);
    const manifest = parseManifest(sourceBytes);
    const resources = new Map();
    let bytes = sourceBytes.length, sourcePixels = 0, maskPixels = 0;
    const named = manifest.layers.flatMap(l => [l.imageFile, l.maskFile].filter(Boolean));
    if (named.length) await safeDirectory(path.join(root, 'images'));
    for (const name of named) {
      const b = await safeRead(path.join(root, 'images', name), LIMITS.asset);
      bytes += b.length;
      requireValue(bytes <= LIMITS.encoded, 'limit');
      const isMask = name.endsWith('.mask.png'), d = pngDimensions(b, isMask);
      if (isMask) maskPixels += d.width * d.height; else sourcePixels += d.width * d.height;
      requireValue(sourcePixels <= LIMITS.pixels && maskPixels <= LIMITS.pixels, 'limit');
      resources.set(`images/${name}`, { bytes: b, mime: 'image/png', ...d });
    }
    let preview = false;
    // A broken optional preview does not invalidate intact layer resources.
    try {
      await safeDirectory(path.join(root, 'QuickLook'));
      const b = await safeRead(path.join(root, 'QuickLook', 'Preview.jpg'), 32 * 1024 ** 2);
      requireValue(bytes + b.length <= LIMITS.encoded, 'limit');
      resources.set('QuickLook/Preview.jpg', { bytes: b, mime: 'image/jpeg', ...jpegDimensions(b) });
      bytes += b.length;
      preview = true;
    } catch { /* Optional; caller will show an explicit no-preview state. */ }
    // Preserve unrecognized resources too, including future additive fields.
    // Traversal is bounded and rejects links; resource names never select a path outside root.
    let files = 0;
    async function retain(directory, relative = '', depth = 0) {
      requireValue(depth <= 8, 'limit');
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        requireValue(!entry.isSymbolicLink() && !entry.name.includes('\\') && !entry.name.includes(':'), 'path');
        const name = relative ? `${relative}/${entry.name}` : entry.name;
        if (entry.isDirectory()) { await safeDirectory(path.join(directory, entry.name)); await retain(path.join(directory, entry.name), name, depth + 1); }
        else {
          requireValue(entry.isFile() && ++files <= 20_010, 'limit');
          if (name === 'manifest.json' || resources.has(name)) continue;
          const b = await safeRead(path.join(directory, entry.name), LIMITS.asset);
          bytes += b.length; requireValue(bytes <= LIMITS.encoded, 'limit');
          resources.set(name, { bytes: b, mime: 'application/octet-stream' });
        }
      }
    }
    await retain(root);
    // Never write into the opened package or retain its path in user settings.
    return { manifest, sourceBytes, resources, preview, name: path.basename(root), analysis: analyze(manifest, sourcePixels, maskPixels) };
  } catch (e) {
    if (e instanceof ProjectError) throw e;
    throw new ProjectError(e.code === 'ENOENT' ? 'missing' : 'read');
  }
}

// Stage-zero utility only: export a snapshot to a NEW directory for CI round trips.
// Not imported by the app's IPC handlers. No overwrite or editing support.
export async function writeSnapshotNew(project, destination) {
  await mkdir(destination); // EEXIST deliberately refuses overwrite.
  await mkdir(path.join(destination, 'images'));
  await writeFile(path.join(destination, 'manifest.json'), project.sourceBytes, { flag: 'wx' });
  for (const [name, resource] of project.resources) {
    await mkdir(path.dirname(path.join(destination, name)), { recursive: true });
    await writeFile(path.join(destination, name), resource.bytes, { flag: 'wx' });
  }
}
export function resourceDigests(project) {
  return Object.fromEntries([...project.resources].map(([name, r]) => [name, createHash('sha256').update(r.bytes).digest('hex')]));
}
