import { ProjectError, LIMITS } from './project.mjs';

export function gifSize(w, h) {
  if (![w, h].every(v => Number.isInteger(v) && v > 0 && v <= LIMITS.side) || w * h > 16_000_000) throw new ProjectError('gifLimit');
}

// Validate block boundaries before entering a third-party decoder. GCE scope is
// one image, not every later image; omggif's retained GCE state is corrected below.
export function inspectGIF(bytes) {
  const invalid = () => { throw new ProjectError('gifInvalid'); };
  const word = p => bytes[p] | bytes[p + 1] << 8;
  if (bytes.length < 14 || !['GIF87a', 'GIF89a'].includes(bytes.toString('ascii', 0, 6))) invalid();
  const width = word(6), height = word(8); gifSize(width, height);
  let p = 13, palette_size = bytes[10] & 128 ? 1 << ((bytes[10] & 7) + 1) : 0;
  const palette_offset = palette_size ? p : null;
  p += palette_size * 3;
  if (p >= bytes.length) invalid();
  const frames = []; let loopCount = -1, control = null;
  const blocks = () => {
    const parts = [];
    while (p < bytes.length) {
      const n = bytes[p++]; if (!n) return parts;
      if (p + n >= bytes.length) invalid();
      parts.push(bytes.subarray(p, p + n)); p += n;
    }
    invalid();
  };
  while (p < bytes.length) {
    const marker = bytes[p++];
    if (marker === 0x3b) { if (!frames.length || p !== bytes.length) invalid(); return { width, height, frames, loopCount }; }
    if (marker === 0x21) {
      const label = bytes[p++], parts = blocks();
      if (label === 0xf9) {
        if (parts.length !== 1 || parts[0].length !== 4) invalid();
        const c = parts[0]; control = { delay: c[1] | c[2] << 8, disposal: c[0] >> 2 & 7, transparent_index: c[0] & 1 ? c[3] : null };
      } else if (label === 0xff) {
        if (parts[0]?.length !== 11) invalid();
        if (['NETSCAPE2.0', 'ANIMEXTS1.0'].includes(parts[0].toString('ascii'))) {
          if (parts[1]?.length !== 3 || parts[1][0] !== 1) invalid();
          loopCount = parts[1][1] | parts[1][2] << 8;
        }
      } else if (label === 0x01) throw new ProjectError('gifUnsupported');
      else if (label !== 0xfe) invalid();
      continue;
    }
    if (marker !== 0x2c || p + 10 >= bytes.length) invalid();
    const f = { x: word(p), y: word(p + 2), width: word(p + 4), height: word(p + 6), palette_offset, palette_size,
      interlaced: !!(bytes[p + 8] & 64), delay: 0, disposal: 0, transparent_index: null, ...control };
    const flags = bytes[p + 8]; p += 9;
    if (flags & 128) { f.palette_size = 1 << ((flags & 7) + 1); f.palette_offset = p; p += f.palette_size * 3; }
    if (p + 2 >= bytes.length) invalid();
    f.data_offset = p++; blocks(); f.data_length = p - f.data_offset;
    frames.push(f); control = null;
    if (frames.length > 500 || width * height * frames.length > 64_000_000) throw new ProjectError('gifLimit');
  }
  invalid();
}

// omggif reports short/long LZW streams with console warnings. Validate
// each frame's dictionary and exact output length before asking it to blit.
export function validateGIF(reader, bytes) {
  const invalid = () => { throw new ProjectError('gifInvalid'); };
  if (bytes[bytes.length - 1] !== 0x3b) invalid();
  for (let i = 0; i < reader.numFrames(); i++) {
    const f = reader.frameInfo(i);
    gifSize(f.width, f.height);
    if (f.x + f.width > reader.width || f.y + f.height > reader.height ||
        !f.palette_size || f.palette_offset == null || f.palette_offset + f.palette_size * 3 > bytes.length ||
        f.data_length < 3 || f.data_offset + f.data_length > bytes.length - 1 ||
        bytes[f.data_offset + f.data_length - 1] !== 0) invalid();
    if (f.disposal > 3 || f.transparent_index !== null && f.transparent_index >= f.palette_size) invalid();
    validateLZW(f, bytes);
  }
}

function validateLZW(frame, bytes) {
  const invalid = () => { throw new ProjectError('gifInvalid'); };
  const min = bytes[frame.data_offset];
  if (min < 2 || min > 8) invalid();
  let p = frame.data_offset + 1, remaining = 0, bits = 0, value = 0;
  const end = frame.data_offset + frame.data_length;
  function byte() {
    if (!remaining) {
      if (p >= end) return null;
      remaining = bytes[p++];
      if (!remaining) return null;
      if (p + remaining >= end) invalid();
    }
    remaining--; return bytes[p++];
  }
  function code(width) {
    while (bits < width) { const b = byte(); if (b === null) invalid(); value |= b << bits; bits += 8; }
    const result = value & ((1 << width) - 1); value >>>= width; bits -= width; return result;
  }
  const clear = 1 << min, stop = clear + 1, lengths = new Uint32Array(4096);
  let next = stop + 1, width = min + 1, previous = 0, count = 0;
  for (;;) {
    const c = code(width);
    if (c === clear) { next = stop + 1; width = min + 1; previous = 0; continue; }
    if (c === stop) { if (count !== frame.width * frame.height) invalid(); return; }
    let length;
    if (c < clear) { if (c >= frame.palette_size) invalid(); length = 1; }
    else if (c < next) length = lengths[c];
    else if (c === next && previous) length = previous + 1;
    else invalid();
    if (!length || count + length > frame.width * frame.height) invalid();
    count += length;
    if (previous && next < 4096) {
      lengths[next++] = previous + 1;
      if (next === 1 << width && width < 12) width++;
    }
    previous = length;
  }
}
