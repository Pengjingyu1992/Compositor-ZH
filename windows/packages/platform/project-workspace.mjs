import{randomUUID}from'node:crypto';
import{realpath}from'node:fs/promises';
import path from'node:path';
import{ProjectSession}from'./project-session.mjs';
import{readProject,safeDirectory,ProjectError}from'../comp-bridge/project.mjs';
import{newProject}from'../comp-bridge/edit.mjs';
import{fingerprint}from'./save-project.mjs';

export class ProjectWorkspace{
  constructor(reader=readProject,options={},limits={}){
    this.reader=reader;this.options=options;this.maxTabs=limits.maxTabs??8;this.maxBytes=limits.maxBytes??512*1024**2;this.pending=false;this.seenExternal=new Map();
    const initial=this.entry();this.entries=[initial];this.activeID=initial.id;
  }
  entry(){return{id:randomUUID(),session:new ProjectSession(this.reader,{...this.options,validateRetained:(data,session,replacing)=>this.validateRetained(data,session,replacing),validateSave:(location,session)=>this.validateSave(location,session)})};}
  get active(){return this.entries.find(entry=>entry.id===this.activeID).session;}
  get sessions(){return this.entries.map(entry=>entry.session);}
  get busy(){return this.pending||this.sessions.some(session=>session.pending);}
  guard(){if(this.busy)throw new ProjectError('busy');}
  tabs(){return this.entries.filter(entry=>entry.session.current).map(entry=>({id:entry.id,projectID:entry.session.current.id,name:entry.session.current.data.name,dirty:entry.session.isDirty(),active:entry.id===this.activeID}));}
  state(){return{tabs:this.tabs(),activeID:this.activeID};}
  validateRetained(candidate,owner,replacing){
    if(this.sessions.some(session=>session!==owner&&session.current?.data.manifest.documentID.toUpperCase()===candidate.manifest.documentID.toUpperCase()))throw new ProjectError('documentOpen');
    const seen=new Set();let bytes=0;const add=buffer=>{if(buffer&&!seen.has(buffer)){seen.add(buffer);bytes+=buffer.byteLength??buffer.length??0;}};
    const states=[];for(const session of this.sessions??[]){if(session===owner&&replacing)continue;states.push(session.current?.data,session.saved,...session.undoStack,...session.redoStack);}states.push(candidate);
    for(const data of states.filter(Boolean)){add(data.sourceBytes);add(data.selection?.data);for(const resource of data.resources.values()){add(resource.bytes);add(resource.proxyBytes);}}
    if(bytes>this.maxBytes)throw new ProjectError('limit');
  }
  async validateSave(location,owner){
    const canonical=async value=>{try{return await realpath(value);}catch{return path.join(await safeDirectory(path.dirname(value)),path.basename(value));}},key=value=>process.platform==='win32'?value.toLowerCase():value;
    const destination=key(await canonical(location));
    for(const session of this.sessions){if(session===owner||!session.current?.location)continue;if(key(await canonical(session.current.location))===destination)throw new ProjectError('documentOpen');}
  }
  add(data,location=null,saved=false){
    if(this.tabs().length>=this.maxTabs)throw new ProjectError('tabLimit');
    if(this.sessions.some(session=>session.current?.data.manifest.documentID.toUpperCase()===data.manifest.documentID.toUpperCase()))throw new ProjectError('documentOpen');
    const entry=this.entry();entry.session.install(data,location,saved);
    if(!this.active.current){const index=this.entries.findIndex(entry=>entry.id===this.activeID);this.entries.splice(index,1);}
    this.entries.push(entry);this.activeID=entry.id;return this.active.view();
  }
  create(width,height){this.guard();return this.add(newProject(width,height));}
  async open(location){
    this.guard();if(!location)return{canceled:true};const previous=this.active;this.pending=true;previous.pending=true;
    try{
      const canonical=await safeDirectory(location),key=value=>process.platform==='win32'?value.toLowerCase():value;
      for(const entry of this.entries){if(!entry.session.current?.location)continue;let existing;try{existing=await realpath(entry.session.current.location);}catch{continue;}if(key(existing)===key(canonical)){this.activeID=entry.id;return this.active.view();}}
      if(this.tabs().length>=this.maxTabs)throw new ProjectError('tabLimit');
      const data=await this.reader(canonical);return this.add(data,canonical,true);
    }finally{previous.pending=false;this.pending=false;}
  }
  switch(id){this.guard();if(!this.entries.some(entry=>entry.id===id&&entry.session.current))throw new ProjectError('stale');this.activeID=id;return this.active.view();}
  close(id,discard=false){
    this.guard();const index=this.entries.findIndex(entry=>entry.id===id),entry=this.entries[index];if(!entry?.session.current)throw new ProjectError('stale');if(entry.session.isDirty()&&!discard)throw new ProjectError('unsaved');
    entry.session.close();this.entries.splice(index,1);this.seenExternal.delete(id);
    if(!this.entries.length){const initial=this.entry();this.entries.push(initial);this.activeID=initial.id;}else if(id===this.activeID)this.activeID=this.entries[Math.min(index,this.entries.length-1)].id;
    return{closed:true,...(this.active.current?this.active.view():{})};
  }
  async external(id,revision){
    this.guard();if(this.checking)throw new ProjectError('busy');const entry=this.entries.find(entry=>entry.session.current?.id===id),session=entry?.session;if(!session||session!==this.active||session.revision!==revision)throw new ProjectError('stale');
    if(!session.current.location)return{changed:false};const current=session.current;this.checking=true;
    const stale=()=>session.current!==current||session!==this.active||session.revision!==revision||this.busy;
    try{const data=await this.reader(current.location);if(stale())throw new ProjectError('stale');const digest=fingerprint(data),changed=digest!==current.fingerprint&&digest!==this.seenExternal.get(entry.id);return{changed,signature:digest};}
    catch(error){if(error.code==='stale'||stale())throw new ProjectError('stale');return{changed:true,missing:true};}
    finally{this.checking=false;}
  }
  ignoreExternal(signature){if(typeof signature==='string'&&/^[a-f0-9]{64}$/.test(signature))this.seenExternal.set(this.activeID,signature);}
}
