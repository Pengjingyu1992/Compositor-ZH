import {randomUUID} from 'node:crypto';
import {ProjectError} from '../comp-bridge/project.mjs';
import {projectData} from '../comp-bridge/edit.mjs';
import {checkPermission} from '../comp-bridge/editor-ops.mjs';

const fail=code=>{throw new ProjectError(code);};
const key=id=>id?.toUpperCase();
// Only immutable resources referenced by copied layers are retained. Project
// paths, locks, recovery state and unrelated opaque files never enter this cache.
export function captureLayers(data,ids){
  if(data.analysis.issues.length)fail('unsupported');
  const rows=data.manifest.layers,byID=new Map(rows.map(row=>[key(row.id),row]));
  if(!Array.isArray(ids)||!ids.length||ids.length>10000||ids.some(id=>typeof id!=='string'||!byID.has(key(id))))fail('stale');
  const included=new Set(ids.map(key));
  for(let n=0;n<65;n++){
    let changed=false;
    for(const row of rows){
      if(included.has(key(row.parentID))&&!included.has(key(row.id))){included.add(key(row.id));changed=true;}
      if(included.has(key(row.id))&&row.maskSourceID&&!included.has(key(row.maskSourceID))){included.add(key(row.maskSourceID));changed=true;}
    }
    if(!changed)break;
  }
  const layers=structuredClone(rows.filter(row=>included.has(key(row.id)))),resources=new Map();
  if(data.manifest.animation?.frames.some(frame=>included.has(key(frame.groupID))))fail('unsupported');
  for(const row of layers){
    if(row.parentID&&!included.has(key(row.parentID)))delete row.parentID;
    const files=[...[row.imageFile,row.maskFile].filter(Boolean).map(file=>'images/'+file),...(row.editableFilters?[row.editableFilters.sourceFile,...row.editableFilters.nodeFiles].map(file=>'edits/'+file):[])];
    for(const file of files){const resource=data.resources.get(file);if(!resource)fail('asset');resources.set(file,resource);}
  }
  const buffers=new Set();let bytes=Buffer.byteLength(JSON.stringify(layers));
  for(const resource of resources.values())for(const buffer of [resource.bytes,resource.proxyBytes].filter(Boolean))if(!buffers.has(buffer)){buffers.add(buffer);bytes+=buffer.byteLength;}
  if(bytes>128*1024**2)fail('limit');
  return {layers,resources,version:data.manifest.version,activeID:key(ids.at(-1))};
}

// The bundle is created in the main process, never accepted over renderer IPC.
export function pasteLayers(data,bundle,{targetID,suffix=' (copy)'}={}){
  if(data.analysis.issues.length)fail('unsupported');
  const manifest=structuredClone(data.manifest),resources=new Map(data.resources),target=manifest.layers.find(row=>row.id===targetID);
  if(targetID&&!target)fail('stale');
  const parentID=target?.isGroup?target.id:manifest.layers.find(row=>key(row.id)===key(target?.parentID))?.id;
  checkPermission(data,{kind:'add',parentID});
  if(typeof suffix!=='string'||suffix.length>32)fail('invalid');
  const mapping=new Map(bundle.layers.map(row=>[key(row.id),randomUUID().toUpperCase()]));
  const copies=bundle.layers.map(source=>{
    const row=structuredClone(source);row.id=mapping.get(key(source.id));
    if(row.parentID)row.parentID=mapping.get(key(row.parentID));
    else{row.name=row.name.slice(0,256-suffix.length)+suffix;if(parentID)row.parentID=parentID;}
    if(row.maskSourceID){row.maskSourceID=mapping.get(key(row.maskSourceID));if(!row.maskSourceID)fail('asset');}
    for(const field of ['imageFile','maskFile'])if(row[field]){const file=`${row.id}${field==='maskFile'?'.mask':''}.png`;resources.set('images/'+file,bundle.resources.get('images/'+row[field]));row[field]=file;}
    if(row.editableFilters){const old=row.editableFilters,next={sourceFile:row.id+'.source.png',nodeFiles:old.nodeFiles.map(file=>row.id+file.slice(source.id.length))};resources.set('edits/'+next.sourceFile,bundle.resources.get('edits/'+old.sourceFile));old.nodeFiles.forEach((file,index)=>resources.set('edits/'+next.nodeFiles[index],bundle.resources.get('edits/'+file)));row.editableFilters=next;}
    return row;
  });
  const descendants=new Set(target?[key(target.id)]:[]),clipBase=target&&(target.maskSourceID??target.id);
  for(let n=0;n<64;n++)for(const row of manifest.layers)if(descendants.has(key(row.parentID))||row.maskSourceID&&key(row.maskSourceID)===key(clipBase))descendants.add(key(row.id));
  const index=target?manifest.layers.reduce((after,row,i)=>descendants.has(key(row.id))?i+1:after,0):manifest.layers.length;
  manifest.layers.splice(index,0,...copies);manifest.activeLayerID=mapping.get(bundle.activeID)??copies.at(-1).id;manifest.version=Math.max(manifest.version,bundle.version);
  resources.delete('QuickLook/Preview.jpg');resources.delete('QuickLook/Thumbnail.png');
  const result=projectData(manifest,resources,data.name);
  if(result.analysis.issues.length)fail(result.analysis.issues.includes('memory')?'limit':'unsupported');
  result.locks=data.locks;result.selection=null;return result;
}
