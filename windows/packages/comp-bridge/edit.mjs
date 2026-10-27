import { validateProjectFilters, copyFilterResources } from './editable-filters.mjs';
import { following } from './editor-math.mjs';
import { randomUUID } from 'node:crypto';
import { GLOBAL_OPS, selectionEdit, editorOperation, checkPermission } from './editor-ops.mjs';
import { parseManifest, analyze, LIMITS, ProjectError } from './project.mjs';
import { defaultFillStyle } from './layer-styles.mjs';
import { pruneOwnedResources } from './resource-ownership.mjs';

export const ADJUSTMENTS = ['Hue/Saturation', 'Levels', 'Curves', 'Exposure', 'Gradient Map', 'Grain', 'Invert', 'Black & White', 'Color Balance', 'Gaussian Blur', 'Motion Blur', 'Add Noise'];
export const EFFECTS = ['stroke', 'shadow', 'colorOverlay', 'innerShadow', 'outerGlow', 'innerGlow', 'gradientOverlay', 'patternOverlay', 'bevel'];
export const placement = (w, h) => ({ origin: [0, 0], size: [w, h], rotation: 0, flipX: false, flipY: false, sampling: 'High quality' });
const clone = v => structuredClone(v);
const fail = code => { throw new ProjectError(code); };
export function projectData(manifest, resources, name = 'Untitled.comp') {
  const sourceBytes = Buffer.from(JSON.stringify(manifest));
  const parsed = parseManifest(sourceBytes);
  let pixels = 0, masks = 0, encoded = sourceBytes.length;
  for (const r of resources.values()) encoded += r.bytes.length;
  if (encoded > LIMITS.encoded) fail('limit');
  for (const l of parsed.layers) for (const field of ['imageFile', 'maskFile']) {
    if (!l[field]) continue;
    const r = resources.get(`images/${l[field]}`);
    if (!r || !r.width || !r.height) fail('asset');
    if (field === 'imageFile') pixels += r.width * r.height; else masks += r.width * r.height;
  }
  pixels+=validateProjectFilters(parsed,resources);
  if (pixels > LIMITS.pixels || masks > LIMITS.pixels) fail('limit');
  return { manifest: parsed, resources, sourceBytes, name, preview: resources.has('QuickLook/Preview.jpg'), analysis: analyze(parsed, pixels, masks) };
}
export function newProject(w, h, resolution) {
  const manifest = { format: 'com.compositor.project', version: 11, documentID: randomUUID().toUpperCase(), colorSpace: 'sRGB', width: w, height: h, layers: [] };
  if (resolution !== undefined) manifest.resolution = resolution;
  return projectData(manifest, new Map());
}

