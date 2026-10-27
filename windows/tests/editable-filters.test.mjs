import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fixture, IDS } from './fixtures.mjs';
import { readProject, parseManifest, resourceDigests } from '../packages/comp-bridge/project.mjs';
import { editProject } from '../packages/comp-bridge/edit.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { saveProject, RecoveryStore } from '../packages/platform/save-project.mjs';
import { defaultFilterNode, readFilterNodes, encodeBinary, decodeBinary, renderFilterStack } from '../packages/comp-bridge/editable-filters.mjs';
import { newLiquify, liquifyDab, renderLiquify, validateSavedLiquify } from '../packages/comp-bridge/liquify.mjs';

test('filter recipes retain source, order, masks, stable noise and undo resources across save and recovery',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-stack-'));
  try{
    const root=path.join(temp,'source.comp');await fixture(root);const original=await readProject(root),node=defaultFilterNode('Add Noise');node.amount=100;
    const selected=editProject(original,{kind:'selection',action:'rectangle',start:[0,0],end:[32,48]},codecs);
    const data=editProject(selected,{kind:'filterStack',id:IDS[0],nodes:[node]},codecs),layer=data.manifest.layers[0],nodes=readFilterNodes(layer,data.resources);
    assert.equal(data.manifest.version,14);assert.equal(nodes.length,1);assert.equal(decodeBinary(nodes[0].coverage,64*48)[40],0);
    assert.deepEqual(data.resources.get(`edits/${layer.editableFilters.sourceFile}`).bytes,original.resources.get(`images/${layer.imageFile}`).bytes);
    const pixels=codecs.decodePNG(data.resources.get(`images/${layer.imageFile}`));assert.notDeepEqual(pixels.data,codecs.decodePNG(original.resources.get(`images/${layer.imageFile}`)).data);
    const repeated=editProject(data,{kind:'filterStack',id:layer.id,nodes},codecs);assert.deepEqual(resourceDigests(repeated),resourceDigests(data));
    const saved=path.join(temp,'saved.comp');await saveProject(data,saved);const reopened=await readProject(saved);assert.deepEqual(readFilterNodes(reopened.manifest.layers[0],reopened.resources),nodes);assert.deepEqual(resourceDigests(reopened),resourceDigests(data));
    const store=new RecoveryStore(path.join(temp,'recovery'));await store.write(data,crypto.randomUUID());const restored=await store.restore((await store.list())[0].key);assert.deepEqual(resourceDigests(restored),resourceDigests(data));
    const moved=editProject(data,{kind:'transform',id:layer.id,field:'origin',value:[5,7]},codecs);assert.deepEqual(readFilterNodes(moved.manifest.layers[0],moved.resources),nodes);
    const copy=editProject(moved,{kind:'duplicate',id:layer.id},codecs),duplicate=copy.manifest.layers[1];assert.notEqual(duplicate.editableFilters.sourceFile,layer.editableFilters.sourceFile);assert.deepEqual(readFilterNodes(duplicate,copy.resources),nodes);
    const baked=editProject(data,{kind:'rasterize',id:layer.id},codecs);assert.equal(baked.manifest.layers[0].editableFilters,undefined);assert.equal([...baked.resources.keys()].some(key=>key.startsWith('edits/')),false);assert.ok(data.resources.has(`edits/${layer.editableFilters.sourceFile}`));
    const painted=editProject(data,{kind:'fill',id:layer.id,settings:{color:[30,60,90],opacity:1}},codecs);assert.equal(painted.manifest.layers[0].editableFilters,undefined);assert.equal([...painted.resources.keys()].some(key=>key.startsWith('edits/')),false);
    const copied=editProject(data,{kind:'filterStack',id:layer.id,nodes,copy:true},codecs);assert.equal(copied.manifest.layers[0].isVisible,false);assert.equal(copied.manifest.layers.length,3);assert.deepEqual(readFilterNodes(copied.manifest.layers[1],copied.resources),nodes);
    const halftone=defaultFilterNode('Color Halftone'),screened=editProject(original,{kind:'filterStack',id:layer.id,nodes:[halftone]},codecs);assert.equal(screened.manifest.version,15);
    const mislabeled=structuredClone(screened.manifest);mislabeled.version=14;await assert.rejects(async()=>{const dir=path.join(temp,'mislabeled.comp');await saveProject({...screened,manifest:mislabeled,sourceBytes:Buffer.from(JSON.stringify(mislabeled))},dir);await readProject(dir);});
    const cleared=editProject(data,{kind:'filterStack',id:layer.id,nodes:[]},codecs);assert.deepEqual(codecs.decodePNG(cleared.resources.get(`images/${layer.imageFile}`)).data,codecs.decodePNG(original.resources.get(`images/${layer.imageFile}`)).data);
  }finally{await rm(temp,{recursive:true,force:true});}
});

