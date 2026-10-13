import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import omggif from 'omggif';
import * as codecs from '../packages/comp-bridge/codecs.mjs';
import { inspectGIF } from '../packages/comp-bridge/gif-validation.mjs';
import { encodeRasterEPS, decodeRasterEPS, epsBounds, postScriptSection } from '../packages/comp-bridge/eps-raster.mjs';
import { editProject, newProject } from '../packages/comp-bridge/edit.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { frameForLayer, projectForFrame } from '../packages/editor-adapter/animation.ts';
import { png } from './fixtures.mjs';

const colors = [[255,0,0,255], [0,255,0,255], [0,0,255,255]];
const payload = { frames: colors.map((color, i) => ({ png: png(8, 6, color), durationMS: [50,120,230][i] })), loopCount: 2 };
const pixelsForFrame = (project, i) => {
  const id = project.manifest.animation.frames[i].groupID;
  const layer = project.manifest.layers.find(layer => layer.parentID === id);
  return codecs.decodePNG(project.resources.get(`images/${layer.imageFile}`));
};
const pixel = (image, x, y) => Array.from(image.data.subarray((y*image.width+x)*4, (y*image.width+x+1)*4));

test('GIF round trip preserves every solid frame, duration and finite repeats', async () => {
  const encoded = codecs.exportGIF(payload), decoded = codecs.importGIF(encoded);
  assert.equal(decoded.manifest.version, 16);
  assert.equal(decoded.manifest.animation.loopCount, 2);
  assert.deepEqual(decoded.manifest.animation.frames.map(frame => frame.durationMS), [50,120,230]);
  colors.forEach((color, i) => assert.deepEqual(pixel(pixelsForFrame(decoded, i), 3, 2), color));
  await mkdir('playwright-report/codec-fixtures', { recursive: true });
  await writeFile('playwright-report/codec-fixtures/independent-animation.gif', encoded);
});

test('GIF opaque-to-transparent and fully transparent frames do not retain older pixels', () => {
  const decoded = codecs.importGIF(codecs.exportGIF({ frames: [
    { png: png(4, 3, [255,0,0,255]), durationMS: 100 },
    { png: png(4, 3, [0,0,0,0]), durationMS: 100 },
    { png: png(4, 3, [0,255,0,255]), durationMS: 100 }
  ], loopCount: 0 }));
  assert.equal(decoded.manifest.animation.loopCount, 0);
  assert.deepEqual(pixel(pixelsForFrame(decoded, 0), 1, 1), [255,0,0,255]);
  assert.deepEqual(pixel(pixelsForFrame(decoded, 1), 1, 1), [0,0,0,0]);
  assert.deepEqual(pixel(pixelsForFrame(decoded, 2), 1, 1), [0,255,0,255]);
});

test('GIF partial-frame disposal 2 and 3 clear and restore the correct areas', () => {
  const buffer = Buffer.alloc(4096), writer = new omggif.GifWriter(buffer, 4, 3, { palette: [0,0xff0000,0x00ff00,0x0000ff] });
  writer.addFrame(0,0,4,3,new Uint8Array(12).fill(1),{delay:5,disposal:1});
  writer.addFrame(1,1,1,1,Uint8Array.of(2),{delay:5,disposal:2,transparent:0});
  writer.addFrame(2,1,1,1,Uint8Array.of(3),{delay:5,disposal:3});
  writer.addFrame(3,1,1,1,Uint8Array.of(2),{delay:5});
  const decoded = codecs.importGIF(buffer.subarray(0, writer.end()));
  assert.deepEqual(pixel(pixelsForFrame(decoded, 1),1,1),[0,255,0,255]);
  assert.equal(pixel(pixelsForFrame(decoded,2),1,1)[3],0);
  assert.deepEqual(pixel(pixelsForFrame(decoded,2),2,1),[0,0,255,255]);
  assert.deepEqual(pixel(pixelsForFrame(decoded,3),2,1),[255,0,0,255]);
});

test('GIF control extensions apply to only the next frame', () => {
  const buffer=Buffer.alloc(4096), writer=new omggif.GifWriter(buffer,2,1,{palette:[0,0xff0000]});
  writer.addFrame(0,0,2,1,Uint8Array.of(1,1),{delay:7,transparent:0});
  writer.addFrame(0,0,2,1,Uint8Array.of(0,0));
  const decoded=codecs.importGIF(buffer.subarray(0,writer.end()));
  assert.deepEqual(decoded.manifest.animation.frames.map(f=>f.durationMS),[70,100]);
  assert.deepEqual(pixel(pixelsForFrame(decoded,1),0,0),[0,0,0,255]);
});

test('short interlaced GIFs reconstruct all four passes without skipping rows', () => {
  const buffer=Buffer.alloc(4096), writer=new omggif.GifWriter(buffer,2,3,{palette:[0,0xff0000,0x00ff00,0x0000ff]});
  writer.addFrame(0,0,2,3,Uint8Array.of(1,1,3,3,2,2));
  const gif=buffer.subarray(0,writer.end()), frame=inspectGIF(gif).frames[0];
  gif[frame.data_offset-1] |= 64;
  const image=pixelsForFrame(codecs.importGIF(gif),0);
  colors.forEach((color,y)=>assert.deepEqual(pixel(image,0,y),color));
});

