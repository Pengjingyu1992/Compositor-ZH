import sharp from './native-imaging.mjs';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { ProjectError, LIMITS, pngDimensions } from '../comp-bridge/project.mjs';

export const OUTPUT_FORMATS = ['png', 'jpeg', 'tiff', 'webp', 'avif', 'pdf', 'cmyktiff'];
function number(value, low, high, fallback) {
  value ??= fallback;
  if (!Number.isFinite(value) || value < low || value > high) throw new ProjectError('invalid');
  return value;
}
export function validateCMYKProfile(value) {
  if (!(value instanceof Uint8Array) || value.byteLength < 128 || value.byteLength > 4 * 1024 ** 2) throw new ProjectError('asset');
  const bytes = Buffer.from(value);
  if (bytes.readUInt32BE(0) !== bytes.length || bytes.toString('ascii', 36, 40) !== 'acsp' || bytes.toString('ascii', 16, 20) !== 'CMYK') throw new ProjectError('asset');
  return bytes;
}
function pdfImage(jpeg, width, height, resolution, icc) {
  const pageWidth = width * 72 / resolution, pageHeight = height * 72 / resolution;
  const content = Buffer.from(`q ${pageWidth} 0 0 ${pageHeight} 0 0 cm /Im0 Do Q\n`);
  const stream = (dictionary, data) => Buffer.concat([Buffer.from(`<< ${dictionary} /Length ${data.length} >>\nstream\n`), data, Buffer.from('\nendstream')]);
  const objects = [Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'), Buffer.from('<< /Type /Pages /Count 1 /Kids [3 0 R] >>'),
    Buffer.from(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`),
    stream(`/Type /XObject /Subtype /Image /Width ${width} /Height ${height} /ColorSpace ${icc ? '[/ICCBased 6 0 R]' : '/DeviceRGB'} /BitsPerComponent 8 /Filter /DCTDecode`, jpeg), stream('', content)];
  if (icc) objects.push(stream('/N 3 /Alternate /DeviceRGB', icc));
  const parts = [Buffer.from('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n', 'latin1')], offsets = [0];
  let length = parts[0].length;
  objects.forEach((object, index) => { offsets.push(length); const part = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`), object, Buffer.from('\nendobj\n')]); parts.push(part); length += part.length; });
  parts.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map(n => `${String(n).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${length}\n%%EOF\n`));
  return Buffer.concat(parts);
}

export async function encodeOutputImage(value, options = {}) {
  if (!(value instanceof Uint8Array) || value.byteLength > LIMITS.asset || !OUTPUT_FORMATS.includes(options.format)) throw new ProjectError('invalid');
  const bytes = Buffer.from(value), dimensions = pngDimensions(bytes);
  if (dimensions.width * dimensions.height > 16_000_000) throw new ProjectError('limit');
  const quality = number(options.quality, 1, 100, 90), resolution = number(options.resolution, 1, 9600, 72), size = number(options.size, 0, LIMITS.side, 0);
  if (!Number.isInteger(quality) || !Number.isInteger(size)) throw new ProjectError('invalid');
  let width = dimensions.width, height = dimensions.height, temporary;
  if (size) { const ratio = size / Math.max(width, height); width = Math.max(1, Math.round(width * ratio)); height = Math.max(1, Math.round(height * ratio)); }
  if (width * height > 16_000_000) throw new ProjectError('limit');
  try {
    let image = sharp(bytes, { limitInputPixels: 16_000_000, failOn: 'warning' });
    // Float linear RGB avoids 8-bit premultiply truncation when resizing soft
    // transparency. Repeated resize must not progressively darken its colors.
    if(width!==dimensions.width||height!==dimensions.height){
      // Decode ICC before switching to the float pipeline. Keeping an input
      // profile attached here makes libvips interpret float samples as bytes.
      const decoded=await image.withIccProfile('srgb',{attach:false}).ensureAlpha().raw().timeout({seconds:20}).toBuffer({resolveWithObject:true});
      image=sharp(decoded.data,{raw:{width:decoded.info.width,height:decoded.info.height,channels:4}}).pipelineColourspace('scrgb');
    }
    image=image.resize(width,height).toColourspace('srgb').withMetadata({ density: resolution }).withIccProfile('srgb');
    const format = options.format;
    if (format === 'png') image = image.png();
    if (format === 'webp') image = image.webp({ quality, lossless: options.lossless === true });
    if (format === 'avif') image = image.avif({ quality, effort: 4 });
    if (format === 'tiff') image = image.tiff({ compression: 'lzw' });
    if (format === 'jpeg' || format === 'pdf') image = image.flatten({ background: '#ffffff' }).jpeg({ quality, chromaSubsampling: '4:4:4' });
    if (format === 'cmyktiff') {
      let profile = 'cmyk';
      if (options.profile) {
        const data = validateCMYKProfile(options.profile);
        temporary = await mkdtemp(path.join(os.tmpdir(), 'comp-icc-'));
        profile = path.join(temporary, 'output.icc'); await writeFile(profile, data, { mode: 0o600, flag: 'wx' });
      }
      image = image.flatten({ background: '#ffffff' }).toColourspace('cmyk').withIccProfile(profile).tiff({ compression: 'lzw' });
    }
    const encoded = await image.timeout({ seconds: 20 }).toBuffer();
    if (encoded.length > LIMITS.encoded) throw new ProjectError('limit');
    if (format === 'pdf') return pdfImage(encoded, width, height, resolution, (await sharp(encoded).metadata()).icc);
    return encoded;
  } catch (error) {
    if (error instanceof ProjectError) throw error;
    throw new ProjectError('asset');
  } finally { if (temporary) await rm(temporary, { recursive: true, force: true }); }
}

export async function printProof(value, profile) {
  const cmyk = await encodeOutputImage(value, { format: 'cmyktiff', ...(profile ? { profile } : {}) });
  return sharp(cmyk, { limitInputPixels: 16_000_000 }).withIccProfile('srgb', { attach: false }).toColourspace('srgb').png().timeout({ seconds: 20 }).toBuffer();
}
