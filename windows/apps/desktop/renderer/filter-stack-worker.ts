import { renderFilterStack } from '../../../packages/comp-bridge/editable-filters.mjs';
self.onmessage=event=>{
  try{const image=renderFilterStack(event.data.source,event.data.nodes);self.postMessage({image}, {transfer:[image.data.buffer]});}
  catch(error){self.postMessage({error:(error as any).code??'invalid'});}
};
