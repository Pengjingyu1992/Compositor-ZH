import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { editProject } from '../comp-bridge/edit.mjs';
import { prepareStructuredOperation } from './structured-layers.mjs';
const codecs=createRequire(import.meta.url)(workerData.codecPath);
try {
  const data=workerData.data;data.sourceBytes=Buffer.from(data.sourceBytes);
  for(const resource of data.resources.values()){resource.bytes=Buffer.from(resource.bytes);if(resource.proxyBytes)resource.proxyBytes=Buffer.from(resource.proxyBytes);}
  async function execute(data,op){
    if(op?.kind==='batch'){
      if(!Array.isArray(op.operations)||!op.operations.length||op.operations.length>512||op.operations.some(value=>value?.kind==='batch'))throw new Error('invalid');
      for(const operation of op.operations)data=await execute(data,operation);
      return data;
    }
    return editProject(data,await prepareStructuredOperation(data,op),codecs);
  }
  parentPort.postMessage({data:await execute(data,workerData.op)});
} catch(error) { parentPort.postMessage({error:error.code??(['limit','source','selection'].includes(error.message)?error.message:'invalid')}); }
