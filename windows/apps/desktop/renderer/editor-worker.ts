import { applySelectedFilter } from '../../../packages/comp-bridge/raster-tools.mjs';
self.onmessage=event=>{try{const p=event.data,result=applySelectedFilter(p.image,p.placement,p.selection,p.kind,p.settings);self.postMessage({result},{transfer:[result.data.buffer]});}catch(error){self.postMessage({error:(error as Error).message});}};
