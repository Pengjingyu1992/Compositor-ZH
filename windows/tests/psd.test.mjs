import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { readPsd, writePsdBuffer } from 'ag-psd';
import { exportPSD, importPSD, validatePNG } from '../packages/comp-bridge/codecs.mjs';
import { projectData } from '../packages/comp-bridge/edit.mjs';
import { manifest, IDS, png } from './fixtures.mjs';
const image=(w,h,c)=>({width:w,height:h,data:new Uint8ClampedArray(Array.from({length:w*h*4},(_,i)=>c[i%4]))});
function data(){const m=manifest(),resources=new Map();for(const l of m.layers){resources.set(`images/${l.imageFile}`,validatePNG(new Uint8Array(png(64,48,l.id===IDS[0]?[240,160,144,255]:[120,220,180,255]))));if(l.maskFile)resources.set(`images/${l.maskFile}`,{bytes:png(64,48,[128],true),mime:'image/png',width:64,height:48});}return projectData(m,resources);}
const payload=()=>({composite:new Uint8Array(png(64,48,[210,175,153,255])),layers:[{id:IDS[0],left:0,top:0,image:new Uint8Array(png(64,48,[240,160,144,255]))},{id:IDS[1],left:5,top:3,image:new Uint8Array(png(16,12,[120,220,180,255]))}],masks:[{id:IDS[1],left:5,top:3,image:new Uint8Array(png(16,12,[128,128,128,255]))}]});
test('PSD export retains order, offsets, opacity, blend, mask channels and straight pixels',async()=>{
  const a=data(),m=structuredClone(a.manifest);m.layers[1].blendMode='Multiply';const p=projectData(m,a.resources),bytes=exportPSD(p,payload());
  const read=readPsd(bytes,{useImageData:true,skipThumbnail:true});assert.equal(read.children.length,2);assert.equal(read.children[1].name,'Mint / 薄荷');assert.equal(read.children[1].blendMode,'multiply');assert.equal(read.children[1].left,5);assert.ok(Math.abs(read.children[1].opacity-.5)<.005);assert.equal(read.children[1].mask.imageData.data[0],128);
  await mkdir('test-results',{recursive:true});await writeFile('test-results/independent.psd',bytes);
  const round=importPSD(new Uint8Array(bytes));assert.equal(round.data.manifest.layers.length,2);assert.equal(round.data.manifest.layers[1].blendMode,'Multiply');assert.deepEqual(round.data.manifest.layers[1].transform.origin,[5,3]);
});
test('PSD export preserves groups; text is explicitly rasterized and complex effects require flattened export',()=>{
  const a=data(),m=structuredClone(a.manifest);m.layers.unshift({id:IDS[2],name:'Group',isGroup:true,isVisible:true,transform:m.layers[0].transform});m.layers[1].parentID=IDS[2];m.layers[2].parentID=IDS[2];m.layers[1].text={content:'中文'};
  const p=projectData(m,a.resources),b=exportPSD(p,payload()),parsed=readPsd(b,{useImageData:true});assert.equal(parsed.children[0].children.length,2);assert.equal(parsed.children[0].children[0].text,undefined);
  m.layers[1].effects={shadow:{angle:135,distance:10,blur:8,red:0,green:0,blue:0,opacity:.5}};const complex=projectData(m,a.resources);assert.throws(()=>exportPSD(complex,payload()),e=>e.code==='psdConversion');assert.ok(exportPSD(complex,{...payload(),flatten:true}).length>26);
});
test('PSD dimensions/color/depth and independent layer decode budgets are checked before pixels',()=>{
  const b=writePsdBuffer({width:2,height:2,imageData:image(2,2,[1,2,3,255]),children:[{name:'Test',imageData:image(2,2,[1,2,3,255])}]});
  for(const mutate of [b=>b.writeUInt16BE(16,22),b=>b.writeUInt32BE(30001,18)]){const c=Buffer.from(b);mutate(c);assert.throws(()=>importPSD(new Uint8Array(c)));}
});
