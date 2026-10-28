import{test}from'node:test';
import assert from'node:assert/strict';
import{readFile}from'node:fs/promises';
import{colorRangeMask,sampleRangeColor}from'../packages/comp-bridge/color-range.mjs';
import{ProjectSession}from'../packages/platform/project-session.mjs';
import{newProject}from'../packages/comp-bridge/edit.mjs';
import * as codecs from'../packages/comp-bridge/codecs.mjs';
import{png}from'./fixtures.mjs';

test('color range masks match the macOS C kernel for six tolerance/inversion cases including soft and zero alpha',async()=>{
  const fixture=JSON.parse(await readFile(new URL('./golden/color-range-native.json',import.meta.url))),image={width:fixture.width,height:fixture.height,data:new Uint8ClampedArray(fixture.source)},before=new Uint8ClampedArray(image.data);
  for(const item of fixture.cases)assert.deepEqual([...colorRangeMask(image,item.settings)],item.expected);assert.deepEqual(image.data,before);
});
test('3 by 3 samples average premultiplied coverage and strict limits reject malformed inputs',()=>{
  const image={width:3,height:1,data:new Uint8ClampedArray([255,0,0,255,0,0,255,0,0,255,0,255])};assert.deepEqual(sampleRangeColor(image,1,0),[128,128,0]);assert.equal(sampleRangeColor(image,-1,0),null);assert.deepEqual(sampleRangeColor(image,0,0),[255,0,0]);
  const settings={include:[[255,0,0]],exclude:[],fuzziness:0,invert:false};assert.deepEqual([...colorRangeMask(image,settings)],[255,0,0]);assert.deepEqual([...colorRangeMask(image,{...settings,invert:true})],[0,255,255]);
  for(const change of [{include:[]},{include:[[256,0,0]]},{exclude:Array(33).fill([0,0,0])},{fuzziness:201},{fuzziness:NaN},{invert:1}])assert.throws(()=>colorRangeMask(image,{...settings,...change}));assert.throws(()=>colorRangeMask({...image,width:4},settings));
});
test('color range is one undoable selection edit without modifying saved document or resources, and stale callers cannot apply it',()=>{
  const session=new ProjectSession(undefined,{codecs}),view=session.install(newProject(4,2),null,true).project,before=session.current.data,bytes=Buffer.from(before.sourceBytes),source=png(4,2,[240,20,80,128]),settings={include:[[239,20,80]],exclude:[],fuzziness:2,invert:false};
  const changed=session.edit(view.id,view.revision,{kind:'selection',action:'colorRange',png:source,settings}).project;assert.ok(changed);assert.equal(changed.dirty,false);assert.equal(changed.selection.data.filter(Boolean).length,8);assert.deepEqual(session.current.data.sourceBytes,bytes);assert.equal(session.current.data.resources,before.resources);assert.equal(session.undoStack.length,1);assert.equal(session.edit(view.id,view.revision,{kind:'selection',action:'colorRange',png:source,settings}).error,'stale');
  assert.equal(session.history(changed.id,changed.revision,'undo').project.selection,undefined);const current=session.view().project,empty=session.edit(current.id,current.revision,{kind:'selection',action:'colorRange',png:source,settings:{...settings,include:[[0,0,255]],fuzziness:0}}).project;assert.equal(empty.revision,current.revision);assert.equal(empty.selection,undefined);session.close();
});
