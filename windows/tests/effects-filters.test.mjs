import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ADJUSTMENT_KINDS, EFFECT_KINDS } from '../packages/comp-bridge/capabilities.mjs';
import { adjustedPixels, effectPixels } from '../packages/editor-adapter/pixels.mjs';
import { FILTERS, applySelectedFilter } from '../packages/comp-bridge/raster-tools.mjs';
import { shapeMask } from '../packages/comp-bridge/editor-math.mjs';
import { newProject, editProject, projectData } from '../packages/comp-bridge/edit.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';

const image = { width: 12, height: 10, data: Uint8ClampedArray.from({ length: 480 }, (_, i) => i % 4 === 3 ? (Math.floor(i/4)%12<3 ? 0 : 180) : (i*37)%256) };
const placement = { origin:[0,0], size:[12,10], rotation:0, sampling:'High quality' };
const selection = { width:12, height:10, data:shapeMask(12,10,'rectangle',[4,3],[8,7]) };
const valid = result => { assert.equal(result.width,12);assert.equal(result.height,10);assert.equal(result.data.length,480);assert.ok(result.data.every(Number.isFinite)); };
let project=editProject(newProject(12,10),{kind:'add',type:'pixels',name:'Synthetic'},codecs);
const layerID=project.manifest.layers[0].id;
for(const kind of ADJUSTMENT_KINDS)test(`adjustment ${kind}: preserves source and valid RGBA`,()=>{
  const adjusted=editProject(project,{kind:'add',type:'adjustment',adjustment:kind,name:kind},codecs).manifest.layers.at(-1).adjustment;
  const before=image.data.slice(), result=adjustedPixels(image,adjusted); valid(result);assert.deepEqual(image.data,before);
  if(!['Gaussian Blur','Motion Blur'].includes(kind))for(let i=3;i<result.data.length;i+=4)assert.equal(result.data[i],before[i]);
});
for(const kind of EFFECT_KINDS)test(`effect ${kind}: disabled identity and immutable source`,()=>{
  const effect=editProject(project,{kind:'effect',id:layerID,effect:kind},codecs).manifest.layers[0].effects[kind];
  const before=image.data.slice();valid(effectPixels(image,{[kind]:effect}));
  const disabled=effectPixels(image,{[kind]:{...effect,enabled:false}}).data;
  for(let i=0;i<before.length;i+=4){assert.equal(disabled[i+3],before[i+3]);if(before[i+3])assert.deepEqual(disabled.slice(i,i+4),before.slice(i,i+4));}
  assert.deepEqual(image.data,before);
});
test('an empty selection keeps every source byte, including hidden RGB',()=>{
  const empty={...selection,data:new Uint8Array(120)};
  assert.deepEqual(applySelectedFilter(image,placement,empty,'Invert',{}).data,image.data);
});
test('a filter on an empty selection keeps saved identity, redo and editable shape metadata',()=>{
  let data=editProject(project,{kind:'pixels',id:layerID,target:'content',png:codecs.encodePixels(image).bytes},codecs);
  const manifest=structuredClone(data.manifest);
  manifest.layers[0].shape={kind:'Rectangle',red:0,green:0,blue:1,cornerRadius:0,lineWidth:1,start:[0,0],end:[1,1]};
  data=projectData(manifest,data.resources);data.selection={width:12,height:10,data:new Uint8Array(120)};
  const session=new ProjectSession(undefined,{codecs});session.install(data,null,true);
  session.edit(session.current.id,session.revision,{kind:'rename',id:layerID,name:'Temporary'});session.history(session.current.id,session.revision,'undo');
  const revision=session.revision, result=session.edit(session.current.id,revision,{kind:'filter',id:layerID,filter:'Invert',settings:{}});
  assert.equal(result.project.dirty,false);assert.equal(session.revision,revision);assert.equal(session.redoStack.length,1);
  assert.deepEqual(session.current.data.manifest.layers[0].shape,manifest.layers[0].shape);session.close();
});
for(const kind of FILTERS)test(`filter ${kind}: selection limits changes and keeps source immutable`,()=>{
  const before=image.data.slice(),result=applySelectedFilter(image,placement,selection,kind,{size:3,radius:1,amount:25});valid(result);
  for(let i=0;i<selection.data.length;i++)if(!selection.data[i])assert.deepEqual(result.data.slice(i*4,i*4+4),before.slice(i*4,i*4+4));
  assert.deepEqual(image.data,before);
});
