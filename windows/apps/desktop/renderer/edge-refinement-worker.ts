import{guidedEdge,edgeGuide,edgeBrush,edgePreview,saveEdgeLevels,validateEdgeSettings}from'../../../packages/comp-bridge/edge-refinement.mjs';
let source:any,sourceWidth=1,levels:Float32Array,guide:Float32Array,guided:Float32Array|undefined,past:Float32Array[]=[],future:Float32Array[]=[],before:Float32Array|undefined,last:number[]|undefined,maskOnly=false,settings:any;
function trim(){const count=Math.max(1,Math.min(32,Math.floor(64*1024**2/levels.byteLength)));while(past.length>count)past.shift();}
function preview(){const image=edgePreview(source,levels,settings,sourceWidth,maskOnly);self.postMessage({image,canUndo:past.length>0,canRedo:future.length>0},{transfer:[image.data.buffer]});}
self.onmessage=event=>{try{const m=event.data;
  if(m.action==='init'){source=m.source;sourceWidth=m.sourceWidth;levels=new Float32Array(m.levels);guide=edgeGuide(source);settings=validateEdgeSettings(m.settings);preview();}
  else if(m.action==='configure'){settings=validateEdgeSettings(m.settings);maskOnly=m.maskOnly===true;preview();}
  else if(m.action==='stroke'){settings=validateEdgeSettings(m.settings);maskOnly=m.maskOnly===true;if(!before){before=new Float32Array(levels);last=undefined;if(m.brush.mode==='refine')guided=guidedEdge(levels,guide,source.width,source.height);}edgeBrush(levels,source.width,source.height,last,m.point,{...m.brush,sourceWidth},guided);last=m.point;preview();}
  else if(m.action==='end'){if(before){past.push(before);future=[];before=undefined;last=undefined;guided=undefined;trim();}preview();}
  else if(m.action==='undo'&&past.length){future.push(levels);levels=past.pop()!;preview();}
  else if(m.action==='redo'&&future.length){past.push(levels);levels=future.pop()!;trim();preview();}
  else if(m.action==='save'){self.postMessage({saved:saveEdgeLevels(levels,source.width,source.height)});}
}catch(error){self.postMessage({error:(error as any).code??'invalid'});}};
