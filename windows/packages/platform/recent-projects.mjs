import{createHash,randomUUID}from'node:crypto';
import{mkdir,writeFile,rename,rm}from'node:fs/promises';
import path from'node:path';
import{safeRead,safeDirectory,ProjectError}from'../comp-bridge/project.mjs';
const validLocation=value=>typeof value==='string'&&value.length<=32768&&path.isAbsolute(value)&&path.extname(value).toLowerCase()==='.comp';
const identity=location=>createHash('sha256').update(process.platform==='win32'?location.toLowerCase():location).digest('hex').slice(0,32);
export class RecentProjects{
  constructor(directory){this.directory=directory;this.enabled=false;this.entries=[];this.queue=Promise.resolve();}
  async load(){try{const record=JSON.parse((await safeRead(path.join(await safeDirectory(this.directory),'recent-projects.json'),1024*1024)).toString('utf8'));if(record.schema!==1||record.enabled!==true||!Array.isArray(record.entries)||record.entries.length>20||record.entries.some(entry=>!validLocation(entry.location)||!Number.isFinite(entry.time)||entry.time<0))throw new ProjectError('invalid');this.enabled=true;this.entries=record.entries.map(entry=>({location:path.resolve(entry.location),time:entry.time}));}catch{this.enabled=false;this.entries=[];}return this.view();}
  view(){return {enabled:this.enabled,entries:this.entries.map(entry=>({id:identity(entry.location),name:path.basename(entry.location),parent:path.basename(path.dirname(entry.location)),time:entry.time}))};}
  resolve(id){const entry=this.entries.find(entry=>identity(entry.location)===id);if(!entry)throw new ProjectError('stale');return entry.location;}
  record(location){if(!validLocation(location))return Promise.resolve();location=path.resolve(location);const id=identity(location);this.entries=[{location,time:Date.now()},...this.entries.filter(entry=>identity(entry.location)!==id)].slice(0,20);return this.persist();}
  setEnabled(enabled){if(typeof enabled!=='boolean')throw new ProjectError('invalid');this.enabled=enabled;return this.persist();}
  clear(){this.entries=[];return this.persist();}
  persist(){let record=this.enabled?JSON.stringify({schema:1,enabled:true,entries:this.entries}):null;while(record&&Buffer.byteLength(record)>1024*1024&&this.entries.length){this.entries.pop();record=JSON.stringify({schema:1,enabled:true,entries:this.entries});}this.queue=this.queue.catch(()=>{}).then(async()=>{await mkdir(this.directory,{recursive:true});const directory=await safeDirectory(this.directory),destination=path.join(directory,'recent-projects.json');if(record===null){await rm(destination,{force:true});return;}const temporary=path.join(directory,'recent-'+randomUUID()+'.tmp');try{await writeFile(temporary,record,{flag:'wx',mode:0o600});await rename(temporary,destination);}finally{await rm(temporary,{force:true});}});return this.queue;}
}
