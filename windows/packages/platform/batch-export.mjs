import{mkdir,writeFile,rename,rm}from'node:fs/promises';
import{randomUUID}from'node:crypto';
import path from'node:path';
import{safeDirectory,ProjectError,pngDimensions,LIMITS}from'../comp-bridge/project.mjs';
import{batchOptions,batchTargets}from'../comp-bridge/batch-export.mjs';

// One raster is retained at a time. Files become visible as a batch only after
// all targets succeed; cancellation never publishes a partially filled folder.
export class BatchExportRun{
  static async create(directory,manifest,name,options,selected,encode,progress=()=>{}){
    const validated=batchOptions(options,manifest.width,manifest.height),targets=batchTargets(manifest,validated,selected,name),parent=await safeDirectory(directory),id=randomUUID(),label='Export-'+new Date().toISOString().replace(/[:.]/g,'-')+'-'+id.slice(0,8),stage=path.join(parent,'.'+label+'.partial');
    await mkdir(stage,{mode:0o700});return new BatchExportRun({id,stage,destination:path.join(parent,label),manifest,options:validated,targets,encode,progress});
  }
  constructor(values){Object.assign(this,values);this.index=0;this.completed=0;this.bytes=0;this.total=this.targets.length*this.options.dimensions.length;this.aborted=false;this.finished=false;this.queue=Promise.resolve();}
  check(){if(this.aborted||this.finished)throw new ProjectError('canceled');}
  append(index,png){
    const task=this.queue.then(async()=>{this.check();if(index!==this.index||index>=this.targets.length)throw new ProjectError('stale');if(!(png instanceof Uint8Array)||png.byteLength>LIMITS.asset)throw new ProjectError('limit');png=Buffer.from(png);const dimensions=pngDimensions(png);if(dimensions.width!==this.manifest.width||dimensions.height!==this.manifest.height)throw new ProjectError('invalid');
      for(const dimension of this.options.dimensions){this.check();const output=await this.encode(png,{format:this.options.format,quality:this.options.quality,size:dimension.side,resolution:this.manifest.resolution??72});this.check();this.bytes+=output.length;if(this.bytes>1024**3)throw new ProjectError('limit');await writeFile(path.join(this.stage,this.targets[index].name+'_'+dimension.key+(this.options.format==='jpeg'?'.jpg':'.png')),output,{flag:'wx',mode:0o600});this.completed++;this.progress(this.completed,this.total);}
      this.index++;return{completed:this.completed,total:this.total};
    });this.queue=task;return task;
  }
  async finish(){await this.queue;this.check();if(this.index!==this.targets.length)throw new ProjectError('invalid');await rename(this.stage,this.destination);this.finished=true;return{exported:true,folder:path.basename(this.destination),completed:this.completed,total:this.total};}
  async cancel(){this.aborted=true;await this.queue.catch(()=>{});if(!this.finished)await rm(this.stage,{recursive:true,force:true});}
}
