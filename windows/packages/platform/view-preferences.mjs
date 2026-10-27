import{mkdir,rename,writeFile,rm}from'node:fs/promises';
import{randomUUID}from'node:crypto';
import path from'node:path';
import{safeRead,safeDirectory}from'../comp-bridge/project.mjs';
import{DEFAULT_VIEW_SETTINGS,validateViewSettings}from'../comp-bridge/view-settings.mjs';
export class ViewPreferences{
  constructor(directory){this.directory=directory;this.queue=Promise.resolve();}
  async read(){await this.queue.catch(()=>{});try{const bytes=await safeRead(path.join(await safeDirectory(this.directory),'workspace.json'),65536),record=JSON.parse(bytes.toString('utf8'));if(record.schema!==1)throw new Error('invalid');return validateViewSettings(record.settings);}catch{return structuredClone(DEFAULT_VIEW_SETTINGS);}}
  write(value){const settings=validateViewSettings(value);this.queue=this.queue.catch(()=>{}).then(async()=>{await mkdir(this.directory,{recursive:true});const directory=await safeDirectory(this.directory),temporary=path.join(directory,'workspace-'+randomUUID()+'.tmp');try{await writeFile(temporary,JSON.stringify({schema:1,settings}),{flag:'wx',mode:0o600});await rename(temporary,path.join(directory,'workspace.json'));}finally{await rm(temporary,{force:true});}return settings;});return this.queue;}
}
