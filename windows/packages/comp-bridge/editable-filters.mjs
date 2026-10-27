import { validSurface, selectionCoverage, toDocument } from './editor-math.mjs';
import { filterPixels } from './raster-tools.mjs';
import { validateColorLUT } from './poster-color.mjs';
import { validateSavedLiquify, renderLiquify } from './liquify.mjs';

export const EDITABLE_FILTERS = ['Gaussian Blur','Motion Blur','Add Noise','Color Halftone','Color Lookup','Advanced Liquify'];
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fail=(code='invalid')=>{const error=new Error(code);error.code=code;throw error;};
const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const known=(v,keys)=>object(v)&&Object.keys(v).every(k=>keys.includes(k));
const finite=(v,a,b)=>typeof v==='number'&&Number.isFinite(v)&&v>=a&&v<=b;
export { encodeBinary, decodeBinary } from './binary.mjs';
import { encodeBinary, decodeBinary } from './binary.mjs';
export function defaultFilterNode(kind,id=()=>globalThis.crypto.randomUUID().toUpperCase()) {
  return {id:id(),version:1,kind,enabled:true,opacity:1,seed:Math.floor(Math.random()*4294967296),radius:1,angle:0,distance:10,amount:10,gaussian:false,monochromatic:false,
    halftone:{size:8,strength:100,shape:'Round',cyan:108,magenta:162,yellow:90,black:45,screen:'Automatic Channels'},lut:{strength:100,space:'Encoded sRGB'}};
}
export function validateFilterRecord(record,layer) {
  if(!known(record,['sourceFile','nodeFiles'])||record.sourceFile!==`${layer.id.toUpperCase()}.source.png`||!Array.isArray(record.nodeFiles)||record.nodeFiles.length>32||new Set(record.nodeFiles).size!==record.nodeFiles.length)fail();
  for(const file of record.nodeFiles){const prefix=`${layer.id.toUpperCase()}.`,suffix='.filter.json',id=typeof file==='string'?file.slice(prefix.length,-suffix.length):'';if(typeof file!=='string'||!file.startsWith(prefix)||!file.endsWith(suffix)||!UUID.test(id)||id!==id.toUpperCase())fail();}
  if(!layer.imageFile||layer.text||layer.shape||layer.fill||layer.adjustment||layer.isGroup)fail();
}
export function validateFilterNode(node,width,height) {
  validSurface(width,height);
  if(!known(node,['id','version','kind','enabled','opacity','seed','radius','angle','distance','amount','gaussian','monochromatic','halftone','lut','liquify','coverage'])||!UUID.test(node.id)||node.version!==1||!EDITABLE_FILTERS.includes(node.kind)||typeof node.enabled!=='boolean'||!finite(node.opacity,0,1)||!Number.isInteger(node.seed)||!finite(node.seed,0,4294967295)||!finite(node.radius,.1,250)||!finite(node.angle,-90,90)||!finite(node.distance,1,2000)||!finite(node.amount,.1,400)||typeof node.gaussian!=='boolean'||typeof node.monochromatic!=='boolean')fail();
  const h=node.halftone,l=node.lut;
  if(!known(h,['size','strength','shape','cyan','magenta','yellow','black','screen'])||!finite(h.size,2,128)||!finite(h.strength,0,100)||!['Round','Square','Line'].includes(h.shape)||!['cyan','magenta','yellow','black'].every(k=>finite(h[k],-180,180))||h.screen!=null&&!['Automatic Channels','RGB Channels','Grayscale Screen','Legacy CMYK Print'].includes(h.screen))fail();
  if(!known(l,['table','strength','space'])||!finite(l.strength,0,100)||!['Encoded sRGB','Linear sRGB'].includes(l.space)||node.kind==='Color Lookup'&&node.enabled&&!l.table)fail();
  let retained=0;if(l.table){validateColorLUT(l.table);retained+=l.table.values.length*64;}
  if(node.coverage!=null)retained+=decodeBinary(node.coverage,width*height).byteLength;
  if(node.kind==='Advanced Liquify'){validateSavedLiquify(node.liquify,width,height);retained+=node.liquify.gridWidth*node.liquify.gridHeight*12+(node.liquify.coverage?width*height:0);}
  else if(node.liquify!=null)fail();
  return retained;
}
export function readFilterNodes(layer,resources) {
  const record=layer.editableFilters;if(!record)return [];
  validateFilterRecord(record,layer);
  const source=resources.get(`edits/${record.sourceFile}`),cache=resources.get(`images/${layer.imageFile}`);
  if(!source||!cache||source.width!==cache.width||source.height!==cache.height)fail('asset');
  let retained=0,encoded=0;const ids=new Set();
  const nodes=record.nodeFiles.map(file=>{
    const resource=resources.get(`edits/${file}`);if(!resource)fail('missing');encoded+=resource.bytes.length;if(resource.bytes.length>192*1024**2||encoded>384*1024**2)fail('limit');
    let node;try{node=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(resource.bytes));}catch{fail();}
    retained+=validateFilterNode(node,source.width,source.height);const id=node.id.toUpperCase();if(ids.has(id)||file!==`${layer.id.toUpperCase()}.${id}.filter.json`)fail();ids.add(id);return node;
  });
  if(retained>256*1024**2||source.width*source.height*20+retained>512*1024**2)fail('limit');
  return nodes;
}
export function capturedCoverage(selection,placement,width,height) {
  if(!selection)return undefined;const data=new Uint8Array(width*height);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++)data[y*width+x]=Math.round(selectionCoverage(selection,toDocument([x+.5,y+.5],placement,width,height))*255);
  return encodeBinary(data);
}
export function renderFilterStack(source,nodes) {
  if(!Array.isArray(nodes)||nodes.length>32)fail('limit');let retained=0;const ids=new Set();
  for(const node of nodes){retained+=validateFilterNode(node,source.width,source.height);if(ids.has(node.id.toUpperCase()))fail();ids.add(node.id.toUpperCase());}
  if(retained>256*1024**2||source.width*source.height*20+retained>512*1024**2)fail('limit');
  let image=source;
  for(const node of nodes){
    if(!node.enabled||!node.opacity)continue;
    const before=image;
    image=node.kind==='Advanced Liquify'?renderLiquify(image,node.liquify):filterPixels(image,node.kind,{radius:node.radius,angle:node.angle,distance:node.distance,amount:node.amount,noiseGaussian:node.gaussian,noiseMonochromatic:node.monochromatic,seed:node.seed,halftone:{...node.halftone,screen:node.halftone.screen??undefined},colorLUT:node.lut});
    if(node.coverage!=null||node.opacity!==1){const mask=node.coverage!=null?decodeBinary(node.coverage,source.width*source.height):undefined,data=new Uint8ClampedArray(image.data.length);
      for(let i=0;i<data.length;i+=4){const weight=node.opacity*(mask?mask[i/4]/255:1),a=before.data[i+3]*(1-weight),b=image.data[i+3]*weight,alpha=a+b;for(let c=0;c<3;c++)data[i+c]=alpha?Math.round((before.data[i+c]*a+image.data[i+c]*b)/alpha):0;data[i+3]=Math.round(alpha);}image={...image,data};}
  }
  return image;
}

