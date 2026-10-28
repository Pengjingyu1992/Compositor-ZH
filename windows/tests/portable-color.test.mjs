import{test}from'node:test';
import assert from'node:assert/strict';
import{readFile}from'node:fs/promises';
import{createHash}from'node:crypto';
import{PORTABLE_COLOR_BASE64,PORTABLE_COLOR_SHA256}from'../packages/comp-bridge/portable-color-wasm.mjs';
import{portableColor}from'../packages/comp-bridge/portable-color.mjs';
import{defaultCameraRaw,validateCameraRaw,activeCameraRaw}from'../packages/comp-bridge/camera-raw-settings.mjs';
import{cameraRawPixels,cameraRawWhiteBalance,cameraRawAutoWhiteBalance,cameraRawCurveTables}from'../packages/comp-bridge/camera-raw.mjs';
import{cameraRawCorners,inverseHomography,cameraRawGeometry}from'../packages/comp-bridge/camera-raw-geometry.mjs';
import{reactive}from'vue';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
test('portable kernels match their source manifest and import no host functions or unbounded memory',async()=>{
  const metadata=JSON.parse(await readFile(new URL('../native/portable-color/build.json',import.meta.url))),bytes=Buffer.from(PORTABLE_COLOR_BASE64,'base64');assert.equal(sha(bytes),PORTABLE_COLOR_SHA256);assert.equal(sha(bytes),metadata.sha256);assert.equal(bytes.length,metadata.bytes);for(const[file,digest]of Object.entries(metadata.inputs))assert.equal(sha(await readFile(new URL('../native/portable-color/'+file,import.meta.url))),digest,file);assert.deepEqual(WebAssembly.Module.imports(new WebAssembly.Module(bytes)),[]);
  const color=portableColor();try{assert.throws(()=>color.api.memory.grow(8193),RangeError);assert.equal(color.api.color_allocate(600*1024**2),0);assert.equal(color.api.color_allocation_failed(),1);}finally{color.dispose();}
});
test('Camera Raw settings reject unknown schemas and geometry while disabled groups preserve their drafts',()=>{
  const defaults=defaultCameraRaw();assert.deepEqual(validateCameraRaw(),defaults);assert.deepEqual(validateCameraRaw(reactive(defaultCameraRaw())),defaults);for(const input of [{exposure:6},{glowStyle:'unknown'},{curve:{shadowSplit:95}},{mixer:{hue:[1]}},{mixer:{points:[{}]}},{calibration:{process:7}},{geometry:{guides:[{startX:NaN}]}},JSON.parse('{"__proto__":{"polluted":true}}')])assert.throws(()=>validateCameraRaw(input));const draft={exposure:2,curve:{darks:30},enabled:{light:false,curve:false}};assert.equal(activeCameraRaw(draft).exposure,0);assert.equal(activeCameraRaw(draft).curve.darks,0);assert.equal(draft.exposure,2);assert.equal({}.polluted,undefined);
});
test('identity and idle controls preserve soft alpha and hidden colors exactly; white balance solves a neutral response',()=>{
  const image={width:2,height:1,data:new Uint8ClampedArray([180,100,60,128,23,45,67,0])};assert.deepEqual(cameraRawPixels(image).data,image.data);assert.deepEqual(cameraRawPixels(image,{detail:{sharpenRadius:90},grainSize:80}).data,image.data);const wb=cameraRawWhiteBalance([.6,.5,.45]);assert.ok(wb);const decode=v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4,r=decode(.6)*(1+.35*wb.temperature/100+.15*wb.tint/100),g=decode(.5)*(1-.30*wb.tint/100),b=decode(.45)*(1-.35*wb.temperature/100+.15*wb.tint/100);assert.ok(Math.abs(r-g)<1e-8&&Math.abs(b-g)<1e-8);assert.equal(cameraRawWhiteBalance([0,1,1]),null);assert.ok(cameraRawAutoWhiteBalance(image));assert.deepEqual(cameraRawPixels(image,{exposure:1}).data.slice(4),image.data.slice(4));
});
test('curves keep endpoints and monotone interpolation; perspective correction maps corners and retains its source',()=>{
  const defaults=defaultCameraRaw(),tables=cameraRawCurveTables(defaults.curve);for(const table of tables)for(let index=0;index<256;index++)assert.ok(Math.abs(table[index]-index/255)<1e-7);const changed=cameraRawCurveTables({...defaults.curve,darks:45});assert.ok(changed[0][64]>tables[0][64]);assert.equal(changed[0][0],0);assert.equal(changed[0][255],1);
  assert.deepEqual(cameraRawCorners(20,10,defaults.geometry),[[0,0],[20,0],[20,10],[0,10]]);const from=[[0,0],[20,0],[20,10],[0,10]],matrix=inverseHomography(from,from);assert.deepEqual(matrix,[1,0,0,0,1,0,0,0]);assert.throws(()=>inverseHomography([[0,0],[0,0],[0,0],[0,0]],from));
  const image={width:20,height:10,data:Uint8ClampedArray.from({length:800},(_,index)=>index%4===3?255:120)},before=new Uint8ClampedArray(image.data),warped=cameraRawGeometry(image,{...defaults.geometry,vertical:45,rotate:12,constrainCrop:true});assert.equal(warped.data.length,image.data.length);assert.deepEqual(image.data,before);assert.ok(warped.data.some(value=>value===255));
});
test('all Camera Raw kernel groups match 25 independent native C fixtures, including previews and combined order',async()=>{
  const fixture=JSON.parse(await readFile(new URL('./golden/camera-raw-native.json',import.meta.url))),image={width:fixture.width,height:fixture.height,data:new Uint8ClampedArray(fixture.source)},before=new Uint8ClampedArray(image.data);
  for(const item of fixture.cases){const output=cameraRawPixels(image,item.settings,item.preview).data;let largest=0;for(let index=0;index<output.length;index++){const actual=index%4===3?output[index]:Math.round(output[index]*output[index-index%4+3]/255);largest=Math.max(largest,Math.abs(actual-item.expected[index]));}assert.ok(largest<=1,`${item.label}: premultiplied error ${largest}`);}assert.deepEqual(image.data,before);
});
