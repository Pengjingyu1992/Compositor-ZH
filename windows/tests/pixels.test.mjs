import {test} from 'node:test';
import assert from 'node:assert/strict';
import {adjustedPixels,effectPixels,curveValue,blurPlane} from '../packages/editor-adapter/pixels.mjs';
const image={width:2,height:1,data:new Uint8ClampedArray([64,128,192,128,20,40,60,255])};
test('invert uses straight sRGB and preserves soft alpha',()=>{const out=adjustedPixels(image,{kind:'Invert'});assert.deepEqual([...out.data],[191,127,63,128,235,215,195,255]);assert.equal(image.data[0],64);});
test('identity levels, curves, exposure and color balance preserve pixels',()=>{
  for(const kind of ['Levels','Curves','Exposure','Color Balance'])assert.deepEqual(adjustedPixels(image,{kind}).data,image.data);
  for(let i=0;i<=255;i++)assert.ok(Math.abs(curveValue([{x:0,y:0},{x:255,y:255}],i/255)-i/255)<1e-6);
});
test('seeded noise/grain are deterministic; inner effects preserve alpha',()=>{
  for(const kind of ['Grain','Add Noise'])assert.deepEqual(adjustedPixels(image,{kind}).data,adjustedPixels(image,{kind}).data);
  const out=effectPixels(image,{colorOverlay:{enabled:true,red:1,green:0,blue:0,opacity:.5}});assert.equal(out.data[3],128);assert.equal(out.data[7],255);
});
test('blur is bounded and constant fields remain constant',()=>{const a=new Float32Array(16).fill(.25);assert.ok(blurPlane(a,4,4,100).every(v=>Math.abs(v-.25)<1e-6));});
test('positive saturation reaches full color while neutrals remain neutral',()=>{
  const a={width:2,height:1,data:new Uint8ClampedArray([100,150,200,255,128,128,128,128])};
  const out=adjustedPixels(a,{kind:'Hue/Saturation',saturation:100});assert.deepEqual([...out.data],[45,150,255,255,128,128,128,128]);
});
test('exposure applies stops in linear light while preserving coverage',()=>{
  const out=adjustedPixels(image,{kind:'Exposure',exposureSettings:{exposure:1}});assert.deepEqual([...out.data.slice(0,4)],[90,176,255,128]);
});
