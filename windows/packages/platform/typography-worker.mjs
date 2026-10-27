import {parentPort,workerData}from'node:worker_threads';
import {createRequire}from'node:module';
try{
  const typography=createRequire(import.meta.url)(workerData.typographyPath);
  const result=workerData.action==='fonts'?{fonts:await typography.fontNames()}:{png:(await typography.renderVectorText(workerData.payload.style)).png};
  parentPort.postMessage({result});
}catch(error){parentPort.postMessage({error:error.code??'glyph'});}
