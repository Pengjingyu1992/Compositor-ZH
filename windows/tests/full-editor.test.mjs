import {test} from 'node:test';
import assert from 'node:assert/strict';
import {newProject,editProject} from '../packages/comp-bridge/edit.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import {arrange,bounds,following,toLocal,toDocument,shapeMask,combineMasks,modifyMask,floodMask,symmetryPoints} from '../packages/comp-bridge/editor-math.mjs';
import {fillPixels,strokePixels,resizePixels,filterPixels,FILTERS} from '../packages/comp-bridge/raster-tools.mjs';
import {ProjectSession} from '../packages/platform/project-session.mjs';
import {reactive,ref} from 'vue';
import {ipcData} from '../apps/desktop/renderer/ipc-data.ts';
import {remapRuns,rangeStyle} from '../packages/editor-adapter/text-runs.mjs';
const change=(data,op)=>editProject(data,op,codecs);
const setup=()=>{const data=change(newProject(32,24),{kind:'add',type:'pixels',name:'Synthetic'});return {data,id:data.manifest.layers[0].id};};
const image=(w=8,h=8)=>({width:w,height:h,data:new Uint8ClampedArray(w*h*4).map((_,i)=>i%4===3?255:80)});
const placement={origin:[0,0],size:[8,8],rotation:0,sampling:'High quality'};
test('rotated geometry, document/local coordinates and all arrangement operations',()=>{
  const p={...placement,origin:[14,-3],rotation:45,flipX:true};const point=[3,5];assert.ok(toLocal(toDocument(point,p,8,8),p,8,8).every((n,i)=>Math.abs(n-point[i])<1e-6));assert.ok(bounds(p).w>8);
  const rects=[{x:0,y:0,w:10,h:10},{x:20,y:15,w:4,h:4},{x:40,y:30,w:10,h:10}];for(const op of ['left','hcenter','right','top','vcenter','bottom','hspread','vspread','hgap','vgap'])assert.equal(arrange(rects,op).length,3);
  assert.deepEqual(arrange(rects,'right',{x:0,y:0,w:100,h:100})[0],[90,0]);assert.deepEqual(arrange(rects.slice(0,2),'hgap'),[[0,0],[0,0]]);
});
test('selection shapes, set operations and bounded morphology',()=>{
  const rectangle=shapeMask(8,8,'rectangle',[2,2],[6,6]),ellipse=shapeMask(8,8,'ellipse',[2,2],[6,6]);assert.equal(rectangle.reduce((n,v)=>n+(v>0),0),16);assert.ok(ellipse.reduce((n,v)=>n+(v>0),0)<16);
  assert.deepEqual(combineMasks(rectangle,rectangle,'subtract'),new Uint8Array(64));assert.equal(modifyMask(rectangle,8,8,'expand',1).filter(Boolean).length,36);assert.equal(modifyMask(rectangle,8,8,'contract',1).filter(Boolean).length,4);assert.equal(modifyMask(rectangle,8,8,'invert')[0],255);assert.ok(modifyMask(rectangle,8,8,'feather',1)[9]>0);
});
test('flood fill compares premultiplied RGB and alpha; global/contiguous modes',()=>{
  const a={width:3,height:1,data:new Uint8ClampedArray([255,0,0,0,0,0,0,255,0,255,0,0])};assert.deepEqual([...floodMask(a,0,0,0,true)],[255,0,0]);assert.deepEqual([...floodMask(a,0,0,0,false)],[255,0,255]);assert.deepEqual([...floodMask(a,-1,0)],[0,0,0]);
});
test('fill/gradient/eraser respect selection and do not mutate their input',()=>{
  const a=image(),mask={width:8,height:8,data:shapeMask(8,8,'rectangle',[2,2],[6,6])},b=fillPixels(a,placement,mask,{color:[255,0,0]});assert.equal(b.data[0],80);assert.equal(b.data[(3*8+3)*4],255);assert.equal(a.data[(3*8+3)*4],80);
  const g=fillPixels(a,placement,null,{action:'gradient',points:[[0,0],[8,0]],color:[0,0,0],background:[255,255,255],opacity:1});assert.ok(g.data[0]<g.data[7*4]);
  const erased=strokePixels(a,placement,mask,{points:[[4,4]],mode:'eraser',size:4,opacity:1,hardness:1});assert.equal(erased.data[3],255);assert.equal(erased.data[(3*8+3)*4+3],0);
});
test('brush opacity is bounded within one stroke and symmetry is limited to 2–16',()=>{
  const a={...image(),data:new Uint8ClampedArray(256)},b=strokePixels(a,placement,null,{points:[[4,4],[4,4]],color:[255,0,0],size:4,opacity:.5,hardness:1});assert.equal(b.data[(3*8+3)*4+3],128);assert.equal(symmetryPoints([1,1],'radial',4,4,100).length,16);
});
test('clone/healing/smear and blur return valid immutable surfaces',()=>{
  const a=image();for(const mode of ['clone','healing','blur','smudge','liquify']){const b=strokePixels(a,placement,null,{points:[[4,4],[5,4]],source:[1,1],mode,size:3,opacity:1,hardness:1});assert.equal(b.data.length,256);}assert.throws(()=>strokePixels(a,placement,null,{points:[[4,4]],mode:'clone',size:3}),/source/);
});
test('premultiplied resize avoids hidden RGB bleeding and all filters are bounded',()=>{
  const a={width:2,height:1,data:new Uint8ClampedArray([255,0,0,0,0,0,255,255])},b=resizePixels(a,3,1);assert.equal(b.data[4],0);assert.equal(b.data[6],255);
  for(const kind of FILTERS.filter(k=>k!=='Content-Aware Fill')){const output=filterPixels(image(),kind,{size:3,radius:1,amount:10});assert.equal(output.data.length,256);}assert.throws(()=>resizePixels(a,30000,30000),/limit/);
});
test('selection and locks have undo but never mark unchanged file content dirty',()=>{
  const {data,id}=setup(),s=new ProjectSession(undefined,{codecs});s.install(data,null,true);const doc=s.current.id;
  assert.equal(s.edit(doc,s.revision,{kind:'selection',action:'all'}).project.dirty,false);assert.equal(s.edit(doc,s.revision,{kind:'lock',id,field:'content',value:true}).project.dirty,false);assert.equal(s.edit(doc,s.revision,{kind:'clear',id}).error,'locked');s.history(doc,s.revision,'undo');assert.ok(s.edit(doc,s.revision,{kind:'clear',id}).project);
});
test('fill, masks and destructive filters share history and invalidate editable metadata',()=>{
  const {data,id}=setup();let a=change(data,{kind:'selection',action:'rectangle',start:[4,4],end:[10,10]});a=change(a,{kind:'fill',id,settings:{color:[255,0,0]}});const pixels=codecs.decodePNG(a.resources.get(`images/${id}.png`));assert.equal(pixels.data[3],0);assert.equal(pixels.data[(5*32+5)*4],255);
  a=change(a,{kind:'selectionMask',id});assert.ok(a.manifest.layers[0].maskFile);a=change(a,{kind:'applyMask',id});assert.equal(a.manifest.layers[0].maskFile,undefined);assert.equal(a.selection.data.length,32*24);
});
test('canvas crop preserves effects and pixels; image resizing scales and rasterizes',()=>{
  const {data,id}=setup();let a=change(data,{kind:'effect',id,effect:'shadow'});const bytes=a.resources.get(`images/${id}.png`).bytes;a=change(a,{kind:'canvas',x:4,y:5,width:16,height:12});assert.deepEqual(a.manifest.layers[0].transform.origin,[-4,-5]);assert.equal(a.resources.get(`images/${id}.png`).bytes,bytes);assert.equal(a.manifest.layers[0].effects.shadow.distance,10);
  a=change(a,{kind:'imageSize',width:32,height:24});assert.equal(a.resources.get(`images/${id}.png`).width,64);assert.equal(a.manifest.layers[0].effects.shadow.distance,20);
});
test('group duplication remaps descendants; ancestor locks stop every pixel path',()=>{
  const {data,id}=setup();let a=change(data,{kind:'group',ids:[id],name:'Group'}),group=a.manifest.activeLayerID;const hidden=change(a,{kind:'appearance',id:group,field:'isVisible',value:false});assert.equal(change(hidden,{kind:'ungroup',id:group}).manifest.layers.find(l=>l.id===id).isVisible,false);a=change(a,{kind:'duplicateTree',id:group,copySuffix:' 副本'});assert.equal(a.manifest.layers.length,4);assert.equal(new Set(a.manifest.layers.map(l=>l.id)).size,4);assert.equal(a.manifest.layers.find(l=>l.id===a.manifest.activeLayerID).name,'Group 副本');
  a=change(a,{kind:'lock',id:group,field:'content',value:true});for(const kind of ['delete','fill','filter','stroke','pixels'])assert.throws(()=>change(a,{kind,id,filter:'Invert',settings:{points:[[2,2]]}}),e=>e.code==='locked');
});
test('style creation validates UTF-16 runs and saves only current schema fields',()=>{
  const {data}=setup(),style={content:'中文😀',fontName:'ArialMT',fontSize:24,red:0,green:0,blue:0,alignment:'Left',tracking:0,leading:0,boxSize:[32,24],colorRuns:[{location:2,length:2,red:1,green:0,blue:0}],fontRuns:[]},png=new Uint8Array(codecs.blankPNG(32,24,false).bytes);
  const a=change(data,{kind:'styled',type:'text',origin:[1,2],style,png});assert.equal(a.manifest.version,11);assert.equal(a.manifest.layers.at(-1).text.content,'中文😀');assert.throws(()=>change(data,{kind:'styled',type:'text',origin:[0,0],style:{...style,colorRuns:[{location:3,length:2,red:1,green:0,blue:0}]},png}),e=>e.code==='invalid');
});
test('asynchronous old owner cannot publish into a replacement document',async()=>{
  const {data,id}=setup(),s=new ProjectSession(undefined,{codecs});s.install(data,null,true);let done;const pending=s.editAsync(s.current.id,s.revision,{kind:'fill',id},()=>new Promise(resolve=>{done=resolve;}));assert.equal(s.create(2,2).error,'busy');s.install(newProject(2,2));done(data);assert.equal((await pending).error,'stale');assert.equal(s.current.data.manifest.width,2);
});
test('worker snapshots preserve clean selection state and share unchanged resource buffers',async()=>{
 const {data,id}=setup(),s=new ProjectSession(undefined,{codecs});s.install(data,null,true);const original=s.current.data.resources.get(`images/${id}.png`);
 const result=await s.editAsync(s.current.id,s.revision,{kind:'selection',action:'all'},before=>Promise.resolve(structuredClone(change(before,{kind:'selection',action:'all'}))));assert.equal(result.project.dirty,false);assert.equal(s.current.data.resources.get(`images/${id}.png`),original);assert.equal(s.current.data.selection.data.length,768);
 const revision=s.revision,count=s.undoStack.length;await s.editAsync(s.current.id,s.revision,{kind:'stroke',id,settings:{points:[[-100,-100]]}},(before,op)=>Promise.resolve(structuredClone(change(before,op))));assert.equal(s.revision,revision);assert.equal(s.undoStack.length,count);
 const batch={kind:'batch',operations:[{kind:'selection',action:'invert'},{kind:'lock',id,field:'alpha',value:true}]};await s.editAsync(s.current.id,s.revision,batch,(before,op)=>Promise.resolve(structuredClone(change(before,op))));assert.equal(s.current.data.locks[id].alpha,true);assert.ok(s.current.data.selection.data.every(v=>v===0));assert.equal(s.isDirty(),false);
});
test('alpha locks inherit from groups and independent mask transform survives validation',()=>{
 const {data,id}=setup();let a=change(data,{kind:'group',ids:[id],name:'Group'});const group=a.manifest.activeLayerID;a=change(a,{kind:'lock',id:group,field:'alpha',value:true});a=change(a,{kind:'fill',id,settings:{color:[255,0,0]}});assert.ok(codecs.decodePNG(a.resources.get(`images/${id}.png`)).data.every((v,i)=>i%4!==3||v===0));
 a=change(a,{kind:'mask',id,action:'add'});a=change(a,{kind:'transformMask',id,field:'origin',value:[3,4]});const layer=a.manifest.layers.find(l=>l.id===id);assert.equal(layer.maskLinked,false);assert.deepEqual(layer.maskPlacement.origin,[3,4]);
});
test('group rotation/resize and linked/unlinked masks follow the rectangle model',()=>{
 const {data,id}=setup();let a=change(data,{kind:'mask',id,action:'add'});a=change(a,{kind:'transformMask',id,field:'origin',value:[3,4]});a=change(a,{kind:'group',ids:[id],name:'Group'});const group=a.manifest.activeLayerID;
 a=change(a,{kind:'transformLayers',ids:[group],field:'rotation',value:90});let l=a.manifest.layers.find(l=>l.id===id);assert.ok(Math.abs(l.transform.rotation-90)<1e-8);assert.deepEqual(l.maskPlacement.origin,[3,4]);
 a=change(a,{kind:'canvas',x:2,y:1,width:30,height:23});l=a.manifest.layers.find(l=>l.id===id);assert.deepEqual(l.maskPlacement.origin,[1,3]);
 const t=following(placement,{...placement,size:[8,8]},{...placement,size:[16,16]});assert.deepEqual(t.size,[16,16]);assert.deepEqual(t.origin,[0,0]);
});
test('reactive tool parameters cross IPC without proxies or corrupting PNG arrays',()=>{
 const source=ref([4,5]),op=reactive({ids:['one','two'],settings:{source:source.value},png:new Uint8Array([1,2,3]),id:undefined});const copied=structuredClone(ipcData(op));assert.deepEqual(copied.ids,['one','two']);assert.deepEqual(copied.settings.source,[4,5]);assert.ok(copied.png instanceof Uint8Array);assert.equal(copied.id,undefined);
});
test('empty strokes and alpha-locked fill retain editable metadata and save identity',()=>{
 const initial=setup(),id=initial.id,data=change(initial.data,{kind:'styled',id,type:'shape',origin:[0,0],style:{kind:'Rectangle',red:0,green:0,blue:0,cornerRadius:0,lineWidth:0,start:[0,0],end:[1,1]},png:new Uint8Array(initial.data.resources.get(`images/${id}.png`).bytes)});
 const before=data.resources.get(`images/${id}.png`);assert.equal(change(data,{kind:'stroke',id,settings:{points:[[-100,-100]],size:4,color:[255,0,0]}}),data);
 const locked=change(data,{kind:'lock',id,field:'alpha',value:true}),after=change(locked,{kind:'fill',id,settings:{color:[255,0,0]}});assert.equal(after,locked);assert.equal(after.resources.get(`images/${id}.png`),before);assert.ok(after.manifest.layers[0].shape);
});
test('group selection masks have canvas dimensions and structure locks cover insertion',()=>{
 const {data,id}=setup();let a=change(data,{kind:'group',ids:[id],name:'Group'});const group=a.manifest.activeLayerID;a=change(a,{kind:'selection',action:'all'});a=change(a,{kind:'selectionMask',id:group});const r=a.resources.get(`images/${group}.mask.png`);assert.equal(r.width,32);assert.equal(r.height,24);assert.equal(codecs.decodePNG(r).data[0],255);
 a=change(a,{kind:'lock',id:group,field:'content',value:true});assert.throws(()=>change(a,{kind:'add',type:'pixels',name:'Blocked',parentID:group}),e=>e.code==='locked');
 a=change(a,{kind:'lock',id:group,field:'content',value:false});a=change(a,{kind:'lock',id,field:'position',value:true});assert.throws(()=>change(a,{kind:'reorder',id,direction:1}),e=>e.code==='locked');assert.throws(()=>change(a,{kind:'group',ids:[id],name:'Blocked'}),e=>e.code==='locked');
});
test('editing across differently styled UTF-16 runs never leaves overlapping ranges',()=>{
 const runs=[{location:0,length:4,fontName:'ArialMT'},{location:4,length:4,fontName:'SimSun'}];assert.deepEqual(remapRuns(runs,'ABCDEFGH','ABGH'),[{location:0,length:2,fontName:'ArialMT'},{location:2,length:2,fontName:'SimSun'}]);
 assert.deepEqual(remapRuns([{location:0,length:4,fontName:'ArialMT'}],'中文😀','中文新😀'),[{location:0,length:5,fontName:'ArialMT'}]);assert.deepEqual(remapRuns(runs,'ABCDEFGH',''),[]);
 const updated=rangeStyle(runs,2,6,{fontName:'Consolas'});assert.deepEqual(updated.map(r=>[r.location,r.length]),[[0,2],[2,4],[6,2]]);assert.deepEqual(runs.map(r=>r.length),[4,4]);
});
test('external grayscale PNGs normalize to RGBA8 after bounded header checks',()=>{
 const input=codecs.blankPNG(8,8,true,127),r=codecs.importPNG(input.bytes);assert.equal(r.bytes[25],6);assert.equal(codecs.decodePNG(r).data[0],127);assert.equal(codecs.decodePNG(r).data[3],255);
 const large=Buffer.from(input.bytes);large.writeUInt32BE(30000,16);large.writeUInt32BE(30000,20);assert.throws(()=>codecs.importPNG(large),e=>e.code==='limit');
});
