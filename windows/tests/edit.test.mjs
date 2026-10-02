import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { editProject, projectData, ADJUSTMENTS, EFFECTS } from '../packages/comp-bridge/edit.mjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { readProject, resourceDigests } from '../packages/comp-bridge/project.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { saveProject, fingerprint, recoverSaves, RecoveryStore } from '../packages/platform/save-project.mjs';
import { fixture, IDS, manifest, png } from './fixtures.mjs';
async function sample(t) { const directory=await mkdtemp(path.join(os.tmpdir(),'comp-editor-'));t.after(()=>rm(directory,{recursive:true,force:true}));const location=path.join(directory,'source.comp');await fixture(location);return {directory,location,data:await readProject(location)}; }
const change = (data,op) => editProject(data,{id:IDS[0],...op},codecs);
test('all adjustment/effect families produce schema-valid candidates',async t=>{
  const {data}=await sample(t);
  for(const adjustment of ADJUSTMENTS){const a=change(data,{kind:'add',type:'adjustment',adjustment,name:adjustment});assert.equal(a.manifest.layers.at(-1).adjustment.kind,adjustment);assert.deepEqual(a.analysis.issues,[]);}
  for(const effect of EFFECTS){const a=change(data,{kind:'effect',effect});assert.ok(a.manifest.layers[0].effects[effect]);assert.deepEqual(a.analysis.issues,[]);}
});
test('failed batch is atomic and retains redo; revision and document gates reject old callers',async t=>{
  const {data}=await sample(t),s=new ProjectSession(undefined,{codecs});s.install(data,null,true);
  const id=s.current.id;s.edit(id,s.revision,{kind:'rename',id:IDS[0],name:'Changed'});s.history(id,s.revision,'undo');
  const revision=s.revision,before=s.current.data;
  const result=s.edit(id,revision,{kind:'batch',operations:[{kind:'rename',id:IDS[0],name:'Partial'},{kind:'appearance',id:IDS[1],field:'opacity',value:-1}]});
  assert.ok(result.error);assert.equal(s.current.data,before);assert.equal(s.revision,revision);assert.equal(s.redoStack.length,1);
  s.history(id,revision,'redo');assert.equal(s.edit(id,revision,{kind:'rename',id:IDS[0],name:'Stale'}).error,'stale');
  s.create(8,8);assert.equal(s.edit(id,s.revision,{kind:'rename',id:IDS[0],name:'Wrong document'}).error,'stale');
});
test('unknown nested fields and opaque resources survive allowed renames and saving',async t=>{
  const {directory,location}=await sample(t);const m=JSON.parse(await readFile(path.join(location,'manifest.json')));m.future={nested:[1,2]};m.layers[0].transform.future=42;await writeFile(path.join(location,'manifest.json'),JSON.stringify(m));await mkdir(path.join(location,'future'));await writeFile(path.join(location,'future/data.bin'),Buffer.from([255,3]));
  const a=await readProject(location),b=change(a,{kind:'rename',name:'中文 / English'});
  assert.equal(b.manifest.layers[0].transform.future,42);assert.deepEqual(b.manifest.future,m.future);assert.deepEqual(resourceDigests(a),resourceDigests(b));
  assert.throws(()=>change(a,{kind:'appearance',field:'opacity',value:.5}),e=>e.code==='unsupported');
  const copy=path.join(directory,'copy.comp');await saveProject(b,copy);const loaded=await readProject(copy);assert.deepEqual(loaded.manifest,b.manifest);assert.deepEqual(resourceDigests(loaded),resourceDigests(b));
});
test('painting deletes invalidated editable text/shape metadata but retains unrelated bytes',async t=>{
  const {data}=await sample(t),m=structuredClone(data.manifest);m.layers[0].text={content:'中文',fontName:'Test'};m.layers[0].shape={kind:'rectangle'};const a=projectData(m,data.resources),b=change(a,{kind:'pixels',target:'content',png:new Uint8Array(png(64,48,[5,6,7,128]))});
  assert.equal(b.manifest.layers[0].text,undefined);assert.equal(b.manifest.layers[0].shape,undefined);assert.deepEqual(b.resources.get(`images/${IDS[1]}.png`).bytes,data.resources.get(`images/${IDS[1]}.png`).bytes);
});
test('group moves propagate to children; deleting clipping source removes dangling links',async t=>{
  const {data}=await sample(t);let a=change(data,{kind:'add',type:'group',name:'Group'}),group=a.manifest.layers.at(-1).id;
  for(const id of IDS.slice(0,2))a=change(a,{kind:'parent',id,parentID:group});
  a=change(a,{kind:'transform',id:group,field:'origin',value:[12,-3]});assert.deepEqual(a.manifest.layers[0].transform.origin,[12,-3]);
  a=change(a,{kind:'clip',id:IDS[1],sourceID:IDS[0]});a=change(a,{kind:'delete',id:IDS[0]});assert.equal(a.manifest.layers.find(l=>l.id===IDS[1]).maskSourceID,undefined);
});
test('mask create/invert/link and duplicate keep grayscale masks and UUID filenames',async t=>{
  const {data}=await sample(t);let a=change(data,{kind:'mask',action:'add'});a=change(a,{kind:'mask',action:'invert'});a=change(a,{kind:'mask',action:'link',value:false});
  assert.equal(a.manifest.layers[0].maskLinked,false);assert.equal(a.resources.get(`images/${IDS[0]}.mask.png`).bytes[25],0);
  a=change(a,{kind:'duplicate'});const l=a.manifest.layers[1];assert.notEqual(l.id,IDS[0]);assert.equal(l.imageFile,`${l.id}.png`);assert.equal(l.maskFile,`${l.id}.mask.png`);
});
test('save refuses external modifications and keeps the complete original on failure',async t=>{
  const {data,location,directory}=await sample(t),edited=change(data,{kind:'rename',name:'Edited'}),expected=fingerprint(data);
  const external=Buffer.from(JSON.stringify({...data.manifest,resolution:300}));await writeFile(path.join(location,'manifest.json'),external);
  await assert.rejects(()=>saveProject(edited,location,expected,path.join(directory,'journals')),e=>e.code==='changed');assert.deepEqual(await readFile(path.join(location,'manifest.json')),external);
});
test('successful overwrite retains a readable complete backup and clears dirty only for saved snapshot',async t=>{
  const {data,location,directory}=await sample(t),s=new ProjectSession(undefined,{codecs,journalDirectory:path.join(directory,'journals')});s.install(data,location,true);
  s.edit(s.current.id,s.revision,{kind:'rename',id:IDS[0],name:'Saved'});const result=await s.save(s.current.id,s.revision,c=>({location,expected:c.fingerprint}));
  assert.ok(result.backup);assert.equal(result.project.dirty,false);const loaded=await readProject(location);assert.equal(loaded.manifest.layers[0].name,'Saved');s.history(s.current.id,s.revision,'undo');assert.equal(s.view().project.dirty,true);
});
for(const phase of ['afterJournal','afterBackup','afterCommit'])test(`process interruption at ${phase} is recovered without losing the original`,async t=>{
  const {location,directory,data}=await sample(t),registry=path.join(directory,'journals'),child=fileURLToPath(new URL('./save-fault-child.mjs',import.meta.url));
  const r=spawnSync(process.execPath,[child,location,registry,phase],{encoding:'utf8'});assert.equal(r.status,23,r.stderr);
  const result=await recoverSaves(registry);assert.ok(!result.includes('manual'));
  const recovered=await readProject(location);assert.equal(recovered.manifest.layers[0].name,phase==='afterCommit'?'Saved before crash':data.manifest.layers[0].name);
});
test('recovery snapshots preserve old format versions and never mark a session saved',async t=>{
  const {directory,data}=await sample(t),store=new RecoveryStore(path.join(directory,'recovery')),s=new ProjectSession(undefined,{codecs,recovery:store});s.install(data);await s.flushRecovery();
  const items=await store.list();assert.equal(items.length,1);const loaded=await store.restore(items[0].key);assert.deepEqual(loaded.manifest,data.manifest);assert.equal(s.view().project.dirty,true);
  await store.clear(data.manifest.documentID);assert.equal((await store.list()).length,0);s.close();
});
