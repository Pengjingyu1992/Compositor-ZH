import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
try {
  const codecs = createRequire(import.meta.url)(workerData.codecPath);
  if (!['gifInfo', 'importGIF', 'exportGIF', 'importRasterEPS', 'exportEPS', 'importPNG'].includes(workerData.operation)) throw new Error('invalid');
  parentPort.postMessage({ result: codecs[workerData.operation](workerData.bytes, workerData.resolution) });
} catch (error) { parentPort.postMessage({ error: error.code ?? 'asset' }); }
