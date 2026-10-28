import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm,readFile}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{RecentProjects}from'../packages/platform/recent-projects.mjs';

test('recent projects stay in memory by default, persist only when enabled, and clear without touching projects',async()=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-recent-'));
  try{const recent=new RecentProjects(temp);await recent.load();const source=path.join(temp,'source.comp');await recent.record(source);assert.equal(recent.view().entries.length,1);assert.equal(recent.view().enabled,false);await assert.rejects(()=>readFile(path.join(temp,'recent-projects.json')),error=>error.code==='ENOENT');assert.equal(JSON.stringify(recent.view()).includes(temp),false);assert.equal(recent.resolve(recent.view().entries[0].id),source);
    await recent.setEnabled(true);const restored=new RecentProjects(temp);await restored.load();assert.equal(restored.resolve(restored.view().entries[0].id),source);assert.equal(restored.enabled,true);
    for(let i=0;i<25;i++)await restored.record(path.join(temp,'project-'+i+'.comp'));assert.equal(restored.view().entries.length,20);assert.equal(restored.view().entries[0].name,'project-24.comp');await restored.record(source);assert.equal(restored.view().entries[0].name,'source.comp');assert.equal(restored.view().entries.length,20);
    await restored.clear();assert.equal(restored.view().entries.length,0);assert.equal((await new RecentProjects(temp).load()).entries.length,0);await restored.setEnabled(false);await assert.rejects(()=>readFile(path.join(temp,'recent-projects.json')));assert.throws(()=>restored.resolve('arbitrary-path'));
  }finally{await rm(temp,{recursive:true,force:true});}
});