test('recipe schema, unknown versions, unsafe files, dimensions, budgets and LUT gates refuse invalid edits and loads',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-stack-invalid-'));
  try{
    const root=path.join(temp,'source.comp');await fixture(root);const original=await readProject(root),node=defaultFilterNode('Gaussian Blur'),op={kind:'filterStack',id:IDS[0],nodes:[node]};
    for(const change of [{version:2},{opacity:2},{radius:Infinity},{kind:'Future Filter'},{coverage:'bad'},{future:true},{kind:'Color Lookup'}])assert.throws(()=>editProject(original,{...op,nodes:[{...node,...change}]},codecs));
    assert.throws(()=>editProject(original,{...op,nodes:[node,node]},codecs));
    const locked=editProject(original,{kind:'lock',id:IDS[0],field:'alpha',value:true},codecs);assert.throws(()=>editProject(locked,op,codecs),/locked/);
    const data=editProject(original,op,codecs),manifest=structuredClone(data.manifest);manifest.version=13;assert.throws(()=>parseManifest(Buffer.from(JSON.stringify(manifest))));
    manifest.version=14;manifest.layers[0].editableFilters.sourceFile='../private.png';assert.throws(()=>parseManifest(Buffer.from(JSON.stringify(manifest))));
    const saved=path.join(temp,'saved.comp');await saveProject(data,saved);const nodePath=path.join(saved,'edits',data.manifest.layers[0].editableFilters.nodeFiles[0]);
    const bytes=await readFile(nodePath);await writeFile(nodePath,JSON.stringify({...node,version:99}));await assert.rejects(()=>readProject(saved));await writeFile(nodePath,bytes);
    await rm(path.join(saved,'edits',data.manifest.layers[0].editableFilters.sourceFile));await assert.rejects(()=>readProject(saved));
  }finally{await rm(temp,{recursive:true,force:true});}
});

test('recipe ordering, normal alpha mixing and v15 channel-screen gates remain explicit',()=>{
  const image={width:2,height:1,data:new Uint8ClampedArray([20,80,160,128,220,10,50,255])},noise=defaultFilterNode('Add Noise'),blur=defaultFilterNode('Gaussian Blur');
  noise.seed=123;noise.amount=90;blur.radius=2;
  assert.notDeepEqual(renderFilterStack(image,[noise,blur]).data,renderFilterStack(image,[blur,noise]).data);
  noise.enabled=false;blur.opacity=0;assert.deepEqual(renderFilterStack(image,[noise,blur]).data,image.data);
  const lookup=defaultFilterNode('Color Lookup');lookup.lut.table={name:'white',size:2,is1D:true,minimum:[0,0,0],maximum:[1,1,1],values:[[1,1,1],[1,1,1]]};lookup.opacity=.5;
  assert.deepEqual([...renderFilterStack(image,[lookup]).data],[138,168,208,128,238,133,153,255]);
});

test('saved liquify supports seven tools, freeze/thaw, reconstruction, premultiplied sampling and alpha preservation',()=>{
  const settings={...newLiquify(16,12),diameter:12,fixedEdges:false,strength:1,usesPressure:false},field=new Float32Array(settings.gridWidth*settings.gridHeight*3);
  settings.tool='Freeze';liquifyDab(field,settings,8,6);const frozen=new Float32Array(field);assert.equal(field[(6*16+8)*3+2],1);
  settings.tool='Forward Warp';liquifyDab(field,settings,8,6,3,0);assert.equal(field[(6*16+8)*3],0);
  settings.tool='Thaw';liquifyDab(field,settings,8,6);assert.equal(field[(6*16+8)*3+2],0);
  settings.tool='Forward Warp';liquifyDab(field,settings,8,6,3,0);assert.ok(field[(6*16+8)*3]<0);
  settings.tool='Reconstruct';liquifyDab(field,settings,8,6);assert.equal(field[(6*16+8)*3],0);
  for(const tool of ['Twirl','Pinch','Bloat']){const draft=new Float32Array(field.length);settings.tool=tool;liquifyDab(draft,settings,8,6);assert.ok(draft.some((n,i)=>i%3!==2&&n!==0));}
  const image={width:16,height:12,data:new Uint8ClampedArray(16*12*4)};for(let i=0;i<image.data.length;i+=4){image.data[i]=255;image.data[i+3]=(i/4)%16<8?0:255;}
  const identity={...settings,field:encodeBinary(new Uint8Array(new Float32Array(field.length).buffer))};assert.deepEqual(renderLiquify(image,identity).data,image.data);
  const shift=new Float32Array(field.length);for(let i=0;i<shift.length;i+=3)shift[i]=.5;const saved={...settings,field:encodeBinary(new Uint8Array(shift.buffer)),keepsAlpha:true};const rendered=renderLiquify(image,saved);assert.equal(rendered.data[(6*16+7)*4+3],0);assert.equal(rendered.data[(6*16+8)*4+3],255);assert.equal(rendered.data[(6*16+8)*4],255);
  assert.throws(()=>validateSavedLiquify({...saved,field:'x'},16,12));assert.ok(frozen.some(n=>n===1));
});

test('all seven saved Liquify tools match the macOS C field and opaque renderer',async()=>{
  const fixture=JSON.parse(await readFile(new URL('./golden/liquify-native.json',import.meta.url),'utf8'));
  for(const golden of fixture.cases){
    const settings={...newLiquify(fixture.width,fixture.height),diameter:10,fixedEdges:false,hardness:.3,strength:.6,usesPressure:false,tool:golden.tool},field=new Float32Array(settings.gridWidth*settings.gridHeight*3);
    for(let i=0;i<field.length;i+=3)field.set([.3,-.2,.2],i);
    liquifyDab(field,settings,6,5,2,-1);
    assert.ok(field.every((v,i)=>Math.abs(v-golden.field[i])<.00001),golden.tool+' displacement/freeze field');
    const saved={...settings,field:encodeBinary(new Uint8Array(field.buffer))},image=renderLiquify({width:fixture.width,height:fixture.height,data:new Uint8ClampedArray(fixture.source)},saved);
    assert.ok(image.data.every((v,i)=>Math.abs(v-golden.pixels[i])<=1),golden.tool+' sampled pixels');
  }
});
