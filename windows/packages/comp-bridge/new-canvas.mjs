// Match the renderer/codec surface budget; do not allocate pixels in the form.
export const CANVAS_MAX_SIDE = 30_000;
export const CANVAS_MAX_PIXELS = 16_000_000;
export const CANVAS_UNITS = Object.freeze(['px', 'in', 'cm', 'mm']);
const perInch = { in: 1, cm: 2.54, mm: 25.4 };
export const CANVAS_PRESETS = Object.freeze([
  { group: 'screens', items: [
    { id: '4k', title: '4K', width: 3840, height: 2160 },
    { id: '1440p', title: '1440p', width: 2560, height: 1440 },
    { id: '1080p', title: '1080p', width: 1920, height: 1080 }
  ] },
  { group: 'devices', items: [
    { id: 'iphone-pro', title: 'iPhone 18 Pro', width: 1206, height: 2622 },
    { id: 'iphone-pro-max', title: 'iPhone 18 Pro Max', width: 1320, height: 2868 },
    { id: 'macbook-14', title: 'MacBook Pro 14″', width: 3024, height: 1964 },
    { id: 'macbook-16', title: 'MacBook Pro 16″', width: 3456, height: 2234 },
    { id: 'studio', title: 'Studio Display', width: 5120, height: 2880 }
  ] },
  { group: 'social', items: [
    { id: 'square', title: 'Instagram Square', width: 1080, height: 1080 },
    { id: 'portrait', title: 'Instagram Portrait', width: 1080, height: 1350 },
    { id: 'story', title: 'Instagram Story', width: 1080, height: 1920 },
    { id: 'youtube', title: 'YouTube Thumb', width: 1080, height: 608 }
  ] }
]);

export function canvasPixels(text, unit, resolution) {
  if (!CANVAS_UNITS.includes(unit) || !Number.isFinite(resolution) || resolution < 1 || resolution > 9600) return null;
  const normalized = String(text).trim().replaceAll(',', '.');
  if (!/^\+?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(normalized)) return null;
  const value = Number(normalized);
  if (!Number.isFinite(value) || value <= 0) return null;
  const pixels = unit === 'px' ? value : Math.round(value / perInch[unit] * resolution);
  return Number.isInteger(pixels) && pixels >= 1 && pixels <= CANVAS_MAX_SIDE ? pixels : null;
}

export function canvasDimensionText(pixels, unit, resolution) {
  return unit === 'px' ? String(pixels) : String(Number((pixels / resolution * perInch[unit]).toFixed(2)));
}

export function canvasCreation(width, height, options = {}) {
  const invalid = code => { const error = new Error(code); error.code = code; throw error; };
  if (!options || typeof options !== 'object' || Array.isArray(options) || Object.keys(options).some(key => !['resolution', 'background', 'backgroundName'].includes(key))) invalid('invalid');
  if (![width, height].every(n => Number.isInteger(n) && n >= 1 && n <= CANVAS_MAX_SIDE)) invalid('invalid');
  if (width * height > CANVAS_MAX_PIXELS) invalid('limit');
  const { resolution = 72, background = 'transparent', backgroundName = 'Background' } = options;
  if (!Number.isFinite(resolution) || resolution < 1 || resolution > 9600 || !['transparent', 'white', 'black'].includes(background) || typeof backgroundName !== 'string' || !backgroundName.trim() || backgroundName.length > 256) invalid('invalid');
  return { width, height, resolution, background, backgroundName };
}
