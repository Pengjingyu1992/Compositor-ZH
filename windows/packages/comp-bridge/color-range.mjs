const fail=()=>{throw Object.assign(new Error('invalid'),{code:'invalid'});};
function surface(image){if(!Number.isInteger(image?.width)||!Number.isInteger(image.height)||image.width<1||image.height<1||image.width>30000||image.height>30000||image.width*image.height>16_000_000||!(image.data instanceof Uint8Array||image.data instanceof Uint8ClampedArray)||image.data.length!==image.width*image.height*4)fail();}
function colors(value){if(!Array.isArray(value)||value.length>32||value.some(color=>!Array.isArray(color)||color.length!==3||color.some(channel=>!Number.isInteger(channel)||channel<0||channel>255)))fail();return value;}
// CoreGraphics samples the native canvas as premultiplied bytes. Reproduce its
// byte quantization before matching so soft alpha has the same color boundary.
const straight=new Uint8Array(65536);for(let alpha=1;alpha<256;alpha++)for(let color=0;color<256;color++)straight[alpha*256+color]=Math.floor((Math.round(color*alpha/255)*255+alpha/2)/alpha);
export function colorRangeMask(image,settings){
  surface(image);const include=colors(settings?.include),exclude=colors(settings.exclude??[]),fuzziness=settings.fuzziness;
  if(!include.length||!Number.isInteger(fuzziness)||fuzziness<0||fuzziness>200||typeof settings.invert!=='boolean')fail();
  const mask=new Uint8Array(image.width*image.height),pixels=image.data;
  const near=(r,g,b,list)=>list.some(color=>Math.abs(r-color[0])<=fuzziness&&Math.abs(g-color[1])<=fuzziness&&Math.abs(b-color[2])<=fuzziness);
  for(let pixel=0;pixel<mask.length;pixel++){const index=pixel*4,alpha=pixels[index+3],base=alpha*256;let match=false;if(alpha){const r=straight[base+pixels[index]],g=straight[base+pixels[index+1]],b=straight[base+pixels[index+2]];match=near(r,g,b,include)&&!near(r,g,b,exclude);}mask[pixel]=(settings.invert?!match:match)?255:0;}
  return mask;
}
export function sampleRangeColor(image,x,y){
  surface(image);if(!Number.isFinite(x)||!Number.isFinite(y))fail();x=Math.floor(x);y=Math.floor(y);if(x<0||x>=image.width||y<0||y>=image.height)return null;
  const sums=[0,0,0,0];for(let row=Math.max(0,y-1);row<=Math.min(image.height-1,y+1);row++)for(let column=Math.max(0,x-1);column<=Math.min(image.width-1,x+1);column++){const offset=(row*image.width+column)*4,alpha=image.data[offset+3];for(let channel=0;channel<3;channel++)sums[channel]+=Math.round(image.data[offset+channel]*alpha/255);sums[3]+=alpha;}
  return sums[3]?sums.slice(0,3).map(sum=>Math.min(255,Math.floor((sum*255+sums[3]/2)/sums[3]))):null;
}