function animationEdit(data, op, codecs) {
  const failAnimation = () => fail('gifLimit');
  if (data.analysis.issues.length) fail('unsupported');
  const m = clone(data.manifest), resources = new Map(data.resources);
  if ([op.name,op.layerName].some(v => v !== undefined && (typeof v !== 'string' || v.length > 256))) fail('invalid');
  const descendants = id => {
    const ids = new Set([id]);
    for (let n = 0; n < 64; n++) for (const l of m.layers) if (ids.has(l.parentID)) ids.add(l.id);
    return ids;
  };
  const blank = () => {
    const groupID = randomUUID().toUpperCase(), id = randomUUID().toUpperCase(), imageFile = `${id}.png`;
    resources.set(`images/${imageFile}`, codecs.blankPNG(m.width, m.height, false));
    return [{ id: groupID, name: 'Frame', isVisible: true, isGroup: true, transform: placement(m.width, m.height) },
      { id, name: op.layerName ?? 'Layer', parentID: groupID, isVisible: true, imageFile, transform: placement(m.width, m.height) }];
  };
  if (op.action === 'create') {
    if (m.animation) fail('invalid');
    if (m.width * m.height > 16_000_000) failAnimation();
    checkPermission(data, { kind: 'group', ids: m.layers.map(l => l.id) });
    const groupID = randomUUID().toUpperCase();
    for (const l of m.layers) if (!l.parentID) l.parentID = groupID;
    m.layers.unshift({ id: groupID, name: op.name ?? 'Frame 1', isVisible: true, isGroup: true, transform: placement(m.width, m.height) });
    m.animation = { frames: [{ groupID, durationMS: 100 }], loopCount: 0 };
    m.activeLayerID ??= groupID;
  } else {
    const track = m.animation;
    if (!track) fail('invalid');
    const index = track.frames.findIndex(f => f.groupID === op.frameID);
    if (op.action === 'loops') {
      if (!Number.isInteger(op.value) || op.value < -1 || op.value > 65535) fail('invalid');
      track.loopCount = op.value;
    } else {
      if (index < 0) fail('stale');
      const current = track.frames[index], ids = descendants(current.groupID);
      if (op.action === 'duration') {
        if (!Number.isInteger(op.value) || op.value < 10 || op.value > 655350 || op.value % 10) fail('invalid');
        current.durationMS = op.value;
      } else if (op.action === 'move') {
        if (![-1, 1].includes(op.direction) || !track.frames[index + op.direction]) fail('invalid');
        [track.frames[index], track.frames[index + op.direction]] = [track.frames[index + op.direction], track.frames[index]];
      } else if (op.action === 'delete') {
        if (track.frames.length < 2) fail('invalid');
        checkPermission(data, { kind: 'delete', id: current.groupID });
        m.layers = m.layers.filter(l => !ids.has(l.id));
        track.frames.splice(index, 1); m.activeLayerID = track.frames[Math.min(index, track.frames.length - 1)].groupID;
      } else if (['add', 'duplicate'].includes(op.action)) {
        if (track.frames.length >= 500 || m.width * m.height > 16_000_000 || m.width * m.height * (track.frames.length + 1) > 64_000_000) failAnimation();
        let added;
        if (op.action === 'duplicate') {
          const original = m.layers.filter(l => ids.has(l.id)), map = new Map(original.map(l => [l.id, randomUUID().toUpperCase()]));
          added = original.map(old => {
            const copy = clone(old); copy.id = map.get(old.id);
            if (copy.parentID) copy.parentID = map.get(copy.parentID) ?? copy.parentID;
            if (copy.maskSourceID) copy.maskSourceID = map.get(copy.maskSourceID) ?? copy.maskSourceID;
            for (const field of ['imageFile', 'maskFile']) if (copy[field]) {
              const file = `${copy.id}${field === 'maskFile' ? '.mask' : ''}.png`;
              resources.set(`images/${file}`, resources.get(`images/${copy[field]}`)); copy[field] = file;
            }
            copyFilterResources(copy,resources);return copy;
          });
        } else added = blank();
        const group = added.find(l => l.isGroup && !l.parentID), insertion = m.layers.reduce((n, l, i) => ids.has(l.id) ? i + 1 : n, 0);
        group.name = op.name ?? `Frame ${index + 2}`;
        m.layers.splice(insertion, 0, ...added);
        track.frames.splice(index + 1, 0, { groupID: group.id, durationMS: current.durationMS });
        m.activeLayerID = added.find(l => !l.isGroup)?.id ?? group.id;
      } else fail('invalid');
    }
  }
  m.version = Math.max(m.version, 16);
  resources.delete('QuickLook/Preview.jpg'); resources.delete('QuickLook/Thumbnail.png');
  pruneOwnedResources(data.manifest,m,resources);
  const result = projectData(m, resources, data.name);
  if (result.analysis.issues.length) fail(result.analysis.issues.includes('memory') ? 'limit' : 'unsupported');
  result.locks = data.locks; result.selection = data.selection;
  return result;
}

