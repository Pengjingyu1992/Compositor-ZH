import{test}from'node:test';
import assert from'node:assert/strict';
import sharp from'sharp';
import{newProject,editProject}from'../packages/comp-bridge/edit.mjs';
import{ImageImportRun,insertImportedImage}from'../packages/platform/image-import.mjs';
import{decodeSourceImage}from'../packages/platform/image-pipeline.mjs';
import{ProjectSession}from'../packages/platform/project-session.mjs';
import*as codecs from'../packages/comp-bridge/codecs.mjs';
import{png}from'./fixtures.mjs';
const edit=(data,op)=>editProject(data,op,codecs),decode=(bytes,signal)=>{if(signal?.aborted)throw Object.assign(new Error('canceled'),{code:'canceled'});return decodeSourceImage(bytes);};
test('original PNG import keeps session locks and selection, applies orientation and retains source bytes',async()=>{
  let data=edit(newProject(64,48),{kind:'add',type:'pixels',name:'Existing'}),old=data.manifest.activeLayerID;data=edit(data,{kind:'lock',id:old,field:'content',value:true});data=edit(data,{kind:'selection',action:'all'});
  const bytes=await sharp({create:{width:2,height:3,channels:4,background:{r:180,g:90,b:45,alpha:.5}}}).withMetadata({orientation:6,density:300}).withIccProfile('p3').toColourspace('rgb16').png().toBuffer(),resource=await decodeSourceImage(bytes),result=insertImportedImage(data,resource,{name:'Profile PNG',point:[20,18],targetID:old},codecs),row=result.manifest.layers.find(row=>row.id===result.manifest.activeLayerID);
  assert.equal(result.locks,data.locks);assert.equal(result.selection,data.selection);assert.equal(result.manifest.version,17);assert.deepEqual(row.transform.origin,[18,17]);assert.deepEqual(row.transform.size,[3,2]);assert.deepEqual(result.resources.get('images/'+row.imageFile).bytes,bytes);assert.equal(result.resources.get('images/'+row.imageFile).proxyBytes[24],8);assert.equal(data.manifest.layers.length,1);
});
test('a multi-image candidate retains order, determines the first canvas, centers later images and commits as one undo step',async()=>{
  const records=[{name:'First.png',bytes:png(20,12,[240,100,40,255])},{name:'Second.png',bytes:png(4,2,[40,100,240,128])}],progress=[],run=new ImageImportRun(records,{point:[250,250]}),candidate=await run.build(null,codecs,decode,value=>progress.push(value));
  assert.equal(candidate.manifest.width,20);assert.equal(candidate.manifest.height,12);assert.equal(candidate.name,'First.comp');assert.deepEqual(candidate.manifest.layers.map(row=>row.name),['First.png','Second.png']);assert.deepEqual(candidate.manifest.layers.map(row=>row.transform.origin),[[0,0],[8,5]]);assert.deepEqual(progress.map(row=>row.completed),[0,1,2]);assert.equal(run.records.length,0);
  let data=edit(newProject(64,48),{kind:'add',type:'group',name:'Folder'}),targetID=data.manifest.activeLayerID;const next=await new ImageImportRun(records,{targetID,point:[20,18]}).build(data,codecs,decode);for(const row of next.manifest.layers.filter(row=>!row.isGroup))assert.equal(row.parentID,targetID);const session=new ProjectSession(undefined,{codecs});session.install(data,null,true);session.commit(data,next,{kind:'importPixels'});assert.equal(session.undoStack.length,1);session.history(session.current.id,session.revision,'undo');assert.equal(session.current.data,data);assert.equal(session.isDirty(),false);session.close();
});
test('a failed later image and canceled decode never publish partial images or consume project history',async()=>{
  const data=newProject(64,48),session=new ProjectSession(undefined,{codecs});session.install(data,null,true);const original=session.current.data,run=new ImageImportRun([{name:'Good.png',bytes:png(4,2,[20,40,60,255])},{name:'Bad.png',bytes:new Uint8Array([1,2,3])}]);await assert.rejects(()=>run.build(data,codecs,decode),error=>error.code==='asset');assert.equal(session.current.data,original);assert.equal(session.undoStack.length,0);assert.equal(run.records.length,0);
  const canceled=new ImageImportRun([{name:'Pending.png',bytes:png(4,2,[20,40,60,255])}]);let started;const entered=new Promise(resolve=>started=resolve),pending=canceled.build(data,codecs,async(bytes,signal)=>{started();await new Promise(resolve=>signal.addEventListener('abort',resolve,{once:true}));throw Object.assign(new Error('canceled'),{code:'canceled'});});await entered;canceled.cancel();await assert.rejects(()=>pending,error=>error.code==='canceled');assert.equal(canceled.records.length,0);assert.equal(session.current.data,original);session.close();
});
test('image batch limits, unsafe names, stale destinations and locked ancestors are refused',async()=>{
  const bytes=png(4,2,[20,40,60,255]),record={name:'Image.png',bytes};for(const records of [[],Array(33).fill(record),[{name:'../Image.png',bytes}],[{location:'relative/Image.png'}],[{name:'Image.png',bytes:new Uint8Array()}],[{name:'Animation.gif',bytes}],[{name:'Project.comp',bytes}]])assert.throws(()=>new ImageImportRun(records));
  assert.throws(()=>new ImageImportRun([record],{point:[Infinity,0]}));assert.throws(()=>new ImageImportRun([record],{targetID:42}));
  let data=edit(newProject(64,48),{kind:'add',type:'group',name:'Locked'}),targetID=data.manifest.activeLayerID;data=edit(data,{kind:'lock',id:targetID,field:'content',value:true});await assert.rejects(()=>new ImageImportRun([record],{targetID}).build(data,codecs,decode),error=>error.code==='locked');await assert.rejects(()=>new ImageImportRun([record],{targetID:crypto.randomUUID()}).build(data,codecs,decode),error=>error.code==='stale');
});