export function validateProjectFilters(manifest,resources) {
  let pixels=0,retained=0,encoded=0;
  for(const layer of manifest.layers)if(layer.editableFilters){
    const source=resources.get(`edits/${layer.editableFilters.sourceFile}`),nodes=readFilterNodes(layer,resources);
    pixels+=source.width*source.height;
    for(const node of nodes){retained+=validateFilterNode(node,source.width,source.height);encoded+=resources.get(`edits/${layer.id.toUpperCase()}.${node.id.toUpperCase()}.filter.json`).bytes.length;}
    if(nodes.some(n=>n.kind==='Color Halftone'&&n.halftone.screen!=null&&n.halftone.screen!=='Legacy CMYK Print')&&manifest.version<15)fail();
  }
  if(retained>256*1024**2||encoded>384*1024**2)fail('limit');return pixels;
}
export function copyFilterResources(copy,resources) {
  const previous=copy.editableFilters;if(!previous)return;
  const oldID=previous.sourceFile.slice(0,-'.source.png'.length),next={sourceFile:`${copy.id}.source.png`,nodeFiles:previous.nodeFiles.map(file=>copy.id+file.slice(oldID.length))};
  resources.set(`edits/${next.sourceFile}`,resources.get(`edits/${previous.sourceFile}`));
  previous.nodeFiles.forEach((file,index)=>resources.set(`edits/${next.nodeFiles[index]}`,resources.get(`edits/${file}`)));copy.editableFilters=next;
}
