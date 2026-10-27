import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseColorLUT, sampleColorLUT, posterColorFilter, halftonePixels, IDENTITY_MIXER } from '../packages/comp-bridge/poster-color.mjs';
import { applySelectedFilter } from '../packages/comp-bridge/raster-tools.mjs';
const image={width:2,height:1,data:new Uint8ClampedArray([200,100,50,255,120,60,30,128])};
test('1D/3D cube tables honor red-fast ordering, domains, interpolation and strict parsing',()=>{
  const one=parseColorLUT('TITLE "Synthetic"\nLUT_1D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n0 0 0\n1 1 1');
  assert.deepEqual(sampleColorLUT(one,[0,-1,1]),[.5,0,1]);
  const values=[];for(let b=0;b<2;b++)for(let g=0;g<2;g++)for(let r=0;r<2;r++)values.push(`${b} ${g} ${r}`);
  const table=parseColorLUT(`LUT_3D_SIZE 2\n${values.join('\n')}`);
  const result=sampleColorLUT(table,[.2,.4,.8]);result.forEach((v,i)=>assert.ok(Math.abs(v-[.8,.4,.2][i])<1e-12));
  for(const text of ['LUT_1D_SIZE 2\n0 0 0','LUT_3D_SIZE 66','LUT_1D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\n0 0 0\n1 1 1','LUT_1D_SIZE 2\n0 0 NaN\n1 1 1','LUT_1D_SIZE 2\n0x0 0 0\n1 1 1'])assert.throws(()=>parseColorLUT(text));
  assert.throws(()=>parseColorLUT(new Uint8Array([255,254])));
});
test('channel mixer and selective-color ranges retain alpha, hidden RGB and immutable source',()=>{
  const source=new Uint8ClampedArray(image.data),identity=posterColorFilter(image,'Channel Mixer',{coefficients:IDENTITY_MIXER});assert.deepEqual(identity.data,source);
  const swap=posterColorFilter(image,'Channel Mixer',{coefficients:[0,0,100,0,0,100,0,0,100,0,0,0]});assert.deepEqual([...swap.data],[50,100,200,255,30,60,120,128]);
  const adjusted=posterColorFilter(image,'Selective Color',{relative:true,adjustments:{Reds:[100,0,0,0]}});assert.ok(adjusted.data[0]<source[0]);assert.equal(adjusted.data[1],source[1]);assert.equal(adjusted.data[7],128);
  assert.deepEqual(image.data,source);assert.throws(()=>posterColorFilter(image,'Channel Mixer',{coefficients:[1]}));assert.throws(()=>posterColorFilter(image,'Selective Color',{adjustments:{Unknown:[0,0,0,0]}}));
  const transparent={...image,data:new Uint8ClampedArray([23,45,67,0,120,60,30,128])};
  assert.deepEqual([...posterColorFilter(transparent,'Channel Mixer',{coefficients:IDENTITY_MIXER}).data.slice(0,4)],[23,45,67,0]);
});
test('LUTs blend in encoded or linear sRGB and missing tables are rejected',()=>{
  const table=parseColorLUT('LUT_1D_SIZE 2\n0 0 0\n0 0 0');
  assert.deepEqual(posterColorFilter(image,'Color Lookup',{table,strength:0}).data,image.data);
  for(const space of ['Encoded sRGB','Linear sRGB']){const result=posterColorFilter(image,'Color Lookup',{table,strength:50,space});assert.equal(result.data[0],100);assert.equal(result.data[3],255);assert.equal(result.data[7],128);}
  assert.throws(()=>posterColorFilter(image,'Color Lookup',{}));
});
test('RGB, grayscale and legacy halftone dots agree with independent macOS C reference samples',async()=>{
  const fixture=JSON.parse(await readFile(new URL('./golden/poster-color-native.json',import.meta.url)));
  const sample={width:fixture.width,height:fixture.height,data:new Uint8ClampedArray(fixture.source)};
  for(const item of fixture.cases){const result=halftonePixels(sample,item.settings);let largest=0;for(let i=0;i<result.data.length;i++)largest=Math.max(largest,Math.abs(result.data[i]-item.expected[i]));assert.ok(largest<=1,`${item.settings.screen}/${item.settings.shape}: error ${largest}`);}
});
test('halftone automatic channels, zero strength, selection and hidden pixels retain their contracts',()=>{
  const gray={width:8,height:8,data:Uint8ClampedArray.from({length:256},(_,i)=>i%4===3?128:120)};
  assert.deepEqual(halftonePixels(gray,{screen:'Automatic Channels'}).data,halftonePixels(gray,{screen:'Grayscale Screen'}).data);
  assert.deepEqual(halftonePixels(image,{strength:0}).data,image.data);
  const empty={width:2,height:1,data:new Uint8Array(2)},placement={origin:[0,0],size:[2,1],rotation:0};
  assert.deepEqual(applySelectedFilter(image,placement,empty,'Channel Mixer',{coefficients:[0,0,100,0,0,100,0,0,100,0,0,0]}).data,image.data);
  assert.throws(()=>halftonePixels(image,{size:Infinity}));assert.throws(()=>halftonePixels(image,{screen:'unknown'}));
});
