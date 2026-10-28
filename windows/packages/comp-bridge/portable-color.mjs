import{PORTABLE_COLOR_BASE64}from'./portable-color-wasm.mjs';
let module;
const fail=()=>{throw Object.assign(new Error('limit'),{code:'limit'});};
export function portableColor(){
  module??=new WebAssembly.Module(Uint8Array.from(atob(PORTABLE_COLOR_BASE64),character=>character.charCodeAt(0)));
  const api=new WebAssembly.Instance(module,{}).exports,pointers=[];
  api.color_reset_failure();
  return{
    api,
    put(value){const bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength),pointer=api.color_allocate(bytes.length||1);if(!pointer)fail();pointers.push(pointer);new Uint8Array(api.memory.buffer,pointer,bytes.length).set(bytes);return pointer;},
    call(name,...args){try{api[name](...args);}catch(error){if(error instanceof WebAssembly.RuntimeError)fail();throw error;}if(api.color_allocation_failed())fail();},
    bytes(pointer,length){return new Uint8Array(api.memory.buffer,pointer,length).slice();},
    dispose(){for(const pointer of pointers)api.free(pointer);pointers.length=0;}
  };
}
