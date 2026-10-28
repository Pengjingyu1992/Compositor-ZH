import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm,writeFile}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{ProjectWorkspace}from'../packages/platform/project-workspace.mjs';
import{newProject}from'../packages/comp-bridge/edit.mjs';
import{saveProject}from'../packages/platform/save-project.mjs';
import * as codecs from'../packages/comp-bridge/codecs.mjs';
import{readProject}from'../packages/comp-bridge/project.mjs';

test('tabs preserve independent dirty state, history, selection and revisions without duplicating an open location',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-tabs-')),workspace=new ProjectWorkspace(undefined,{codecs});
  try{
    const first=workspace.create(32,24).project,firstTab=workspace.activeID,firstSession=workspace.active;firstSession.edit(first.id,first.revision,{kind:'add',type:'pixels',name:'First'});const firstRevision=firstSession.revision;
    const second=workspace.create(16,12).project,secondTab=workspace.activeID;assert.notEqual(secondTab,firstTab);assert.equal(workspace.tabs().length,2);assert.equal(workspace.active.undoStack.length,0);
    const restored=workspace.switch(firstTab).project;assert.equal(restored.id,first.id);assert.equal(restored.revision,firstRevision);assert.equal(restored.canUndo,true);assert.equal(restored.dirty,true);
    assert.equal(workspace.active.edit(second.id,second.revision,{kind:'add',type:'group',name:'Stale'}).error,'stale');
    const saved=path.join(temp,'saved.comp');await firstSession.save(restored.id,restored.revision,async()=>({location:saved}));workspace.switch(secondTab);
    const reopened=await workspace.open(saved);assert.equal(workspace.activeID,firstTab);assert.equal(reopened.project.dirty,false);assert.equal(workspace.tabs().length,2);
    const secondSession=workspace.entries.find(entry=>entry.id===secondTab).session;const blocked=await secondSession.save(secondSession.current.id,secondSession.revision,async()=>({location:saved}));assert.equal(blocked.error,'documentOpen');assert.equal(secondSession.current.location,null);
    assert.throws(()=>workspace.close(secondTab),error=>error.code==='unsaved');workspace.close(secondTab,true);assert.equal(workspace.tabs().length,1);
    const before=workspace.active.current;await assert.rejects(()=>workspace.open(path.join(temp,'missing.comp')));assert.equal(workspace.active.current,before);assert.equal(workspace.active.pending,false);
  }finally{for(const session of workspace.sessions)session.close();await rm(temp,{recursive:true,force:true});}
});

test('background disk checks do not lock editing and discard results from superseded revisions',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-external-race-'));let block=false,release,started;const waiting=new Promise(resolve=>started=resolve),gate=new Promise(resolve=>release=resolve),workspace=new ProjectWorkspace(async location=>{if(block){started();await gate;}return readProject(location);},{codecs});
  try{const source=path.join(temp,'source.comp');await saveProject(newProject(8,8),source);const project=(await workspace.open(source)).project;block=true;const reading=workspace.external(project.id,project.revision);await waiting;assert.equal(workspace.busy,false);const edited=workspace.active.edit(project.id,project.revision,{kind:'add',type:'pixels',name:'Kept while checking'});assert.ok(edited.project);await assert.rejects(()=>workspace.external(edited.project.id,edited.project.revision),error=>error.code==='busy');release();await assert.rejects(()=>reading,error=>error.code==='stale');assert.equal(workspace.active.current.data.manifest.layers[0].name,'Kept while checking');assert.equal(workspace.active.pending,false);
  }finally{release();for(const session of workspace.sessions)session.close();await rm(temp,{recursive:true,force:true});}
});

test('tab and retained-memory limits reject additions and edits before consuming state or recovery',()=>{
  const workspace=new ProjectWorkspace(undefined,{codecs},{maxTabs:2});workspace.create(8,8);workspace.create(8,8);const active=workspace.active.current;assert.throws(()=>workspace.create(8,8),error=>error.code==='tabLimit');assert.equal(workspace.active.current,active);
  const limit=new ProjectWorkspace(undefined,{codecs},{maxBytes:1000});const project=limit.create(8,8).project;limit.maxBytes=1;const before=limit.active.current.data,result=limit.active.edit(project.id,project.revision,{kind:'add',type:'pixels',name:'Too much'});assert.equal(result.error,'limit');assert.equal(limit.active.current.data,before);assert.equal(limit.active.undoStack.length,0);assert.equal(limit.active.create(8,8).error,'limit');
});

test('external changes are reported without overwriting current edits and can be ignored until the next disk change',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-external-')),workspace=new ProjectWorkspace(undefined,{codecs});
  try{const source=path.join(temp,'source.comp'),data=newProject(16,12);await saveProject(data,source);let project=(await workspace.open(source)).project;assert.deepEqual(await workspace.external(project.id,project.revision),{changed:false,signature:workspace.active.current.fingerprint});
    const changed={...data.manifest,resolution:144};await writeFile(path.join(source,'manifest.json'),JSON.stringify(changed));const notice=await workspace.external(project.id,project.revision);assert.equal(notice.changed,true);assert.equal(workspace.active.current.data.manifest.resolution,undefined);workspace.ignoreExternal(notice.signature);assert.equal((await workspace.external(project.id,project.revision)).changed,false);
    await writeFile(path.join(source,'manifest.json'),JSON.stringify({...changed,resolution:300}));assert.equal((await workspace.external(project.id,project.revision)).changed,true);const copy=path.join(temp,'copy.comp');await saveProject(data,copy);await assert.rejects(()=>workspace.open(copy),error=>error.code==='documentOpen');assert.equal(workspace.active.current.id,project.id);
    await rm(source,{recursive:true});assert.equal((await workspace.external(project.id,project.revision)).missing,true);
  }finally{for(const session of workspace.sessions)session.close();await rm(temp,{recursive:true,force:true});}
});