test('malformed GIFs and allocation limits are rejected before decoding', () => {
  const encoded=codecs.exportGIF(payload);
  for (const end of [0,7,13,encoded.length-1,Math.floor(encoded.length/2)]) assert.throws(()=>codecs.importGIF(encoded.subarray(0,end)));
  const huge=Buffer.from(encoded);huge.writeUInt16LE(65535,6);assert.throws(()=>codecs.importGIF(huge),e=>e.code==='gifLimit');
  const disposal=Buffer.from(encoded), control=disposal.indexOf(Buffer.from([0x21,0xf9,4]));disposal[control+3]=(disposal[control+3]&3)|28;
  assert.throws(()=>codecs.importGIF(disposal),e=>e.code==='gifInvalid');
  for(const value of [-2,65536,NaN])assert.throws(()=>codecs.exportGIF({...payload,loopCount:value}));
  for(const durationMS of [0,11,655360])assert.throws(()=>codecs.exportGIF({...payload,frames:[{...payload.frames[0],durationMS}]}));
  assert.throws(()=>codecs.exportGIF({...payload,frames:[payload.frames[0],{png:png(9,6,colors[0]),durationMS:100}]}),e=>e.code==='gifLimit');
});

test('EPS round trip flattens soft alpha to white and preserves fractional resolution', async () => {
  const image={width:3,height:1,data:Uint8ClampedArray.of(255,0,0,255,0,0,255,128,33,66,99,0)};
  const encoded=encodeRasterEPS(image,144.25), decoded=decodeRasterEPS(encoded);
  assert.equal(decoded.resolution,144.25);
  assert.deepEqual(Array.from(decoded.data),[255,0,0,255,127,127,255,255,255,255,255,255]);
  await mkdir('playwright-report/codec-fixtures', { recursive: true });
  await writeFile('playwright-report/codec-fixtures/independent-raster.eps',encodeRasterEPS({...image,width:3,height:1},72));
});

test('EPS binary preview containers retain only the PostScript section', () => {
  const source=encodeRasterEPS({width:2,height:1,data:new Uint8ClampedArray(8)},72), header=Buffer.alloc(30);
  header.set([0xc5,0xd0,0xd3,0xc6]);header.writeUInt32LE(30,4);header.writeUInt32LE(source.length,8);
  const binary=Buffer.concat([header,source,Buffer.from('preview')]);
  assert.deepEqual(postScriptSection(binary),source);
  assert.equal(decodeRasterEPS(binary).width,2);
  header.writeUInt32LE(source.length+1000,8);assert.throws(()=>postScriptSection(Buffer.concat([header,source])),e=>e.code==='epsInvalid');
});

test('EPS negative origins, trailer bounds and oversized geometry are handled explicitly', () => {
  const normal=Buffer.from('%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: -2 -3 8 7\n');
  assert.deepEqual(epsBounds(normal),{width:20,height:20,x:-2,y:-3});
  assert.deepEqual(epsBounds(Buffer.from('%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: (atend)\n%%Trailer\n%%HiResBoundingBox: 1.5 2.5 5.5 6.5\n')),{width:8,height:8,x:1.5,y:2.5});
  assert.throws(()=>epsBounds(Buffer.from('%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 30000 30000\n')),e=>e.code==='epsLimit');
  const corrupt=Buffer.from(encodeRasterEPS({width:1,height:1,data:Uint8ClampedArray.of(1,2,3,255)}));corrupt[corrupt.length-1]=0;
  assert.throws(()=>decodeRasterEPS(corrupt),e=>e.code==='epsInvalid');
});

test('animation frame editing preserves unique resources, frame order and history', () => {
  const session=new ProjectSession(undefined,{codecs});session.install(codecs.importGIF(codecs.exportGIF(payload)));
  const edit=op=>{const result=session.edit(session.current.id,session.revision,{kind:'animation',...op});assert.ok(result.project,result.error);return session.current.data;};
  const first=session.current.data.manifest.animation.frames[0].groupID;
  let changed=edit({action:'duplicate',frameID:first});assert.equal(changed.manifest.animation.frames.length,4);
  assert.equal(new Set(changed.manifest.layers.map(l=>l.id)).size,changed.manifest.layers.length);
  const copied=changed.manifest.animation.frames[1].groupID;
  assert.deepEqual(pixelsForFrame(changed,0).data,pixelsForFrame(changed,1).data);
  changed=edit({action:'duration',frameID:copied,value:340});assert.equal(changed.manifest.animation.frames[1].durationMS,340);
  changed=edit({action:'move',frameID:copied,direction:1});assert.equal(changed.manifest.animation.frames[2].groupID,copied);
  changed=edit({action:'delete',frameID:copied});assert.equal(changed.manifest.animation.frames.length,3);
  session.history(session.current.id,session.revision,'undo');assert.equal(session.current.data.manifest.animation.frames.length,4);
  const before=session.current.data, revision=session.revision;
  assert.equal(session.edit(session.current.id,revision,{kind:'animation',action:'duration',frameID:first,value:11}).error,'invalid');
  assert.equal(session.current.data,before);assert.equal(session.revision,revision);
  session.close();
});

test('frame views hide inactive descendants but preserve shared overlays and original visibility', () => {
  const animation=codecs.importGIF(codecs.exportGIF(payload));
  const data=editProject(animation,{kind:'add',type:'pixels',name:'Shared overlay'},codecs), project={manifest:data.manifest,analysis:data.analysis};
  const active=project.manifest.animation.frames[1].groupID, row=project.analysis.rows.find(l=>l.parentID===active);
  assert.equal(frameForLayer(project,row.id),active);
  const visible=projectForFrame(project,active).analysis.rows.filter(l=>l.effectiveVisible&&!l.isGroup);
  assert.equal(visible.length,2);assert.ok(visible.some(l=>l.id===row.id));assert.ok(visible.some(l=>l.name==='Shared overlay'));
  assert.ok(project.analysis.rows.filter(l=>!l.isGroup).every(l=>l.effectiveVisible));
});
