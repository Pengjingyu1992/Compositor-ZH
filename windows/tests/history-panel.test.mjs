import{test}from'node:test';
import assert from'node:assert/strict';
import{ProjectSession}from'../packages/platform/project-session.mjs';
import * as codecs from'../packages/comp-bridge/codecs.mjs';

test('history jumping retains state, redo, saved identity and stale-command protection',()=>{
  const session=new ProjectSession(undefined,{codecs});let project=session.create(32,24).project;
  const edit=op=>{const result=session.edit(project.id,project.revision,op);assert.ok(result.project,result.error);project=result.project;return result;};
  edit({kind:'add',type:'pixels',name:'Layer'});const id=project.manifest.activeLayerID,baseline=session.current.data;session.saved=baseline;
  edit({kind:'appearance',id,field:'opacity',value:.4});edit({kind:'selection',action:'all'});
  assert.equal(project.historyIndex,3);assert.deepEqual(project.historyEntries.map(entry=>entry.kind),['start','add','appearance','selection']);
  const stale=project.revision;project=session.jumpHistory(project.id,project.revision,1).project;assert.equal(project.manifest.layers[0].opacity,undefined);assert.equal(project.selection,undefined);assert.equal(project.dirty,false);assert.equal(project.canRedo,true);
  assert.equal(session.jumpHistory(project.id,stale,3).error,'stale');assert.equal(session.jumpHistory(project.id,project.revision,99).error,'invalid');assert.equal(session.current.data,baseline);
  project=session.jumpHistory(project.id,project.revision,3).project;assert.equal(project.manifest.layers[0].opacity,.4);assert.ok(project.selection.data.every(value=>value===255));
  project=session.jumpHistory(project.id,project.revision,1).project;edit({kind:'rename',id,name:'Branched'});assert.equal(project.canRedo,false);assert.equal(project.historyEntries.at(-1).kind,'rename');assert.equal(project.historyEntries.length,3);
  session.pending=true;assert.equal(session.jumpHistory(project.id,project.revision,0).error,'busy');session.pending=false;session.close();
});

test('history labels stay aligned after budget trimming, undo, redo and new-project installation',()=>{
  const session=new ProjectSession(undefined,{codecs});let project=session.create(16,16).project;
  project=session.edit(project.id,project.revision,{kind:'add',type:'pixels',name:'Layer'}).project;const id=project.manifest.activeLayerID;
  for(let index=0;index<90;index++)project=session.edit(project.id,project.revision,{kind:'rename',id,name:'Layer '+index}).project;
  assert.equal(project.historyIndex,80);assert.equal(project.historyEntries.length,81);assert.equal(project.historyEntries[0].kind,'start');assert.ok(project.historyEntries.slice(1).every(entry=>entry.kind==='rename'));
  project=session.jumpHistory(project.id,project.revision,0).project;assert.equal(project.manifest.layers[0].name,'Layer 9');project=session.jumpHistory(project.id,project.revision,80).project;assert.equal(project.manifest.layers[0].name,'Layer 89');
  project=session.create(32,32).project;assert.deepEqual(project.historyEntries,[{index:0,kind:'start'}]);assert.equal(project.historyIndex,0);session.close();
});
