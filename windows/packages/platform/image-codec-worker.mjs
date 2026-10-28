import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
try {
  const codecs = createRequire(import.meta.url)(workerData.codecPath);
  let result;
  if (['encodeOutputImage', 'printProof'].includes(workerData.operation)) {
    const output = await import('./image-output.mjs');
    result = await output[workerData.operation](workerData.bytes, workerData.resolution);
  } else if(workerData.operation==='grayscaleImage'){
    const {filterPixels}=await import('../comp-bridge/raster-tools.mjs');result=codecs.encodePixels(filterPixels(codecs.decodePNG(codecs.validatePNG(workerData.bytes)),'Desaturate')).bytes;
  } else if (workerData.operation === 'decodeSourceImage') {
    const { decodeSourceImage } = await import('./image-pipeline.mjs');
    result = await decodeSourceImage(workerData.bytes);
  } else {
    if (!['gifInfo', 'importGIF', 'exportGIF', 'importRasterEPS', 'exportEPS', 'importPNG'].includes(workerData.operation)) throw new Error('invalid');
    result = await codecs[workerData.operation](workerData.bytes, workerData.resolution);
  }
  parentPort.postMessage({ result });
} catch (error) { parentPort.postMessage({ error: error.code ?? 'asset' }); }
