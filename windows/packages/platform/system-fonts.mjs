import * as fontkit from 'fontkit';
import {readdir}from'node:fs/promises';
import {execFile}from'node:child_process';
import {promisify}from'node:util';
import path from'node:path';
import os from'node:os';
import {safeDirectory,safeRead,ProjectError}from'../comp-bridge/project.mjs';
import {fontFamily}from'../comp-bridge/text-layout.mjs';
const execute=promisify(execFile),cache=new Map(),resolved=new Map(),sizes=new WeakMap();let cacheBytes=0,catalogTask;
async function load(file,postscriptName){
  let entry=cache.get(file);
  if(!entry){await safeDirectory(path.dirname(file));const bytes=await safeRead(file,64*1024**2),parsed=fontkit.create(bytes);entry={bytes:bytes.length,fonts:parsed.fonts??[parsed]};for(const font of entry.fonts)sizes.set(font,entry.bytes);cache.set(file,entry);cacheBytes+=entry.bytes;while(cacheBytes>128*1024**2&&cache.size>1){const key=cache.keys().next().value;cacheBytes-=cache.get(key).bytes;cache.delete(key);resolved.clear();}}
  return entry.fonts.find(font=>font.postscriptName===postscriptName)??entry.fonts[0];
}
async function windowsCatalog(){
  const roots=[path.join(process.env.SystemRoot??'C:\\Windows','Fonts'),path.join(process.env.LOCALAPPDATA??path.join(os.homedir(),'AppData','Local'),'Microsoft','Windows','Fonts')],entries=[];
  for(const root of roots){let files;try{await safeDirectory(root);files=await readdir(root,{withFileTypes:true});}catch{continue;}
    for(const entry of files.slice(0,5000)){if(!entry.isFile()||! /\.(?:ttf|otf|ttc)$/i.test(entry.name))continue;const file=path.join(root,entry.name);try{const font=fontkit.create(await safeRead(file,64*1024**2));for(const face of font.fonts??[font])entries.push({file,postscriptName:face.postscriptName,familyName:face.familyName,fullName:face.fullName});}catch{/* A broken optional system font does not hide the other installed fonts. */}}
  }return entries;
}
async function linuxCatalog(){
  const {stdout}=await execute('/usr/bin/fc-list',['--format','%{file}\x1f%{family}\x1f%{postscriptname}\n'],{timeout:10000,maxBuffer:4*1024**2,encoding:'utf8'});
  return stdout.split('\n').filter(Boolean).slice(0,10000).map(line=>{const[file,familyName,postscriptName]=line.split('\x1f');return{file,familyName,postscriptName,fullName:familyName};}).filter(entry=>entry.file&&entry.familyName);
}
export async function fontCatalog(){catalogTask??=(process.platform==='win32'?windowsCatalog():linuxCatalog()).catch(error=>{catalogTask=undefined;throw error;});return catalogTask;}
export async function fontNames(){return [...new Set((await fontCatalog()).map(font=>font.familyName.split(',')[0]))].sort((a,b)=>a.localeCompare(b)).slice(0,4000);}
const key=name=>name.toLowerCase().replace(/[\s-]/g,'');
const visibleCodePoints=text=>Array.from(text,c=>c.codePointAt(0)).filter(cp=>! /[\p{Default_Ignorable_Code_Point}\s]/u.test(String.fromCodePoint(cp)));
export async function resolveFont(name,text){
  const points=visibleCodePoints(text),fits=font=>points.every(cp=>font.hasGlyphForCodePoint(cp)),remember=font=>{const list=resolved.get(name)??[];if(!list.includes(font))list.push(font);resolved.set(name,list);if(resolved.size>256)resolved.delete(resolved.keys().next().value);return font;};
  for(const font of resolved.get(name)??[])if(fits(font))return remember(font);
  if(process.platform==='linux'){
    const family=fontFamily(name).replace(/[\\,:=]/g,'\\$&'),charset=points.map(cp=>cp.toString(16)).join(' ');
    const {stdout}=await execute('/usr/bin/fc-match',['--format','%{file}\x1f%{postscriptname}','--',`${family}${charset?':charset='+charset:''}`],{timeout:5000,maxBuffer:65536,encoding:'utf8'}),[file,postscript]=stdout.split('\x1f');
    const font=await load(file,postscript);if(fits(font))return remember(font);
  }else{
    const common={'arial':'arial.ttf','arialmt':'arial.ttf','segoeui':'segoeui.ttf','timesnewroman':'times.ttf','consolas':'consola.ttf','couriernew':'cour.ttf','microsoftyahei':'msyh.ttc','simsun':'simsun.ttc'},filename=common[key(fontFamily(name))];
    if(filename)try{const font=await load(path.join(process.env.SystemRoot??'C:\\Windows','Fonts',filename),name);if(fits(font))return remember(font);}catch{}
    const catalog=await fontCatalog(),wanted=[key(name),key(fontFamily(name))],preferred=catalog.filter(entry=>wanted.some(name=>[entry.postscriptName,entry.fullName,entry.familyName].some(value=>key(value??'')===name))),fallback=catalog.filter(entry=>/^(?:Arial|Segoe UI|Microsoft YaHei|SimSun|Noto Sans|Yu Gothic|Meiryo|DejaVu Sans)/i.test(entry.familyName??''));
    const visited=new Set();for(const entry of [...preferred,...fallback]){const identity=entry.file+'#'+entry.postscriptName;if(visited.has(identity))continue;visited.add(identity);try{const font=await load(entry.file,entry.postscriptName);if(fits(font))return remember(font);}catch{/* Continue to a real fallback font. */}}
  }
  throw new ProjectError('glyph');
}

export const fontByteSize=font=>sizes.get(font)??0;
