import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { editProject } from '../comp-bridge/edit.mjs';
const codecs=createRequire(import.meta.url)(workerData.codecPath);
try {
  const data=workerData.data;data.sourceBytes=Buffer.from(data.sourceBytes);
  for(const resource of data.resources.values())resource.bytes=Buffer.from(resource.bytes);
  parentPort.postMessage({data:editProject(data,workerData.op,codecs)});
} catch(error) { parentPort.postMessage({error:error.code??(['limit','source','selection'].includes(error.message)?error.message:'invalid')}); }
