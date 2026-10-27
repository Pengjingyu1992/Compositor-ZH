import sharp from './native-imaging.mjs';
import { ProjectError, LIMITS } from '../comp-bridge/project.mjs';

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const input = value => {
  if (!(value instanceof Uint8Array) || !value.byteLength || value.byteLength > LIMITS.asset) throw new ProjectError('limit');
  return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
};
function rasterSignature(bytes) {
  return bytes.subarray(0, 8).equals(signature) || bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 ||
    ['II*\0', 'MM\0*', 'II+\0', 'MM\0+'].includes(bytes.toString('latin1', 0, 4)) ||
    bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP' ||
    bytes.toString('ascii', 4, 8) === 'ftyp' || bytes.toString('ascii', 4, 8) === 'jP  ' ||
    bytes[0] === 255 && bytes[1] === 79 && bytes[2] === 255 && bytes[3] === 81;
}

export async function decodeSourceImage(value, { preservePNG = true, maxPixels = 16_000_000 } = {}) {
  const bytes = input(value);
  if (!rasterSignature(bytes)) throw new ProjectError('asset');
  try {
    const image = sharp(bytes, { limitInputPixels: maxPixels, failOn: 'warning', animated: false });
    const metadata = await image.metadata();
    if (!metadata.width || !metadata.height || metadata.width > LIMITS.side || metadata.height > LIMITS.side || metadata.width * metadata.height > maxPixels) throw new ProjectError('limit');
    if (!['png', 'jpeg', 'webp', 'tiff', 'heif', 'jp2'].includes(metadata.format) || (metadata.pages ?? 1) > 1) throw new ProjectError('asset');
    // autoOrient applies EXIF before ICC conversion. The output has no original
    // orientation/profile tags: it is the actual sRGB, straight-alpha edit proxy.
    if (metadata.icc?.length > 4 * 1024 ** 2 || metadata.exif?.length > 1024 ** 2) throw new ProjectError('limit');
    const proxy = await image.autoOrient().withIccProfile('srgb', { attach: false }).toColourspace('srgb').ensureAlpha().png().timeout({ seconds: 15 }).toBuffer({ resolveWithObject: true });
    if (proxy.data.length > LIMITS.asset) throw new ProjectError('limit');
    const originalPNG = preservePNG && metadata.format === 'png' && bytes.subarray(0, 8).equals(signature);
    return { bytes: originalPNG ? Buffer.from(bytes) : proxy.data, ...(originalPNG ? { proxyBytes: proxy.data, originalPNG: true } : {}),
      mime: 'image/png', width: proxy.info.width, height: proxy.info.height,
      ...(Number.isFinite(metadata.density) && metadata.density >= 1 && metadata.density <= 9600 ? { resolution: metadata.density } : {}) };
  } catch (error) {
    if (error instanceof ProjectError) throw error;
    throw new ProjectError(/pixel limit|memory|too large/i.test(error.message) ? 'limit' : 'asset');
  }
}