// Every operation builds a candidate. Validation precedes publication; failures
// cannot leave a partially edited document or consume redo history.
export function editProject(data, op, codecs) {
  if (!op || typeof op !== 'object' || typeof op.kind !== 'string') fail('invalid');
  if(op.kind==='filterStack'&&op.copy===true){
    const original=data.manifest.layers.find(layer=>layer.id===op.id);if(!original?.imageFile)fail('unsupported');
    checkPermission(data,{kind:'appearance',id:original.id});
    let candidate=editProject(data,{kind:'duplicate',id:original.id},codecs);const id=candidate.manifest.activeLayerID;
    if(original.text||original.shape||original.fill)candidate=editProject(candidate,{kind:'rasterize',id},codecs);
    candidate=editProject(candidate,{...op,id,copy:false},codecs);
    return editProject(candidate,{kind:'appearance',id:original.id,field:'isVisible',value:false},codecs);
  }
  if (op.kind === 'animation') return animationEdit(data, op, codecs);
  if (data.manifest.animation && ['delete', 'duplicate', 'duplicateTree', 'parent', 'ungroup', 'group', 'merge', 'reorder'].includes(op.kind)) {
    const frames = new Set(data.manifest.animation.frames.map(f => f.groupID));
    if ([op.id, ...(op.ids ?? [])].some(id => frames.has(id))) fail('unsupported');
  }
  checkPermission(data, op);
  if(data.analysis.issues.length && op.kind==='selection' && op.action==='wand')fail('unsupported');
  if (op.kind === 'selection') return selectionEdit(data, op, codecs);
  if (op.kind === 'lock') {
    if (!data.manifest.layers.some(l=>l.id===op.id) || !['all','content','position','appearance','alpha'].includes(op.field) || typeof op.value!=='boolean') fail('invalid');
    return {...data, locks:{...data.locks,[op.id]:{...data.locks?.[op.id],[op.field]:op.value}},contentSnapshot:data.contentSnapshot??data};
  }
  if (op.kind === 'batch') {
    if (!Array.isArray(op.operations) || !op.operations.length || op.operations.length > 512 || op.operations.some(v => v.kind === 'batch')) fail('invalid');
    return op.operations.reduce((candidate, operation) => editProject(candidate, operation, codecs), data);
  }
  const m = clone(data.manifest), resources = new Map(data.resources);
  const target = m.layers.find(l => l.id === op.id);
  const needsTarget = !['add', 'importPixels', ...GLOBAL_OPS].includes(op.kind) && !(['styled','fillLayer','path'].includes(op.kind) && !op.id);
  if (needsTarget && !target) fail('stale');
  if (data.analysis.issues.length && !['rename'].includes(op.kind)) fail('unsupported');
  const descendants = id => {
    const result = new Set([id.toUpperCase()]);
    for (let n = 0; n < 64; n++) for (const l of m.layers) if (result.has(l.parentID?.toUpperCase())) result.add(l.id.toUpperCase());
    return result;
  };
  const add = (kind, name) => {
    if (!['pixels', 'group', 'adjustment'].includes(kind) || typeof name !== 'string' || name.length > 256) fail('invalid');
    const id = randomUUID().toUpperCase(), l = { id, name, isVisible: true, transform: placement(m.width, m.height) };
    if (kind === 'group') l.isGroup = true;
    if (kind === 'adjustment') {
      if (!ADJUSTMENTS.includes(op.adjustment)) fail('invalid');
      l.adjustment = { kind: op.adjustment, hue: 0, saturation: 0, lightness: 0, colorize: false,
        levels: { channel: 'RGB', ranges: Array.from({ length: 4 }, () => ({ black: 0, white: 255, gamma: 1, outputBlack: 0, outputWhite: 255 })) },
        curves: { channel: 'RGB', channels: Array.from({ length: 4 }, () => [{ x: 0, y: 0 }, { x: 255, y: 255 }]) } };
    }
    if (kind === 'pixels') {
      l.imageFile = `${id}.png`;
      const r = op.kind === 'importPixels' ? codecs.importPNG(op.png) : codecs.blankPNG(m.width, m.height, false);
      if (r.width * r.height > 16_000_000) fail('limit');
      l.transform = placement(r.width, r.height);
      resources.set(`images/${l.imageFile}`, r);
    }
    if (op.parentID) { if (!m.layers.some(p => p.id === op.parentID && p.isGroup)) fail('invalid'); l.parentID = op.parentID; }
    m.layers.push(l); m.activeLayerID = id;
  };
  if (!editorOperation(data,m,resources,target,op,codecs,descendants)) switch (op.kind) {
    case 'add': add(op.type, op.name); break;
    case 'importPixels': add('pixels', op.name); break;
    case 'rename': if (typeof op.name !== 'string' || op.name.length > 256) fail('invalid'); target.name = op.name; break;
    case 'appearance': {
      if (!['opacity', 'blendMode', 'isVisible'].includes(op.field)) fail('invalid');
      target[op.field] = op.value; break;
    }
    case 'transform': {
      if (!['origin', 'size', 'rotation', 'flipX', 'flipY', 'sampling'].includes(op.field)) fail('invalid');
      if (target.isGroup) {
        if (op.field !== 'origin' || !Array.isArray(op.value) || op.value.length !== 2) fail('unsupported');
        const [dx, dy] = op.value.map((v, i) => v - target.transform.origin[i]);
        const moving = descendants(target.id);
        for (const l of m.layers) if (moving.has(l.id.toUpperCase())) {
          l.transform.origin = l.transform.origin.map((v, i) => v + (i === 0 ? dx : dy));
          if (l.maskPlacement && l.maskLinked !== false) l.maskPlacement.origin = l.maskPlacement.origin.map((v, i) => v + (i === 0 ? dx : dy));
        }
      } else {const before=clone(target.transform);target.transform[op.field]=clone(op.value);if(target.maskPlacement&&target.maskLinked!==false)target.maskPlacement=following(target.maskPlacement,before,target.transform);}
      break;
    }
    case 'delete': {
      const removed = descendants(target.id);
      m.layers = m.layers.filter(l => !removed.has(l.id.toUpperCase()));
      for (const l of m.layers) if (removed.has(l.maskSourceID?.toUpperCase())) delete l.maskSourceID;
      if (removed.has(m.activeLayerID?.toUpperCase())) delete m.activeLayerID;
      // Opaque files may be referenced by future fields. Keep them conservatively.
      break;
    }
    case 'duplicate': {
      if (target.isGroup) return editProject(data,{...op,kind:'duplicateTree'},codecs);
      const l = clone(target), id = randomUUID().toUpperCase(); l.id = id; l.name += ' (copy)';
      for (const field of ['imageFile', 'maskFile']) if (l[field]) {
        const old = l[field]; l[field] = `${id}${field === 'maskFile' ? '.mask' : ''}.png`;
        resources.set(`images/${l[field]}`, resources.get(`images/${old}`));
      }
      copyFilterResources(l,resources);
      m.layers.splice(m.layers.indexOf(target) + 1, 0, l); m.activeLayerID = id; break;
    }
    case 'reorder': {
      if (![1, -1].includes(op.direction)) fail('invalid');
      const siblings = m.layers.filter(l => l.parentID?.toUpperCase() === target.parentID?.toUpperCase()), i = siblings.indexOf(target), other = siblings[i + op.direction];
      if (!other) break;
      const a = m.layers.indexOf(target), b = m.layers.indexOf(other); [m.layers[a], m.layers[b]] = [m.layers[b], m.layers[a]]; break;
    }
    case 'parent': {
      if (op.parentID && (!m.layers.some(l => l.id.toUpperCase() === op.parentID.toUpperCase() && l.isGroup) || descendants(target.id).has(op.parentID.toUpperCase()))) fail('invalid');
      if (op.parentID) target.parentID = op.parentID; else delete target.parentID; break;
    }
    case 'clip': if (target.isGroup) fail('unsupported'); if (op.sourceID) target.maskSourceID = op.sourceID; else delete target.maskSourceID; break;
    case 'mask': {
      if (op.action === 'add') {
        if (target.maskFile) fail('invalid');
        const base = resources.get(`images/${target.imageFile}`), w = base?.width ?? m.width, h = base?.height ?? m.height;
        target.maskFile = `${target.id}.mask.png`; target.maskEnabled = true;
        resources.set(`images/${target.maskFile}`, codecs.blankPNG(w, h, true, op.black ? 0 : 255));
      } else if (op.action === 'remove') { for (const k of ['maskFile', 'maskEnabled', 'maskPlacement', 'maskLinked', 'vectorMask']) delete target[k]; }
      else if (target.maskFile && op.action === 'toggle') target.maskEnabled = target.maskEnabled === false;
      else if (target.maskFile && op.action === 'invert') { resources.set(`images/${target.maskFile}`, codecs.invertMask(resources.get(`images/${target.maskFile}`))); delete target.vectorMask; }
      else if (target.maskFile && op.action === 'link') {
        if (typeof op.value !== 'boolean') fail('invalid');
        target.maskLinked = op.value;
        if (!op.value && !target.maskPlacement) target.maskPlacement = clone(target.transform);
        if (op.value) delete target.maskPlacement;
      } else fail('invalid');
      break;
    }
    case 'pixels': {
      const mask = op.target === 'mask', file = mask ? target.maskFile : target.imageFile;
      if (!file || (!mask && (target.isGroup || target.adjustment))) fail('unsupported');
      const r = codecs.validatePNG(op.png, mask), before = resources.get(`images/${file}`);
      if (r.width !== before.width || r.height !== before.height) fail('invalid');
      const oldPixels=codecs.decodePNG(before),nextPixels=codecs.decodePNG(r);
      if(nextPixels.data.every((value,index)=>value===oldPixels.data[index]))break;
      if(!mask){let row=target;for(let n=0;row&&n<65;n++,row=m.layers.find(value=>value.id===row.parentID))if(data.locks?.[row.id]?.alpha&&nextPixels.data.some((value,index)=>index%4===3&&value!==oldPixels.data[index]))fail('locked');}
      resources.set(`images/${file}`, r);
      if (!mask) { delete target.text; delete target.shape; delete target.fill; delete target.editableFilters; } else delete target.vectorMask;
      break;
    }
    case 'adjustment': {
      if (!target.adjustment || !ADJUSTMENTS.includes(target.adjustment.kind)) fail('unsupported');
      const allowed = ['hue', 'saturation', 'lightness', 'colorize', 'levels', 'curves', 'exposureSettings', 'gradientMapSettings', 'grainSettings', 'blackWhiteSettings', 'colorBalanceSettings', 'blurRadius', 'motionAngle', 'motionDistance', 'noiseAmount', 'noiseGaussian', 'noiseMonochromatic', 'noiseSeed'];
      if (!allowed.includes(op.field)) fail('invalid');
      // Replace a known leaf, preserving unrelated and unknown properties.
      if (op.path) {
        if (!Array.isArray(op.path) || op.path.length > 4 || op.path.some(k => !/^(?:[A-Za-z][A-Za-z0-9]*|[0-9]{1,2})$/.test(String(k)) || ['constructor', 'prototype', '__proto__'].includes(k))) fail('invalid');
        let value = target.adjustment[op.field] ?? (target.adjustment[op.field] = {});
        for (const k of op.path.slice(0, -1)) value = value[k] ?? (value[k] = {});
        value[op.path.at(-1)] = clone(op.value);
      } else target.adjustment[op.field] = clone(op.value);
      break;
    }
    case 'effect': {
      if (target.isGroup || target.adjustment || !EFFECTS.includes(op.effect)) fail('unsupported');
      target.effects ??= {};
      if (op.remove) delete target.effects[op.effect];
      else {
        const v = target.effects[op.effect] ??= ['gradientOverlay','patternOverlay'].includes(op.effect) ? { enabled:true, opacity:1, fill:{...defaultFillStyle(),kind:op.effect==='gradientOverlay'?'Linear':'Pattern'} } : op.effect==='bevel' ? {enabled:true,size:8,depth:.75,angle:120} : { enabled: true, red: 0, green: 0, blue: 0, opacity: .5, ...(op.effect.includes('hadow') ? { angle: 135, distance: 10, blur: 8 } : op.effect === 'colorOverlay' ? {} : { size: 8, ...(op.effect === 'stroke' ? { inside: false } : {}) }) };
        if (op.field) { if (!['enabled', 'red', 'green', 'blue', 'opacity', 'size', 'inside', 'angle', 'distance', 'blur', 'fill', 'depth'].includes(op.field)) fail('invalid'); v[op.field] = clone(op.value); }
        if (['gradientOverlay','patternOverlay','bevel'].includes(op.effect)) m.version=Math.max(m.version,12);
      }
      break;
    }
    default: fail('invalid');
  }
  // An empty gesture must retain editable metadata, previews and save identity.
  pruneOwnedResources(data.manifest,m,resources);
  if(JSON.stringify(m)===JSON.stringify(data.manifest)&&resources.size===data.resources.size&&[...resources].every(([key,value])=>data.resources.get(key)===value))return data;
  // Windows only emits fields already defined by the current macOS schema.
  m.version = Math.max(m.version, 11);
  const dimensionsChanged=op.kind==='imageSize'&&(m.width!==data.manifest.width||m.height!==data.manifest.height);
  if (!['rename','resolution'].includes(op.kind) && !(op.kind==='imageSize'&&!dimensionsChanged)) { resources.delete('QuickLook/Preview.jpg'); resources.delete('QuickLook/Thumbnail.png'); }
  const result = projectData(m, resources, data.name);
  if (op.kind !== 'rename' && result.analysis.issues.length) fail(result.analysis.issues.includes('memory') ? 'limit' : 'unsupported');
  result.locks=data.locks;
  result.selection=op.kind==='canvas'||dimensionsChanged?null:data.selection;
  return result;
}
