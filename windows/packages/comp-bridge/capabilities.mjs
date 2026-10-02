export const ADJUSTMENT_KINDS = ['Hue/Saturation', 'Levels', 'Curves', 'Exposure', 'Gradient Map', 'Grain', 'Invert', 'Black & White', 'Color Balance', 'Gaussian Blur', 'Motion Blur', 'Add Noise'];
export const EFFECT_KINDS = ['stroke', 'shadow', 'colorOverlay', 'innerShadow', 'outerGlow', 'innerGlow'];
export const BLEND_MODES = ['Normal', 'Darken', 'Multiply', 'Color Burn', 'Linear Burn', 'Lighten', 'Screen', 'Color Dodge', 'Linear Dodge (Add)', 'Overlay', 'Soft Light', 'Hard Light', 'Vivid Light', 'Linear Light', 'Pin Light', 'Hard Mix', 'Difference', 'Exclusion', 'Subtract', 'Divide', 'Hue', 'Saturation', 'Color', 'Luminosity'];
const finite = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
const object = v => !!v && typeof v === 'object' && !Array.isArray(v);
const known = (v, keys) => object(v) && Object.keys(v).every(k => keys.includes(k));
const numbers = (v, specs) => Object.entries(specs).every(([k, [lo, hi]]) => v[k] === undefined || finite(v[k], lo, hi));
const color = v => known(v, ['red', 'green', 'blue']) && numbers(v, { red: [0, 1], green: [0, 1], blue: [0, 1] });
const flag = v => v === undefined || typeof v === 'boolean';
export function supportsAdjustment(a) {
  if (!known(a, ['kind', 'hue', 'saturation', 'lightness', 'colorize', 'levels', 'curves', 'exposureSettings', 'gradientMapSettings', 'grainSettings', 'blackWhiteSettings', 'colorBalanceSettings', 'blurRadius', 'motionAngle', 'motionDistance', 'noiseAmount', 'noiseGaussian', 'noiseMonochromatic', 'noiseSeed']) || !ADJUSTMENT_KINDS.includes(a.kind)) return false;
  if (!numbers(a, { hue: [-360, 360], saturation: [-100, 100], lightness: [-100, 100], blurRadius: [.1, 250], motionAngle: [-90, 90], motionDistance: [1, 2000], noiseAmount: [.1, 400], noiseSeed: [0, 4294967295] }) || ![a.colorize, a.noiseGaussian, a.noiseMonochromatic].every(flag)) return false;
  if (a.levels && (!known(a.levels, ['channel', 'ranges']) || !Array.isArray(a.levels.ranges) || a.levels.ranges.length !== 4 || !a.levels.ranges.every(r => known(r, ['black', 'white', 'gamma', 'outputBlack', 'outputWhite']) && numbers(r, { black: [0, 254], white: [1, 255], gamma: [.1, 9.99], outputBlack: [0, 255], outputWhite: [0, 255] }) && (r.black ?? 0) < (r.white ?? 255)))) return false;
  if (a.curves && (!known(a.curves, ['channel', 'channels']) || !Array.isArray(a.curves.channels) || a.curves.channels.length !== 4 || !a.curves.channels.every(p => Array.isArray(p) && p.length >= 2 && p.length <= 32 && p[0].x === 0 && p.at(-1).x === 255 && p.every((v, i) => known(v, ['x', 'y']) && finite(v.x, 0, 255) && finite(v.y, 0, 255) && (!i || v.x > p[i - 1].x))))) return false;
  const specs = {
    exposureSettings: { exposure: [-20, 20], offset: [-.5, .5], gamma: [.01, 9.99] },
    grainSettings: { amount: [0, 100], size: [.5, 20], roughness: [0, 100], seed: [0, 4294967295] },
    blackWhiteSettings: { reds: [-200, 300], yellows: [-200, 300], greens: [-200, 300], cyans: [-200, 300], blues: [-200, 300], magentas: [-200, 300], tintHue: [0, 360], tintSaturation: [0, 100] },
    colorBalanceSettings: Object.fromEntries(['shadow', 'mid', 'highlight'].flatMap(t => ['CyanRed', 'MagentaGreen', 'YellowBlue'].map(c => [t + c, [-100, 100]])))
  };
  for (const [k, spec] of Object.entries(specs)) if (a[k] && (!known(a[k], [...Object.keys(spec), 'tint', 'preserveLuminosity']) || !numbers(a[k], spec) || !flag(a[k].tint) || !flag(a[k].preserveLuminosity))) return false;
  const g = a.gradientMapSettings;
  if (g && (!known(g, ['shadows', 'highlights', 'reversed']) || (g.shadows && !color(g.shadows)) || (g.highlights && !color(g.highlights)) || !flag(g.reversed))) return false;
  return true;
}
export function supportsEffects(e) {
  if (!known(e, EFFECT_KINDS)) return false;
  return Object.entries(e).every(([k, v]) => {
    if (!known(v, ['enabled', 'red', 'green', 'blue', 'opacity', ...(k.includes('hadow') ? ['angle', 'distance', 'blur'] : k === 'colorOverlay' ? [] : ['size', ...(k === 'stroke' ? ['inside'] : [])])])) return false;
    return flag(v.enabled) && flag(v.inside) && numbers(v, { red: [0, 1], green: [0, 1], blue: [0, 1], opacity: [0, 1], size: [0, 500], angle: [-360, 360], distance: [0, 5000], blur: [0, 500] });
  });
}
