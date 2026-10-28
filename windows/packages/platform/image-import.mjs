import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {safeRead,safeDirectory,ProjectError,LIMITS} from '../comp-bridge/project.mjs';
import {newProject,editProject,projectData} from '../comp-bridge/edit.mjs';

const fail=code=>{throw new ProjectError(code);};
export function insertImportedImage(data,resource,{name,targetID,point}={},codecs){
  const target=data.manifest.layers.find(row=>row.id===targetID);
  if(targetID&&!target)fail('stale');
  if(point!==undefined&&(!Array.isArray(point)||point.length!==2||point.some(value=>!Number.isFinite(value)||Math.abs(value)>300000)))fail('invalid');
  const parentID=target?.isGroup?target.id:data.manifest.layers.find(row=>row.id.toUpperCase()===target?.parentID?.toUpperCase())?.id;
  const center=point??[data.manifest.width/2,data.manifest.height/2],origin=[Math.floor(center[0]-resource.width/2),Math.floor(center[1]-resource.height/2)];
  const candidate=editProject(data,{kind:'importPixels',name:String(name??'Image').slice(0,256),png:resource.proxyBytes??resource.bytes,origin,parentID,aboveID:target?.id},codecs);
  if(!resource.originalPNG)return candidate;
  const manifest=structuredClone(candidate.manifest),layer=manifest.layers.find(row=>row.id===manifest.activeLayerID),resources=new Map(candidate.resources);
  resources.set('images/'+layer.imageFile,resource);manifest.version=Math.max(manifest.version,17);
  // Revalidating the resource map must preserve session-only protection state.
  const result=projectData(manifest,resources,candidate.name);result.locks=candidate.locks;result.selection=candidate.selection;return result;
}

export class ImageImportRun{
  constructor(records,options={}){
    if(!Array.isArray(records)||!records.length||records.length>32)fail('drop');
    if(!options||typeof options!=='object'||options.targetID!==undefined&&typeof options.targetID!=='string'||options.point!==undefined&&(!Array.isArray(options.point)||options.point.length!==2||options.point.some(value=>!Number.isFinite(value)||Math.abs(value)>300000)))fail('invalid');
    this.id=randomUUID();this.controller=new AbortController();this.options=options;this.records=records.map(record=>{
      if(/\.(?:comp|gif|eps|epsf|epsi|psd|psb)$/i.test(record?.location??record?.name??''))fail('drop');
      if(record&&typeof record.location==='string'&&path.isAbsolute(record.location)&&record.location.length<=32768)return{location:record.location};
      if(!record||typeof record.name!=='string'||!record.name.length||record.name.length>256||/[\\/\0]/.test(record.name)||!(record.bytes instanceof Uint8Array)||!record.bytes.byteLength||record.bytes.byteLength>LIMITS.asset)fail('path');
      return{name:record.name,bytes:record.bytes};
    });
    if(this.records.reduce((total,record)=>total+(record.bytes?.byteLength??0),0)>128*1024**2)fail('limit');
  }
  cancel(){this.controller.abort();}
  check(){if(this.controller.signal.aborted)fail('canceled');}
  async build(data,codecs,decode,onProgress=()=>{}){
    if(this.started)fail('invalid');this.started=true;
    const total=this.records.length;let candidate=data,targetID=this.options.targetID,encoded=0;
    try{
      onProgress({jobID:this.id,completed:0,total});
      for(let index=0;index<total;index++){
        this.check();const record=this.records[index],name=record.location?path.basename(record.location):record.name;
        const bytes=record.location?await safeRead(path.join(await safeDirectory(path.dirname(record.location)),name),LIMITS.asset):record.bytes;
        encoded+=bytes.byteLength;if(encoded>128*1024**2)fail('limit');this.check();
        const decoded=await decode(bytes,this.controller.signal);this.check();
        const resource={...decoded,bytes:Buffer.from(decoded.bytes),...(decoded.proxyBytes?{proxyBytes:Buffer.from(decoded.proxyBytes)}:{})};
        if(!candidate){candidate=newProject(resource.width,resource.height,resource.resolution);candidate.name=name.replace(/\.[^.]+$/,'')+'.comp';}
        const point=data?this.options.point:undefined;
        candidate=insertImportedImage(candidate,resource,{name,targetID,point},codecs);targetID=candidate.manifest.activeLayerID;this.records[index]=undefined;
        onProgress({jobID:this.id,completed:index+1,total});
      }
      this.check();return candidate;
    }finally{this.records=[];}
  }
}
