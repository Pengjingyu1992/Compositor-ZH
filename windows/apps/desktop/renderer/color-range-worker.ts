import{colorRangeMask}from'../../../packages/comp-bridge/color-range.mjs';
self.onmessage=event=>{try{const mask=colorRangeMask(event.data.image,event.data.settings);self.postMessage({mask},{transfer:[mask.buffer]});}catch(error){self.postMessage({error:(error as Error).message});}};
