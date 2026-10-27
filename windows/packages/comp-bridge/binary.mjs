export function encodeBinary(bytes) {
  if(typeof Buffer!=='undefined')return Buffer.from(bytes).toString('base64');
  let result='';for(let i=0;i<bytes.length;i+=32768)result+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(result);
}
export function decodeBinary(text,length) {
  const fail=()=>{const error=new Error('invalid');error.code='invalid';throw error;};
  if(typeof text!=='string'||text.length!==4*Math.ceil(length/3)||/[^A-Za-z0-9+/=]/.test(text))fail();
  const bytes=typeof Buffer!=='undefined'?new Uint8Array(Buffer.from(text,'base64')):Uint8Array.from(atob(text),c=>c.charCodeAt(0));
  if(bytes.length!==length||encodeBinary(bytes)!==text)fail();return bytes;
}
