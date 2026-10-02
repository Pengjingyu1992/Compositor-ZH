import { randomUUID } from 'node:crypto';
import { supportsAdjustment } from './capabilities.mjs';
import { ProjectError, LIMITS } from './project.mjs';
import { bounds, union, arrange, shapeMask, combineMasks, modifyMask, floodMask, validSurface, toLocal, toDocument, selectionCoverage, following } from './editor-math.mjs';
import { fillPixels, strokePixels, resizePixels, applySelectedFilter, FILTERS } from './raster-tools.mjs';
const fail = c => { throw new ProjectError(c); };
const finite = (v,a=-300000,b=300000) => typeof v==='number' && Number.isFinite(v) && v>=a && v<=b;
const pair = v => Array.isArray(v) && v.length===2 && v.every(n=>finite(n));
const rgb = v => Array.isArray(v) && v.length===3 && v.every(n=>finite(n,0,255));
const place = (w,h) => ({origin:[0,0],size:[w,h],rotation:0,flipX:false,flipY:false,sampling:'High quality'});
export const GLOBAL_OPS = ['selection','lock','canvas','imageSize','arrange','group','merge','guides','flipCanvas','moveLayers','transformLayers'];
export function operationTargets(m,op) {
  const all=['canvas','imageSize','flipCanvas'].includes(op.kind),ids=all?m.layers.map(l=>l.id):op.ids??(op.id?[op.id]:[]);
  if(!Array.isArray(ids)||ids.length>10000||ids.some(id=>typeof id!=='string'||!m.layers.some(l=>l.id===id)))fail('stale');
  const found=new Set(ids.map(id=>id.toUpperCase()));for(let n=0;n<64;n++)for(const l of m.layers)if(found.has(l.parentID?.toUpperCase()))found.add(l.id.toUpperCase());
  return m.layers.filter(l=>found.has(l.id.toUpperCase()));
}
export function checkPermission(data,op) {
  if(op.kind==='batch'){for(const item of op.operations??[])checkPermission(data,item);return;}
  if(['selection','lock','rename','guides'].includes(op.kind))return;
  const inserting=['add','importPixels'].includes(op.kind)||(op.kind==='styled'&&!op.id);
  const dimensions=['group','ungroup','reorder','parent','merge'].includes(op.kind)?['content','position']:['transform','transformMask','transformLayers','moveLayers','arrange','canvas','imageSize','flipCanvas'].includes(op.kind)?['position']:op.kind==='appearance'?['appearance']:['content'];
  const targets=inserting?[]:operationTargets(data.manifest,op);
  if(op.parentID){const parent=data.manifest.layers.find(l=>l.id===op.parentID);if(!parent?.isGroup)fail('invalid');targets.push(parent);}
  for(const l of targets) {
    let row=l;for(let n=0;row&&n<65;n++,row=data.manifest.layers.find(v=>v.id.toUpperCase()===row.parentID?.toUpperCase()))if(dimensions.some(d=>data.locks?.[row.id]?.[d]))fail('locked');
  }
}
export function selectionEdit(data,op,codecs) {
  const {width:w,height:h}=data.manifest;validSurface(w,h);let next;
  if(op.action==='none')next=null;
  else if(op.action==='all')next=new Uint8Array(w*h).fill(255);
  else if(['invert','expand','contract','feather'].includes(op.action)){
    if(!finite(op.amount??0,0,500))fail('invalid');next=modifyMask(data.selection?.data??new Uint8Array(w*h),w,h,op.action,op.amount??0);
  }else{
    if(!['replace','add','subtract','intersect'].includes(op.combine??'replace'))fail('invalid');
    if(op.action==='wand'){
      if(!pair(op.start)||!finite(op.tolerance??24,0,255)||typeof op.contiguous!=='boolean')fail('invalid');
      const image=codecs.decodePNG(codecs.validatePNG(op.png));if(image.width!==w||image.height!==h)fail('invalid');
      next=floodMask(image,Math.floor(op.start[0]),Math.floor(op.start[1]),op.tolerance??24,op.contiguous);
    }else{
      if(!['rectangle','ellipse','lasso'].includes(op.action)||!pair(op.start)||!pair(op.end)||!Array.isArray(op.points??[])||(op.points??[]).length>10000||(op.points??[]).some(p=>!pair(p)))fail('invalid');
      next=shapeMask(w,h,op.action,op.start,op.end,op.points??[]);
    }
    next=combineMasks(data.selection?.data,next,op.combine??'replace');
  }
  return {...data,selection:next?{width:w,height:h,data:next}:null,contentSnapshot:data.contentSnapshot??data};
}
function settings(op) {
  if(JSON.stringify(op.settings??{}).length>1048576)fail('limit');
  const s=structuredClone(op.settings??{});
  for(const [k,a,b] of [['size',1,500],['opacity',0,1],['hardness',0,1],['spacing',.01,2],['sectors',2,16],['tolerance',0,255],['radius',0,200],['amount',0,100],['distance',0,1000],['angle',-360,360],['levels',2,32],['exposure',-10,10],['contrast',-100,100],['saturation',-100,100],['temperature',-100,100],['distortion',-100,100]])if(s[k]!==undefined&&!finite(s[k],a,b))fail('invalid');
  for(const k of ['color','background'])if(s[k]!==undefined&&!rgb(s[k]))fail('invalid');
  if(s.points!==undefined&&(!Array.isArray(s.points)||!s.points.length||s.points.length>10000||s.points.some(p=>!Array.isArray(p)||p.length<2||p.length>3||!p.every(v=>finite(v)))))fail('invalid');
  if(s.source!==undefined&&!pair(s.source))fail('invalid');
  if(s.symmetry!==undefined&&!['none','horizontal','vertical','both','radial'].includes(s.symmetry))fail('invalid');
  if(s.mode!==undefined&&!['brush','eraser','clone','healing','blur','smudge','liquify'].includes(s.mode))fail('invalid');
  return s;
}
function validateStyle(kind,s) {
  if(!s||typeof s!=='object')fail('invalid');
  for(const c of ['red','green','blue'])if(!finite(s[c],0,1))fail('invalid');
  if(kind==='text'){
    if(typeof s.content!=='string'||!s.content.length||s.content.length>100000||typeof s.fontName!=='string'||s.fontName.length>200||/[\r\n]/.test(s.fontName)||!finite(s.fontSize,1,2000)||!['Left','Center','Right'].includes(s.alignment)||!finite(s.tracking,-100,1000)||!finite(s.leading,0,5000)||!pair(s.boxSize)||s.boxSize.some(n=>n<16))fail('invalid');
    for(const field of ['colorRuns','fontRuns']){let end=0;if(!Array.isArray(s[field]??[])||(s[field]??[]).length>10000)fail('invalid');for(const r of s[field]??[]){if(!Number.isInteger(r.location)||!Number.isInteger(r.length)||r.location<end||r.length<1||r.location+r.length>s.content.length)fail('invalid');end=r.location+r.length;if(field==='colorRuns'&&!['red','green','blue'].every(c=>finite(r[c],0,1)))fail('invalid');if(field==='fontRuns'&&(typeof r.fontName!=='string'||r.fontName.length>200||/[\r\n]/.test(r.fontName)))fail('invalid');}}
  }else if(!['Rectangle','Ellipse','Line'].includes(s.kind)||!finite(s.cornerRadius,0,30000)||!finite(s.lineWidth,0,2000)||!pair(s.start)||!pair(s.end)||[...s.start,...s.end].some(n=>n<0||n>1))fail('invalid');
}
// Shared operations construct a local candidate. No mutation reaches the live
// session until projectData validates the complete manifest and all resources.
export function editorOperation(data,m,resources,target,op,codecs,descendants) {
  const layerFile=l=>`images/${l.imageFile}`, shift=(ids,dx,dy,carryAll=false)=>{for(const l of m.layers)if(ids.has(l.id.toUpperCase())){l.transform.origin=l.transform.origin.map((v,i)=>v+(i?dy:dx));if(l.maskPlacement&&(carryAll||l.maskLinked!==false))l.maskPlacement.origin=l.maskPlacement.origin.map((v,i)=>v+(i?dy:dx));}};
  const roots=ids=>m.layers.filter(l=>ids.includes(l.id)&&!m.layers.some(p=>p.id!==l.id&&ids.includes(p.id)&&descendants(p.id).has(l.id.toUpperCase())));
  switch(op.kind){
    case 'stroke':case 'fill':case 'gradient':case 'bucket':case 'filter':case 'clear':{
      const mask=op.target==='mask',file=mask?target.maskFile:target.imageFile;if(!file||(!mask&&(target.isGroup||target.adjustment)))fail('unsupported');
      const t=mask?(target.maskPlacement??target.transform):target.transform;
      const s=settings(op);s.mask=mask;s.lockAlpha=false;let ancestor=target;for(let n=0;ancestor&&n<65;n++,ancestor=m.layers.find(l=>l.id.toUpperCase()===ancestor.parentID?.toUpperCase()))s.lockAlpha ||= !!data.locks?.[ancestor.id]?.alpha;s.cx=m.width/2;s.cy=m.height/2;
      const image=codecs.decodePNG(resources.get(`images/${file}`));let output;
      if(op.kind==='stroke'){if(!s.points)fail('invalid');output=strokePixels(image,t,data.selection,s);}
      else if(op.kind==='filter'){if(!FILTERS.includes(op.filter))fail('invalid');const keys=['curves','exposureSettings','gradientMapSettings','grainSettings','blackWhiteSettings','colorBalanceSettings','noiseAmount','noiseSeed','noiseGaussian','noiseMonochromatic','blurRadius','motionAngle','motionDistance'];if(!supportsAdjustment({kind:'Invert',...Object.fromEntries(keys.filter(k=>s[k]!==undefined).map(k=>[k,s[k]]))}))fail('invalid');output=applySelectedFilter(image,t,data.selection,op.filter,s);}
      else{
        if(op.kind==='gradient'&&(!s.points||s.points.length!==2||!rgb(s.color)||!rgb(s.background)))fail('invalid');
        let coverage;
        if(op.kind==='bucket'){
          if(!pair(op.point))fail('invalid');const merged=codecs.decodePNG(codecs.validatePNG(op.png));if(merged.width!==m.width||merged.height!==m.height)fail('invalid');
          const docMask=floodMask(merged,Math.floor(op.point[0]),Math.floor(op.point[1]),s.tolerance??24,s.contiguous!==false);coverage=new Uint8Array(image.width*image.height);
          for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++){const p=toDocument([x+.5,y+.5],t,image.width,image.height),dx=Math.floor(p[0]),dy=Math.floor(p[1]);if(dx>=0&&dy>=0&&dx<m.width&&dy<m.height)coverage[y*image.width+x]=docMask[dy*m.width+dx];}
        }
        output=fillPixels(image,t,data.selection,{...s,action:op.kind==='clear'?'clear':op.kind==='gradient'?'gradient':'fill'},coverage);
      }
      if(s.lockAlpha)for(let i=0;i<output.data.length;i+=4){output.data[i+3]=image.data[i+3];if(!image.data[i+3])output.data.set(image.data.subarray(i,i+4),i);}
      if(output.data.every((v,i)=>v===image.data[i]))return true;
      resources.set(`images/${file}`,codecs.encodePixels(output,mask));if(!mask){delete target.text;delete target.shape;}return true;
    }
    case 'styled':{
      if(!['text','shape'].includes(op.type)||!pair(op.origin))fail('invalid');validateStyle(op.type,op.style);
      const image=codecs.validatePNG(op.png);let l=target;
      if(!l){const id=randomUUID().toUpperCase();l={id,name:String(op.name??op.type).slice(0,256),isVisible:true,transform:place(image.width,image.height),imageFile:id+'.png'};if(op.parentID){if(!m.layers.some(p=>p.id===op.parentID&&p.isGroup))fail('invalid');l.parentID=op.parentID;}m.layers.push(l);}else if(!l.imageFile||l.isGroup||l.adjustment)fail('unsupported');
      const old=resources.get(layerFile(l)),scale=op.type==='text'&&l.text&&old?[l.transform.size[0]/old.width,l.transform.size[1]/old.height]:[1,1];l.transform.origin=op.origin;l.transform.size=[image.width*scale[0],image.height*scale[1]];l[op.type]=structuredClone(op.style);delete l[op.type==='text'?'shape':'text'];resources.set(layerFile(l),image);m.activeLayerID=l.id;return true;
    }
    case 'transformLayers':{
      operationTargets(m,op);if(!['origin','size','rotation','flipX','flipY','sampling'].includes(op.field))fail('invalid');const layers=operationTargets(m,op),members=layers.filter(l=>l.imageFile);if(!members.length)fail('unsupported');const box=union(members.map(l=>bounds(l.transform))),old={...place(Math.max(1,box.w),Math.max(1,box.h)),origin:[box.x,box.y]},next={...old,[op.field]:structuredClone(op.value)};
      if(!pair(next.origin)||!pair(next.size)||next.size.some(v=>v<1)||!finite(next.rotation)||typeof next.flipX!=='boolean'||typeof next.flipY!=='boolean')fail('invalid');
      for(const l of layers){if(l.maskPlacement&&l.maskLinked!==false)l.maskPlacement=following(l.maskPlacement,old,next);l.transform=following(l.transform,old,next);if(op.field==='sampling')l.transform.sampling=op.value;}return true;
    }
    case 'transformMask':{
      if(!target.maskFile||!['origin','size','rotation','flipX','flipY','sampling'].includes(op.field))fail('unsupported');
      if(!target.maskPlacement)target.maskPlacement=structuredClone(target.transform);target.maskLinked=false;target.maskPlacement[op.field]=structuredClone(op.value);return true;
    }
    case 'moveLayers':operationTargets(m,op);if(!pair(op.delta))fail('invalid');for(const l of roots(op.ids))shift(descendants(l.id),...op.delta);return true;
    case 'rasterize':delete target.text;delete target.shape;return true;
    case 'canvas':{
      validSurface(op.width,op.height);if(!finite(op.x??0)||!finite(op.y??0))fail('invalid');shift(new Set(m.layers.map(l=>l.id.toUpperCase())),-(op.x??0),-(op.y??0),true);m.width=op.width;m.height=op.height;
      for(const g of m.guides??[])g.position-=g.axis==='vertical'?(op.x??0):(op.y??0);return true;
    }
    case 'imageSize':{
      validSurface(op.width,op.height);const sx=op.width/m.width,sy=op.height/m.height,scale=Math.sqrt(sx*sy);let total=0;
      for(const l of m.layers)for(const f of ['imageFile','maskFile'])if(l[f]){const r=resources.get(`images/${l[f]}`),w=Math.max(1,Math.round(r.width*sx)),h=Math.max(1,Math.round(r.height*sy));validSurface(w,h);total+=w*h;}if(total>LIMITS.pixels)fail('limit');
      for(const l of m.layers){for(const t of [l.transform,l.maskPlacement].filter(Boolean)){t.origin=t.origin.map((v,i)=>v*(i?sy:sx));t.size=t.size.map((v,i)=>v*(i?sy:sx));}
        for(const f of ['imageFile','maskFile'])if(l[f]){const r=resources.get(`images/${l[f]}`);resources.set(`images/${l[f]}`,codecs.encodePixels(resizePixels(codecs.decodePNG(r),Math.max(1,Math.round(r.width*sx)),Math.max(1,Math.round(r.height*sy)),op.nearest===true),f==='maskFile'));}
        for(const e of Object.values(l.effects??{}))for(const k of ['size','blur','distance'])if(typeof e[k]==='number')e[k]*=scale;delete l.text;delete l.shape;
      }for(const g of m.guides??[])g.position*=g.axis==='vertical'?sx:sy;m.width=op.width;m.height=op.height;return true;
    }
    case 'arrange':{
      if(!['left','hcenter','right','top','vcenter','bottom','hspread','vspread','hgap','vgap'].includes(op.operation)||!['selection','canvas','keyObject'].includes(op.reference))fail('invalid');operationTargets(m,op);const ls=roots(op.ids);
      const rects=ls.map(l=>l.isGroup?union(m.layers.filter(v=>descendants(l.id).has(v.id.toUpperCase())&&v.imageFile).map(v=>bounds(v.transform))):bounds(l.transform));
      let reference;if(op.reference==='canvas')reference={x:0,y:0,w:m.width,h:m.height};if(op.reference==='keyObject'){const i=ls.findIndex(l=>l.id===op.keyID);if(i<0)fail('invalid');reference=rects[i];}
      arrange(rects,op.operation,reference).forEach((d,i)=>{if(op.reference==='keyObject'&&ls[i].id===op.keyID)return;shift(descendants(ls[i].id),d[0],d[1]);});return true;
    }
    case 'group':{
      operationTargets(m,op);const ls=roots(op.ids);if(!ls.length||ls.some(l=>l.parentID!==ls[0].parentID))fail('invalid');const id=randomUUID().toUpperCase(),group={id,name:String(op.name??'Group').slice(0,256),isVisible:true,isGroup:true,transform:place(m.width,m.height)};if(ls[0].parentID)group.parentID=ls[0].parentID;
      m.layers.splice(Math.min(...ls.map(l=>m.layers.indexOf(l))),0,group);for(const l of ls)l.parentID=id;m.activeLayerID=id;return true;
    }
    case 'ungroup':{if(!target.isGroup||target.maskFile||(target.opacity??1)!==1)fail('unsupported');const children=m.layers.filter(l=>l.parentID===target.id);for(const l of children){if(!target.isVisible)l.isVisible=false;if(target.parentID)l.parentID=target.parentID;else delete l.parentID;}m.layers=m.layers.filter(l=>l.id!==target.id);if(children.length)m.activeLayerID=children[0].id;else delete m.activeLayerID;return true;}
    case 'duplicateTree':{
      const ids=descendants(target.id),ls=m.layers.filter(l=>ids.has(l.id.toUpperCase())),map=new Map(ls.map(l=>[l.id,randomUUID().toUpperCase()]));
      const suffix=typeof op.copySuffix==='string'&&op.copySuffix.length<=32?op.copySuffix:' (copy)';
      const copies=ls.map(l=>{const v=structuredClone(l);v.id=map.get(l.id);if(l.id===target.id)v.name=v.name.slice(0,256-suffix.length)+suffix;if(map.has(v.parentID))v.parentID=map.get(v.parentID);if(map.has(v.maskSourceID))v.maskSourceID=map.get(v.maskSourceID);for(const f of ['imageFile','maskFile'])if(v[f]){const old=v[f];v[f]=v.id+(f==='maskFile'?'.mask':'')+'.png';resources.set(`images/${v[f]}`,resources.get(`images/${old}`));}return v;});
      m.layers.splice(m.layers.indexOf(target)+ls.length,0,...copies);m.activeLayerID=map.get(target.id);return true;
    }
    case 'merge':{
      operationTargets(m,op);const ls=roots(op.ids);if(!ls.length||ls.some(l=>l.parentID!==ls[0].parentID))fail('invalid');const siblings=m.layers.filter(l=>l.parentID===ls[0].parentID),first=Math.min(...ls.map(l=>siblings.indexOf(l))),last=Math.max(...ls.map(l=>siblings.indexOf(l)));if(siblings.slice(first,last+1).some(l=>!ls.includes(l)))fail('unsupported');const r=codecs.validatePNG(op.png);if(r.width!==m.width||r.height!==m.height)fail('invalid');
      const ids=new Set();for(const l of ls)for(const id of descendants(l.id))ids.add(id);for(const l of m.layers)if(!ids.has(l.id.toUpperCase())&&ids.has(l.maskSourceID?.toUpperCase()))fail('unsupported');
      const id=randomUUID().toUpperCase(),row={id,name:String(op.name??'Merged').slice(0,256),isVisible:true,imageFile:id+'.png',transform:place(m.width,m.height)};if(ls[0].parentID)row.parentID=ls[0].parentID;
      const index=Math.min(...ls.map(l=>m.layers.indexOf(l)));m.layers=m.layers.filter(l=>!ids.has(l.id.toUpperCase()));m.layers.splice(index,0,row);resources.set(layerFile(row),r);m.activeLayerID=id;return true;
    }
    case 'applyMask':{
      if(!target.imageFile||!target.maskFile)fail('unsupported');const image=codecs.decodePNG(resources.get(layerFile(target))),mask=codecs.decodePNG(resources.get(`images/${target.maskFile}`)),t=target.maskPlacement??target.transform;
      for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++){const p=toLocal(toDocument([x+.5,y+.5],target.transform,image.width,image.height),t,mask.width,mask.height),mx=Math.floor(p[0]),my=Math.floor(p[1]);image.data[(y*image.width+x)*4+3]*=mx<0||my<0||mx>=mask.width||my>=mask.height?0:mask.data[(my*mask.width+mx)*4]/255;}
      resources.set(layerFile(target),codecs.encodePixels(image));for(const k of ['maskFile','maskEnabled','maskPlacement','maskLinked','text','shape'])delete target[k];return true;
    }
    case 'selectionMask':{
      if(!data.selection||target.maskFile)fail('selection');const r=target.imageFile?resources.get(layerFile(target)):{width:m.width,height:m.height},pixels=new Uint8ClampedArray(r.width*r.height*4);
      for(let y=0;y<r.height;y++)for(let x=0;x<r.width;x++){const at=(y*r.width+x)*4,v=selectionCoverage(data.selection,toDocument([x+.5,y+.5],target.transform,r.width,r.height))*255;pixels[at]=pixels[at+1]=pixels[at+2]=v;pixels[at+3]=255;}
      target.maskFile=target.id+'.mask.png';target.maskEnabled=true;resources.set(`images/${target.maskFile}`,codecs.encodePixels({...r,data:pixels},true));return true;
    }
    case 'guides':if(!Array.isArray(op.guides)||op.guides.length>200||op.guides.some(g=>!['horizontal','vertical'].includes(g.axis)||!finite(g.position)||typeof g.id!=='string'||!/^[0-9a-f-]{36}$/i.test(g.id)))fail('invalid');m.guides=structuredClone(op.guides);return true;
    case 'flipCanvas':{
      if(!['horizontal','vertical'].includes(op.axis))fail('invalid');const i=op.axis==='horizontal'?0:1;
      for(const l of m.layers)for(const t of [l.transform,l.maskPlacement].filter(Boolean)){t.origin[i]=(i?m.height:m.width)-t.origin[i]-t.size[i];t.rotation=-t.rotation;t[i?'flipY':'flipX']=!t[i?'flipY':'flipX'];}for(const g of m.guides??[])if(g.axis===(i?'horizontal':'vertical'))g.position=(i?m.height:m.width)-g.position;return true;
    }
    default:return false;
  }
}
