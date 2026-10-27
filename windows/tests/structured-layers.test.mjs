import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm}from'node:fs/promises';
import os from'node:os';
import path from'node:path';
import{newProject,editProject,projectData}from'../packages/comp-bridge/edit.mjs';
import{readProject}from'../packages/comp-bridge/project.mjs';
import{saveProject,RecoveryStore}from'../packages/platform/save-project.mjs';
import{ProjectSession}from'../packages/platform/project-session.mjs';
import{prepareStructuredOperation}from'../packages/platform/structured-layers.mjs';
import{defaultFillStyle,defaultVectorPath,renderFillPixels,supportsFillStyle,supportsVectorPath}from'../packages/comp-bridge/layer-styles.mjs';
import{effectPixels}from'../packages/editor-adapter/pixels.mjs';
import*as codecs from'../packages/comp-bridge/codecs.mjs';
const change=(data,op)=>editProject(data,op,codecs);
function rectangle(){const vector=defaultVectorPath();vector.contours=[{closed:true,anchors:[[0,0],[1,0],[1,1],[0,1]].map(point=>({point}))},{closed:true,anchors:[[.25,.25],[.75,.25],[.75,.75],[.25,.75]].map(point=>({point}))}];vector.evenOdd=true;return vector;}
async function location(t){const directory=await mkdtemp(path.join(os.tmpdir(),'comp-structured-'));t.after(()=>rm(directory,{recursive:true,force:true}));return directory;}
test('editable fills retain ordered stops, pattern choices, alpha and format versions through save/recovery',async t=>{
  const directory=await location(t),style=defaultFillStyle();style.stops[0].color.alpha=.5;
  let data=change(newProject(32,24),{kind:'fillLayer',style,name:'Fill'}),id=data.manifest.activeLayerID;
  assert.equal(data.manifest.version,12);assert.deepEqual(data.analysis.issues,[]);assert.equal(codecs.decodePNG(data.resources.get(`images/${id}.png`)).data[3],128);
  data=change(data,{kind:'transform',id,field:'origin',value:[8,6]});assert.deepEqual(data.manifest.layers[0].fill,style);
  const copy=path.join(directory,'fill.comp');await saveProject(data,copy);const loaded=await readProject(copy);assert.deepEqual(loaded.manifest.layers[0].fill,style);
  const store=new RecoveryStore(path.join(directory,'recovery'));await store.write(data,crypto.randomUUID());const[entry]=await store.list();assert.deepEqual((await store.restore(entry.key)).manifest,data.manifest);
  for(const kind of ['Linear','Radial','Pattern']){const pixels=renderFillPixels(32,24,{...style,kind});assert.equal(pixels.data.length,32*24*4);}
  assert.equal(supportsFillStyle({...style,stops:[null,null]}),false);assert.equal(supportsFillStyle({...style,scale:Infinity}),false);
});
test('path geometry, holes and vector masks survive transforms, saving and mask edits',async t=>{
  const directory=await location(t);let data=change(newProject(32,24),{kind:'add',type:'pixels',name:'Base'}),base=data.manifest.activeLayerID;
  data=change(data,{kind:'fill',id:base,settings:{color:[20,80,180]}});
  data=change(data,await prepareStructuredOperation(data,{kind:'path',name:'Path',style:rectangle(),color:{red:1,green:0,blue:0}}));
  const source=data.manifest.activeLayerID,asset=data.resources.get(`images/${source}.png`),pixels=codecs.decodePNG(asset);
  assert.equal(pixels.data[(12*32+16)*4+3],0);assert.equal(pixels.data[(2*32+2)*4],255);assert.equal(data.manifest.version,13);
  const operation=await prepareStructuredOperation(data,{kind:'vectorMask',id:base,sourcePathID:source});data=change(data,operation);
  assert.equal(data.manifest.layers.find(layer=>layer.id===source).isVisible,false);
  assert.ok(data.manifest.layers.find(layer=>layer.id===base).vectorMask);
  const mask=codecs.decodePNG(data.resources.get(`images/${base}.mask.png`));assert.equal(mask.data[(12*32+16)*4],0);assert.equal(mask.data[(2*32+2)*4],255);
  const file=path.join(directory,'path.comp');await saveProject(data,file);const loaded=await readProject(file);assert.deepEqual(loaded.analysis.issues,[]);assert.deepEqual(loaded.manifest,data.manifest);
  const painted=change(loaded,{kind:'stroke',id:base,target:'mask',settings:{points:[[2,2]],mode:'eraser',size:4,opacity:1,hardness:1}});assert.equal(painted.manifest.layers.find(layer=>layer.id===base).vectorMask,undefined);
  assert.equal(supportsVectorPath({...rectangle(),strokeWidth:Infinity}),false);
});
test('pixel edits rasterize editable fills while undo restores them; only owned orphan assets are removed',()=>{
  let data=change(newProject(8,6),{kind:'fillLayer',style:defaultFillStyle(),name:'Fill'}),id=data.manifest.activeLayerID;
  const resources=new Map(data.resources);resources.set('future/opaque.bin',{bytes:Buffer.from([1,2,3]),mime:'application/octet-stream'});data=projectData(data.manifest,resources);
  const session=new ProjectSession(undefined,{codecs});session.install(data,null,true);
  const before=data.resources.get(`images/${id}.png`),pixels=codecs.decodePNG(before);pixels.data[0]=0;
  session.edit(session.current.id,session.revision,{kind:'pixels',id,png:codecs.encodePixels(pixels).bytes});assert.equal(session.current.data.manifest.layers[0].fill,undefined);
  session.history(session.current.id,session.revision,'undo');assert.deepEqual(session.current.data.manifest.layers[0].fill,data.manifest.layers[0].fill);
  session.edit(session.current.id,session.revision,{kind:'delete',id});assert.equal(session.current.data.resources.has(`images/${id}.png`),false);assert.ok(session.current.data.resources.has('future/opaque.bin'));
  session.history(session.current.id,session.revision,'undo');assert.deepEqual(session.current.data.resources.get(`images/${id}.png`).bytes,before.bytes);session.close();
});
test('macOS lock capabilities cover effects, mask flags, structure, alpha and all-lock rename without blocking copies',()=>{
  let data=change(newProject(8,6),{kind:'add',type:'pixels',name:'Base'}),id=data.manifest.activeLayerID;
  data=change(data,{kind:'mask',id,action:'add'});const content=change(data,{kind:'lock',id,field:'content',value:true});
  assert.ok(change(content,{kind:'effect',id,effect:'gradientOverlay'}));assert.ok(change(content,{kind:'mask',id,action:'toggle'}));
  const appearance=change(data,{kind:'lock',id,field:'appearance',value:true});for(const op of [{kind:'effect',effect:'bevel'},{kind:'mask',action:'toggle'},{kind:'delete'}])assert.throws(()=>change(appearance,{...op,id}),e=>e.code==='locked');
  const position=change(data,{kind:'lock',id,field:'position',value:true});assert.throws(()=>change(position,{kind:'mask',id,action:'link',value:false}),e=>e.code==='locked');
  const all=change(data,{kind:'lock',id,field:'all',value:true});assert.throws(()=>change(all,{kind:'rename',id,name:'Blocked'}),e=>e.code==='locked');assert.equal(change(all,{kind:'duplicate',id}).manifest.layers.length,2);
  const alpha=change(data,{kind:'lock',id,field:'alpha',value:true}),rgba=codecs.decodePNG(data.resources.get(`images/${id}.png`));rgba.data[3]=255;
  assert.throws(()=>change(alpha,{kind:'pixels',id,png:codecs.encodePixels(rgba).bytes}),e=>e.code==='locked');
});
test('inner color/gradient effects preserve soft alpha and leave outer shadows untinted',()=>{
  const image={width:3,height:1,data:new Uint8ClampedArray([0,0,0,0,255,0,0,128,0,0,0,0])};
  const overlay={enabled:true,red:0,green:0,blue:1,opacity:1},output=effectPixels(image,{colorOverlay:overlay,shadow:{red:0,green:0,blue:0,opacity:1,angle:180,distance:1,blur:0}});
  assert.deepEqual([...output.data.slice(4,8)],[0,0,255,128]);assert.deepEqual([...output.data.slice(8,12)],[0,0,0,128]);
  const fill=defaultFillStyle();fill.kind='Linear';fill.angle=0;fill.stops[0].color={red:0,green:0,blue:0,alpha:1};fill.stops[1].color={red:1,green:1,blue:1,alpha:1};
  const frame={width:12,height:12,data:new Uint8ClampedArray(12*12*4)};for(let y=3;y<9;y++)for(let x=3;x<9;x++)frame.data[(y*12+x)*4+3]=128;
  const styled=effectPixels(frame,{gradientOverlay:{fill,opacity:1}},{pixelSize:[6,6],placement:{origin:[3,3],size:[6,6],rotation:0}});
  assert.ok(Math.abs(styled.data[(4*12+3)*4]-21)<=1);assert.ok(Math.abs(styled.data[(4*12+8)*4]-234)<=1);assert.equal(styled.data[(4*12+3)*4+3],128);
});
test('resolution-only changes preserve editable records, resource identities and the active selection',()=>{
  let data=change(newProject(8,6),{kind:'fillLayer',style:defaultFillStyle(),name:'Fill'});data.selection={width:8,height:6,data:new Uint8Array(48).fill(255)};
  const result=change(data,{kind:'imageSize',width:8,height:6,resolution:300});assert.equal(result.manifest.resolution,300);assert.deepEqual(result.manifest.layers,data.manifest.layers);assert.equal(result.selection,data.selection);
  for(const[key,value]of data.resources)assert.equal(result.resources.get(key),value);
});
