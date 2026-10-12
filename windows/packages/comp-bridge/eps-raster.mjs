import { ProjectError, LIMITS } from './project.mjs';

export const EPS_LIMITS = Object.freeze({ pixels: 16_000_000, bytes: 128 * 1024 ** 2 });
const ending = Buffer.from('grestore\nshowpage\n%%EOF\n');
const number = value => {
  const scaled = Math.round(value * 1_000_000);
  return `${Math.trunc(scaled / 1_000_000)}.${String(scaled % 1_000_000).padStart(6, '0')}`;
};
export function epsSize(w, h) {
  if (![w, h].every(v => Number.isInteger(v) && v > 0 && v <= LIMITS.side) || w * h > EPS_LIMITS.pixels) throw new ProjectError('epsLimit');
}
function header(w, h, dpi) {
  const pw = w * 72 / dpi, ph = h * 72 / dpi;
  return Buffer.from('%!PS-Adobe-3.0 EPSF-3.0\n%%Creator: Compositor Raster EPS 1\n' +
    `%%BoundingBox: 0 0 ${Math.ceil(pw)} ${Math.ceil(ph)}\n` +
    `%%HiResBoundingBox: 0 0 ${number(pw)} ${number(ph)}\n` +
    `%%LanguageLevel: 2\n%%Pages: 1\n%%CompositorRaster: ${w} ${h} ${number(dpi)}\n` +
    `%%EndComments\ngsave\n${number(pw)} ${number(ph)} scale\n/row ${w * 3 <= 65535 ? w * 3 : w} string def\n` +
    `${w} ${h} 8 [${w} 0 0 -${h} 0 ${h}]\n{currentfile row readhexstring pop} false 3 colorimage\n`);
}
export function encodeRasterEPS(image, resolution = 72) {
  const { width: w, height: h, data } = image;
  epsSize(w, h);
  const dpi = Number.isFinite(resolution) && resolution >= 1 && resolution <= 9600 ? Math.round(resolution * 1_000_000) / 1_000_000 : 72;
  const prefix = header(w, h, dpi), hex = Buffer.from('0123456789ABCDEF');
  const output = Buffer.alloc(prefix.length + w * h * 6 + Math.ceil(w * h * 3 / 36) + ending.length);
  prefix.copy(output); let at = prefix.length, column = 0;
  for (let i = 0; i < data.length; i += 4) {
    for (let c = 0; c < 3; c++) {
      // EPS has no alpha; flatten onto white before writing DeviceRGB samples.
      const v = Math.round((data[i + c] * data[i + 3] + 255 * (255 - data[i + 3])) / 255);
      output[at++] = hex[v >> 4]; output[at++] = hex[v & 15];
      if (++column === 36) { output[at++] = 10; column = 0; }
    }
  }
  if (column) output[at++] = 10;
  ending.copy(output, at);
  if (output.length > EPS_LIMITS.bytes) throw new ProjectError('epsLimit');
  return output;
}
export function postScriptSection(input) {
  const b = Buffer.from(input);
  if (!b.length || b.length > EPS_LIMITS.bytes) throw new ProjectError('epsLimit');
  if (b.length >= 4 && b.readUInt32LE(0) === 0xc6d3d0c5) {
    if (b.length < 30) throw new ProjectError('epsInvalid');
    const start = b.readUInt32LE(4), length = b.readUInt32LE(8);
    if (start < 30 || !length || start > b.length || length > b.length - start) throw new ProjectError('epsInvalid');
    return b.subarray(start, start + length);
  }
  return b;
}
export function decodeRasterEPS(input) {
  const b = postScriptSection(input), head = b.toString('ascii', 0, Math.min(b.length, 2048));
  if (!head.startsWith('%!PS-Adobe-3.0 EPSF-3.0\n%%Creator: Compositor Raster EPS 1\n')) return null;
  const fields = /^%%CompositorRaster: (\d+) (\d+) (\d+\.\d{6})$/m.exec(head);
  if (!fields) throw new ProjectError('epsInvalid');
  const w = Number(fields[1]), h = Number(fields[2]), dpi = Number(fields[3]);
  epsSize(w, h);
  if (!Number.isFinite(dpi) || dpi < 1 || dpi > 9600) throw new ProjectError('epsInvalid');
  const prefix = header(w, h, dpi);
  if (!b.subarray(0, prefix.length).equals(prefix) || !b.subarray(-ending.length).equals(ending)) throw new ProjectError('epsInvalid');
  const data = new Uint8ClampedArray(w * h * 4);
  let high = -1, at = 0, component = 0;
  for (let i = prefix.length; i < b.length - ending.length; i++) {
    const c = b[i]; if (c === 10) continue;
    const v = c >= 48 && c <= 57 ? c - 48 : c >= 65 && c <= 70 ? c - 55 : -1;
    if (v < 0 || at >= data.length) throw new ProjectError('epsInvalid');
    if (high < 0) high = v;
    else {
      data[at++] = (high << 4) | v; high = -1;
      if (++component === 3) { data[at++] = 255; component = 0; }
    }
  }
  if (high !== -1 || at !== data.length) throw new ProjectError('epsInvalid');
  return { width: w, height: h, data, resolution: dpi };
}
export function epsBounds(input) {
  const b = postScriptSection(input), first = b.toString('latin1', 0, Math.min(b.length, 65536));
  if (!/^%!PS-Adobe-[^\r\n]*EPSF-/.test(first)) throw new ProjectError('epsInvalid');
  const sections = [first, b.toString('latin1', Math.max(0, b.length - 65536))];
  for (const key of ['HiResBoundingBox', 'BoundingBox']) for (const section of sections) {
    for (const line of section.split(/\r\n|\r|\n/)) {
      if (!line.startsWith(`%%${key}:`)) continue;
      const values = line.slice(key.length + 3).trim().split(/\s+/).map(Number);
      if (values.length === 4 && values.every(v => Number.isFinite(v) && Math.abs(v) <= 1_000_000) && values[2] > values[0] && values[3] > values[1]) {
        const width = Math.ceil((values[2] - values[0]) * 2), height = Math.ceil((values[3] - values[1]) * 2);
        epsSize(width, height); return { width, height, x: values[0], y: values[1] };
      }
    }
  }
  throw new ProjectError('epsInvalid');
}
