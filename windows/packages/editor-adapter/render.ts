import { createWebGLCompositor, type CompositeInput, type EffectiveMode } from 'pentrado/engine';
import type { Placement, ViewerProject } from '../../apps/desktop/renderer/types';

// Local adapter override; Pentrado's upstream defaults are unchanged.
export const NORMAL_MODE: EffectiveMode = Object.freeze({ blend: 'normal', blendSpace: 'perceptual', compositeSpace: 'perceptual', composite: 'union', legacy: false });

export function createPreviewRenderer() {
  const engine = createWebGLCompositor();
  let live = true, inputs: CompositeInput[] = [], output: HTMLCanvasElement | undefined;
  let lossTimer: ReturnType<typeof setTimeout> | undefined, restored = 0;
  const canvases: HTMLCanvasElement[] = [];
  function draw() {
    if (!live || !output) return;
    engine.beginFrame?.();
    engine.composite(inputs);
    const surface = engine.getCanvas();
    const gpu = surface?.getContext('webgl2') as WebGL2RenderingContext | null;
    if (!gpu || gpu.isContextLost()) throw new Error('gpu');
    // Published Pentrado 0.1.1 presents during readback (no presentCanvas API).
    const pixels = engine.readback();
    if (gpu.isContextLost()) throw new Error('gpu');
    const context = output.getContext('2d');
    if (!context) throw new Error('gpu');
    context.clearRect(0, 0, output.width, output.height);
    context.putImageData(pixels, 0, 0);
  }
  async function source(url: string, placement: Placement) {
    const response = await fetch(url);
    if (!response.ok) throw new Error('asset');
    const bitmap = await createImageBitmap(await response.blob());
    if (!live) { bitmap.close(); throw new Error('stale'); }
    const canvas = document.createElement('canvas');
    if (!output) { bitmap.close(); throw new Error('stale'); }
    canvas.width = output.width; canvas.height = output.height;
    const ctx = canvas.getContext('2d');
    if (!ctx) { bitmap.close(); throw new Error('gpu'); }
    // The published engine samples full-canvas inputs. Bake placement into a
    // bounded derivative without modifying the original resource or record.
    const [x, y] = placement.origin, [w, h] = placement.size;
    ctx.imageSmoothingQuality = 'high';
    ctx.translate(x + w / 2, y + h / 2);
    ctx.rotate(placement.rotation * Math.PI / 180);
    ctx.scale(placement.flipX ? -1 : 1, placement.flipY ? -1 : 1);
    ctx.drawImage(bitmap, -w / 2, -h / 2, w, h); bitmap.close(); canvases.push(canvas);
    return { source: canvas, rect: { x: 0, y: 0, w: canvas.width, h: canvas.height } };
  }
  return {
    async render(project: ViewerProject, canvas: HTMLCanvasElement, failed: () => void) {
      const { width, height } = project.manifest;
      const probe = new OffscreenCanvas(1, 1);
      const gl = probe.getContext('webgl2');
      if (!gl || !gl.getExtension('EXT_color_buffer_float')) throw new Error('gpu');
      const limit = Math.min(gl.getParameter(gl.MAX_TEXTURE_SIZE), gl.getParameter(gl.MAX_RENDERBUFFER_SIZE));
      gl.getExtension('WEBGL_lose_context')?.loseContext();
      if (width > limit || height > limit) throw new Error('gpu');
      output = canvas; canvas.width = width; canvas.height = height;
      function watchContext() {
        const surface = engine.getCanvas();
        surface?.addEventListener('webglcontextlost', () => {
          clearTimeout(lossTimer);
          // Pentrado first tries to recreate its context. A failed attempt has
          // no restore callback, so bound the wait and fall back explicitly.
          lossTimer = setTimeout(() => { if (live) failed(); }, 2000);
        });
      }
      if (!engine.init({ width, height, onContextRestored: () => {
        clearTimeout(lossTimer);
        if (!live) return;
        try { if (++restored > 2) throw new Error('gpu'); draw(); watchContext(); } catch { failed(); }
      } })) throw new Error('gpu');
      watchContext();
      for (const row of project.analysis.rows) {
        if (!row.effectiveVisible || row.effectiveOpacity === 0 || !row.imageFile || row.isGroup) continue;
        const texture = { ...await source(project.urls[`images/${row.imageFile}`], row.transform), linear: false, key: row.id };
        if (texture.source.width > limit || texture.source.height > limit) throw new Error('gpu');
        let mask;
        if (row.maskFile && row.maskEnabled !== false) {
          mask = { ...await source(project.urls[`images/${row.maskFile}`], row.transform), linear: true, key: row.id + ':mask' };
          if (mask.source.width > limit || mask.source.height > limit) throw new Error('gpu');
        }
        inputs.push({ texture, mask, mode: NORMAL_MODE, opacity: row.effectiveOpacity });
      }
      if (!live) throw new Error('stale');
      draw();
    },
    dispose() {
      live = false; clearTimeout(lossTimer);
      const surface = engine.getCanvas();
      engine.dispose();
      (surface?.getContext('webgl2') as WebGL2RenderingContext | null)?.getExtension('WEBGL_lose_context')?.loseContext();
      inputs = [];
      for (const canvas of canvases) { canvas.width = canvas.height = 1; }
      canvases.length = 0;
    }
  };
}
