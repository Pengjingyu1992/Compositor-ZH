import {test} from 'node:test';
import assert from 'node:assert/strict';
import {newProject,editProject} from '../packages/comp-bridge/edit.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import {arrange,bounds,toLocal,toDocument,shapeMask,combineMasks,modifyMask,floodMask,symmetryPoints} from '../packages/comp-bridge/editor-math.mjs';
import {fillPixels,strokePixels,resizePixels,filterPixels,FILTERS} from '../packages/comp-bridge/raster-tools.mjs';
import {ProjectSession} from '../packages/platform/project-session.mjs';
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
  const {data,id}=setup();let a=change(data,{kind:'group',ids:[id],name:'Group'}),group=a.manifest.activeLayerID;a=change(a,{kind:'duplicateTree',id:group});assert.equal(a.manifest.layers.length,4);assert.equal(new Set(a.manifest.layers.map(l=>l.id)).size,4);
  a=change(a,{kind:'lock',id:group,field:'content',value:true});for(const kind of ['delete','fill','filter','stroke','pixels'])assert.throws(()=>change(a,{kind,id,filter:'Invert',settings:{points:[[2,2]]}}),e=>e.code==='locked');
});
test('style creation validates UTF-16 runs and saves only current schema fields',()=>{
  const {data}=setup(),style={content:'中文😀',fontName:'ArialMT',fontSize:24,red:0,green:0,blue:0,alignment:'Left',tracking:0,leading:0,boxSize:[32,24],colorRuns:[{location:2,length:2,red:1,green:0,blue:0}],fontRuns:[]},png=new Uint8Array(codecs.blankPNG(32,24,false).bytes);
  const a=change(data,{kind:'styled',type:'text',origin:[1,2],style,png});assert.equal(a.manifest.version,11);assert.equal(a.manifest.layers.at(-1).text.content,'中文😀');assert.throws(()=>change(data,{kind:'styled',type:'text',origin:[0,0],style:{...style,colorRuns:[{location:3,length:2,red:1,green:0,blue:0}]},png}),e=>e.code==='invalid');
});
test('asynchronous old owner cannot publish into a replacement document',async()=>{
  const {data,id}=setup(),s=new ProjectSession(undefined,{codecs});s.install(data,null,true);let done;const pending=s.editAsync(s.current.id,s.revision,{kind:'fill',id},()=>new Promise(resolve=>{done=resolve;}));assert.equal(s.create(2,2).error,'busy');s.install(newProject(2,2));done(data);assert.equal((await pending).error,'stale');assert.equal(s.current.data.manifest.width,2);
});
