import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,readdir,readFile,rm}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import sharp from'sharp';
import{batchOptions,batchSafeName,batchTargets,isolateBatchRows}from'../packages/comp-bridge/batch-export.mjs';
import{BatchExportRun}from'../packages/platform/batch-export.mjs';
import{encodeOutputImage}from'../packages/platform/image-output.mjs';
import{manifest,png,IDS}from'./fixtures.mjs';
const options={longSides:[0,32,64],format:'png',quality:90,prefix:'Preview / ',individualLayers:false};

test('batch sizing deduplicates actual dimensions, validates targets and creates portable names',()=>{
  const validated=batchOptions(options,64,48);assert.deepEqual(validated.dimensions.map(d=>d.key),['64x48','32x24']);assert.equal(batchSafeName('../CON:*?\\'), '.._CON____');assert.equal(batchSafeName('CON'),'Export-CON');assert.equal(batchSafeName('...'),'Export-');
  for(const change of [{longSides:[]},{longSides:[2,2]},{longSides:[30000]},{quality:NaN},{individualLayers:1},{format:'zip'},{prefix:'x'.repeat(121)}])assert.throws(()=>batchOptions({...options,...change},64,48));
  assert.throws(()=>batchTargets(manifest(),{...validated,individualLayers:true},['unknown'],'Project'));assert.throws(()=>batchTargets(manifest(),{...validated,individualLayers:true},[IDS[0],IDS[0]],'Project'));
});

test('selected groups keep ancestor masks and opacity while hiding unrelated layers without mutating the source',()=>{
  const rows=[{id:'root',isGroup:true,isVisible:false,opacity:.5,maskFile:'root.png'},{id:'group',parentID:'root',isGroup:true,isVisible:false,opacity:.8},{id:'child',parentID:'group',imageFile:'pixel.png',isVisible:true,opacity:.75},{id:'hidden',parentID:'group',imageFile:'hidden.png',isVisible:false},{id:'other',imageFile:'other.png',isVisible:true}];const before=structuredClone(rows),result=isolateBatchRows(rows,'group');assert.deepEqual(rows,before);assert.equal(result[0].isVisible,true);assert.equal(result[0].maskFile,'root.png');assert.equal(result[2].effectiveVisible,true);assert.ok(Math.abs(result[2].effectiveOpacity-.3)<1e-9);assert.equal(result[3].effectiveVisible,false);assert.equal(result[4].effectiveVisible,false);
});

test('batch publishes one complete folder with independent readable outputs and never changes its input',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-batch-')),source=png(64,48,[20,80,160,128]),before=Buffer.from(source),progress=[];
  try{const run=await BatchExportRun.create(temp,manifest(),'Project.comp',options,[],encodeOutputImage,(done,total)=>progress.push([done,total]));assert.deepEqual((await readdir(temp)).filter(name=>!name.startsWith('.')),[]);await run.append(0,source);await assert.rejects(()=>run.append(0,source),error=>error.code==='stale');await run.cancel();assert.deepEqual(await readdir(temp),[]);
    const success=await BatchExportRun.create(temp,manifest(),'Project.comp',{...options,format:'jpeg'},[],encodeOutputImage);await success.append(0,new Uint8Array(source));const result=await success.finish(),files=await readdir(success.destination);assert.equal(result.exported,true);assert.equal(files.length,2);for(const file of files){const meta=await sharp(await readFile(path.join(success.destination,file))).metadata();assert.equal(meta.format,'jpeg');assert.equal(meta.hasAlpha,false);assert.ok([32,64].includes(meta.width));assert.equal(meta.height,meta.width*.75);assert.ok(meta.icc.length);}assert.deepEqual(source,before);assert.deepEqual(progress,[[1,2],[2,2]]);
  }finally{await rm(temp,{recursive:true,force:true});}
});

test('cancel during encoding removes every staged output and refuses later writes',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-batch-cancel-'));let release;const blocked=new Promise(resolve=>release=resolve);let started;const encoding=new Promise(resolve=>started=resolve);
  try{const run=await BatchExportRun.create(temp,manifest(),'Cancel.comp',options,[],async()=>{started();await blocked;return Buffer.from('encoded');});const append=run.append(0,png(64,48,[0,0,0,255]));await encoding;const cancel=run.cancel();release();await assert.rejects(()=>append,error=>error.code==='canceled');await cancel;assert.deepEqual(await readdir(temp),[]);await assert.rejects(()=>run.finish());await assert.rejects(()=>run.append(0,png(64,48,[0,0,0,255])));
  }finally{await rm(temp,{recursive:true,force:true});}
});
