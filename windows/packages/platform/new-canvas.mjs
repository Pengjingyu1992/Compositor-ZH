import { randomUUID } from 'node:crypto';
import { canvasCreation } from '../comp-bridge/new-canvas.mjs';
import { newProject, projectData, placement } from '../comp-bridge/edit.mjs';

export function newCanvasProject(width, height, options, codecs) {
  const spec = canvasCreation(width, height, options);
  const project = newProject(width, height, spec.resolution);
  if (spec.background === 'transparent') return project;
  const pixels = new Uint8Array(width * height * 4);
  if (spec.background === 'white') pixels.fill(255);
  else for (let at = 3; at < pixels.length; at += 4) pixels[at] = 255;
  const resource = codecs.encodePixels({ width, height, data: pixels });
  const id = randomUUID().toUpperCase(), imageFile = `${id}.png`;
  return projectData({ ...project.manifest, activeLayerID: id, layers: [
    { id, name: spec.backgroundName, isVisible: true, imageFile, transform: placement(width, height) }
  ] }, new Map([[`images/${imageFile}`, resource]]));
}
