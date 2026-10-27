import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import sharp from'sharp';
import{supportsTextStyle,layoutText,pathSamples}from'../packages/comp-bridge/text-layout.mjs';
import{supportsVectorPath,defaultVectorPath}from'../packages/comp-bridge/layer-styles.mjs';
import{textOutlines,renderVectorText}from'../packages/platform/typography.mjs';
import{fontNames}from'../packages/platform/system-fonts.mjs';
import{newProject,editProject}from'../packages/comp-bridge/edit.mjs';
import{parseManifest,readProject}from'../packages/comp-bridge/project.mjs';
import{saveProject}from'../packages/platform/save-project.mjs';
import * as codecs from'../packages/comp-bridge/codecs.mjs';
const text=(extra={})=>({content:'Vector O',fontName:'ArialMT',fontSize:32,red:.2,green:.4,blue:.7,alignment:'Left',tracking:0,leading:0,boxSize:[360,120],...extra});
const line=()=>{const path=defaultVectorPath();path.contours[0].anchors=[{point:[0,.5]},{point:[1,.5]}];return path;};

test('text layout preserves UTF-16 style runs, aligns paragraphs, justifies wrapped lines and flows vertical columns',()=>{
  const style=text({content:'A😀中B',colorRuns:[{location:1,length:2,red:1,green:0,blue:0}],fontRuns:[{location:3,length:1,fontName:'CJK'}]}),placed=layoutText(style,()=>20);
  assert.deepEqual(placed.map(g=>g.index),[0,1,3,4]);assert.equal(placed[1].color.red,1);assert.equal(placed[2].font,'CJK');assert.equal(placed[3].font,'ArialMT');
  const center=layoutText(text({alignment:'Center',content:'AB'}),()=>20);assert.equal(center[0].x,160);
  const justified=layoutText(text({content:'ABCDEFGHIJ',fontSize:16,boxSize:[100,100],alignment:'Justified'}),()=>20);assert.equal(justified[2].x+20,88);assert.equal(justified[3].x,12);
  const vertical=layoutText(text({content:'中A中A中A中A',vertical:true,fontSize:20,boxSize:[100,80]}),()=>20);assert.equal(vertical[0].angle,0);assert.equal(vertical[1].angle,Math.PI/2);assert.ok(vertical[2].x<vertical[0].x);assert.ok(vertical[2].y<vertical[1].y);
});

test('path text samples cubic geometry, aligns along the tangent, reverses direction and refuses overflow or incompatible layouts',()=>{
  const path=line(),style=text({content:'AB',pathLayout:{path,offset:10,reversed:false}}),placed=layoutText(style,()=>20);
  assert.equal(placed.length,2);assert.ok(Math.abs(placed[0].x-10)<.00001);assert.equal(placed[0].y,60);assert.equal(placed[0].angle,0);assert.equal(pathSamples(path,360,120).length,33);
  const reversed=layoutText({...style,pathLayout:{...style.pathLayout,reversed:true}},()=>20);assert.equal(reversed[0].angle,Math.PI);assert.ok(reversed[0].x>placed[1].x);
  assert.throws(()=>layoutText({...style,pathLayout:{...style.pathLayout,offset:350}},()=>20),error=>error.code==='pathLength');
  for(const patch of [{vertical:true},{warp:{bend:.2}},{content:'A\nB'}])assert.equal(supportsTextStyle({...style,...patch}),false);
  for(const patch of [{warp:{bend:2}},{fontName:'bad\nfont'},{alignment:'Future'},{vertical:'yes'},{unknown:true},{colorRuns:[{location:0,length:99,red:0,green:0,blue:0}]}])assert.equal(supportsTextStyle(text(patch)),false);
});

test('installed-font outlines retain glyph holes and colors, arc geometry, paths and persisted text-to-path conversion',async()=>{
  const names=await fontNames();assert.ok(names.length>0);assert.ok(names.every(name=>!name.includes('/')&&!name.includes('\\')));
  const style=text({content:'OO',colorRuns:[{location:1,length:1,red:1,green:0,blue:0}]}),normal=await textOutlines(style),arc=await textOutlines({...style,warp:{bend:.2}});
  assert.ok(supportsVectorPath(normal));assert.ok(normal.contours.length>=4);assert.ok(normal.contours.some(c=>c.color.red===1));assert.notDeepEqual(arc.contours,normal.contours);
  const result=await renderVectorText({...style,pathLayout:{path:line(),offset:20,reversed:false}}),metadata=await sharp(result.png).metadata();assert.equal(metadata.width,360);assert.equal(metadata.height,120);
  let data=editProject(newProject(360,120),{kind:'styled',type:'text',style:{...style,colorRuns:[],fontRuns:[],vertical:true},origin:[0,0],png:result.png},codecs),layer=data.manifest.layers[0];
  assert.equal(data.manifest.version,12);assert.equal(layer.text.colorRuns,undefined);assert.equal(layer.text.fontRuns,undefined);assert.deepEqual(data.analysis.issues,[]);
  const manifest=structuredClone(data.manifest);manifest.version=11;assert.throws(()=>parseManifest(Buffer.from(JSON.stringify(manifest))));
  data=editProject(data,{kind:'textOutlines',id:layer.id,style:result.vector,png:result.png},codecs);layer=data.manifest.layers[0];assert.equal(layer.text,undefined);assert.equal(layer.shape.kind,'Path');assert.equal(data.manifest.version,13);
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-outlines-'));
  try{const file=path.join(temp,'outlines.comp');await saveProject(data,file);const reopened=await readProject(file);assert.deepEqual(reopened.manifest.layers[0].shape.vector,result.vector);assert.deepEqual(reopened.analysis.issues,[]);}finally{await rm(temp,{recursive:true,force:true});}
});
