import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { deflateSync } from 'node:zlib';

export const IDS = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003'];
export function png(w, h, color, gray = false) {
  const channels = gray ? 1 : 4, stride = w * channels + 1, data = Buffer.alloc(stride * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < channels; c++) data[y * stride + 1 + x * channels + c] = color[c];
  const crc = b => {
    let v = 0xffffffff;
    for (const byte of b) { v ^= byte; for (let i = 0; i < 8; i++) v = (v >>> 1) ^ (v & 1 ? 0xedb88320 : 0); }
    return (v ^ 0xffffffff) >>> 0;
  };
  const chunk = (name, b) => {
    const body = Buffer.concat([Buffer.from(name), b]), header = Buffer.alloc(4), footer = Buffer.alloc(4);
    header.writeUInt32BE(b.length); footer.writeUInt32BE(crc(body)); return Buffer.concat([header, body, footer]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = gray ? 0 : 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(data)), chunk('IEND', Buffer.alloc(0))]);
}
export function manifest() {
  const placement = { origin: [0, 0], size: [64, 48], rotation: 0, flipX: false, flipY: false, sampling: 'High quality' };
  return { format: 'com.compositor.project', version: 11, colorSpace: 'sRGB', documentID: IDS[2], width: 64, height: 48,
    layers: [
      { id: IDS[0], name: 'Coral / 珊瑚', isVisible: true, imageFile: IDS[0] + '.png', transform: structuredClone(placement) },
      { id: IDS[1], name: 'Mint / 薄荷', isVisible: true, opacity: .5, imageFile: IDS[1] + '.png', maskFile: IDS[1] + '.mask.png', transform: structuredClone(placement) }
    ] };
}
export async function fixture(directory, mutate = m => m) {
  await mkdir(path.join(directory, 'images'), { recursive: true });
  const m = mutate(manifest());
  await writeFile(path.join(directory, 'manifest.json'), JSON.stringify(m));
  await writeFile(path.join(directory, 'images', IDS[0] + '.png'), png(64, 48, [240, 160, 144, 255]));
  await writeFile(path.join(directory, 'images', IDS[1] + '.png'), png(64, 48, [120, 220, 180, 255]));
  await writeFile(path.join(directory, 'images', IDS[1] + '.mask.png'), png(1, 1, [128], true));
  return m;
}
