import{readFile}from'node:fs/promises';
import{createHash}from'node:crypto';
import{PORTABLE_COLOR_BASE64,PORTABLE_COLOR_SHA256}from'../packages/comp-bridge/portable-color-wasm.mjs';
export async function verifyPortableColor(){
  const directory=new URL('../native/portable-color/',import.meta.url),metadata=JSON.parse(await readFile(new URL('build.json',directory))),bytes=Buffer.from(PORTABLE_COLOR_BASE64,'base64'),sha=value=>createHash('sha256').update(value).digest('hex');
  if(metadata.schema!==1||metadata.sha256!==PORTABLE_COLOR_SHA256||sha(bytes)!==metadata.sha256||bytes.length!==metadata.bytes||WebAssembly.Module.imports(new WebAssembly.Module(bytes)).length)throw new Error('Portable color artifact does not match its source manifest');
  for(const[file,digest]of Object.entries(metadata.inputs))if(!/^[A-Za-z][A-Za-z.]+$/.test(file)||sha(await readFile(new URL(file,directory)))!==digest)throw new Error('Portable color source changed; rebuild the module: '+file);
  return metadata;
}
