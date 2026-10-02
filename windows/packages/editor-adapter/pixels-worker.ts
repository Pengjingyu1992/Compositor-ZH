import { adjustedPixels, effectPixels } from './pixels.mjs';
self.onmessage = event => {
  try {
    const { id, image, adjustment, effects } = event.data;
    const result = adjustment ? adjustedPixels(image, adjustment) : effectPixels(image, effects);
    self.postMessage({ id, result }, { transfer: [result.data.buffer] });
  } catch { self.postMessage({ id: event.data.id, error: 'render' }); }
};
