import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { PNG } from 'pngjs';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { canvasPixels, canvasDimensionText, canvasCreation, CANVAS_PRESETS } from '../packages/comp-bridge/new-canvas.mjs';
import { newCanvasProject } from '../packages/platform/new-canvas.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { ProjectWorkspace } from '../packages/platform/project-workspace.mjs';
import { saveProject } from '../packages/platform/save-project.mjs';
import { readProject } from '../packages/comp-bridge/project.mjs';

test('new canvas physical units use the selected DPI and reject invalid or fractional pixel sizes', () => {
  for (const [text, unit, dpi, expected] of [['1','in',300,300],['2.54','cm',72,72],['25.4','mm',300,300],[' 2,54 ','cm',300,300],['1.5','in',72,108],['30000','px',72,30000]]) assert.equal(canvasPixels(text,unit,dpi),expected);
  for (const text of ['', '0', '-1', '1.5', 'Infinity', 'NaN', '0x10', '30001', '1,2,3']) assert.equal(canvasPixels(text,'px',72),null);
  assert.equal(canvasPixels('.001','in',72),null); assert.equal(canvasPixels('1','unknown',72),null); assert.equal(canvasPixels('1','in',0),null);
  assert.equal(canvasDimensionText(1920,'in',72),'26.67'); assert.equal(canvasDimensionText(300,'cm',300),'2.54');
});

test('macOS canvas presets fit the shared edition budget and creation validates before allocating', () => {
  const presets=CANVAS_PRESETS.flatMap(group=>group.items);assert.equal(presets.length,12);assert.equal(new Set(presets.map(p=>p.id)).size,12);
  for(const preset of presets) assert.doesNotThrow(()=>canvasCreation(preset.width,preset.height));
  assert.equal(canvasCreation(1920,1080).resolution,72);
  for(const options of [{resolution:Infinity},{resolution:0},{background:'red'},{backgroundName:''},{unexpected:true},null,[]]) assert.throws(()=>canvasCreation(8,8,options));
  let encoded=0;const spy={encodePixels(){encoded++;throw new Error('unexpected allocation');}};
  for(const background of ['transparent','white','black']) assert.throws(()=>newCanvasProject(5000,5000,{background},spy),{code:'limit'});
  assert.equal(encoded,0);
});

test('transparent creation stays allocation-free and filled backgrounds persist pixels and DPI', async () => {
  const transparent=newCanvasProject(32,24,{},null);assert.equal(transparent.resources.size,0);assert.equal(transparent.manifest.layers.length,0);assert.equal(transparent.manifest.resolution,72);
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-canvas-model-'));
  try { for(const background of ['white','black']) {
    const data=newCanvasProject(32,24,{background,resolution:300,backgroundName:'背景'},codecs),row=data.manifest.layers[0];
    assert.equal(data.manifest.activeLayerID,row.id);assert.deepEqual(row.transform.size,[32,24]);assert.equal(row.name,'背景');
    const destination=path.join(temp,background+'.comp');await saveProject(data,destination);const restored=await readProject(destination);
    assert.equal(restored.manifest.resolution,300);const image=PNG.sync.read(restored.resources.get('images/'+row.imageFile).bytes);assert.equal(image.width,32);assert.equal(image.height,24);
    for(let at=0;at<image.data.length;at+=4)assert.deepEqual([...image.data.subarray(at,at+4)],background==='white'?[255,255,255,255]:[0,0,0,255]);
  }} finally { await rm(temp,{recursive:true,force:true}); }
});

test('failed new canvas creation preserves the active document, resources and undo history', () => {
  const session=new ProjectSession(undefined,{codecs});const first=session.create(32,24,300,{background:'white'}).project;session.edit(first.id,first.revision,{kind:'rename',id:first.manifest.layers[0].id,name:'Keep me'});
  const before=session.current,bytes=[...before.data.resources.values()][0].bytes,history=session.undoStack.length;
  assert.equal(session.create(5000,5000,72,{background:'black'}).error,'limit');assert.equal(session.current,before);assert.equal([...session.current.data.resources.values()][0].bytes,bytes);assert.equal(session.undoStack.length,history);
  const workspace=new ProjectWorkspace(undefined,{codecs});workspace.create(32,24,{resolution:300,background:'black'});const current=workspace.active.current;
  assert.throws(()=>workspace.create(32,24,{background:'invalid'}));assert.equal(workspace.active.current,current);assert.equal(workspace.tabs().length,1);
  workspace.create(16,12,{resolution:72,background:'white'});assert.equal(workspace.tabs().length,2);assert.equal(workspace.active.current.data.manifest.resolution,72);assert.equal(current.data.manifest.resolution,300);
});
