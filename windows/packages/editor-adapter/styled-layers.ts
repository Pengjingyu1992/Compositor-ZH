import { makeCanvas, pngBytes } from './render';
export { remapRuns, rangeStyle } from './text-runs.mjs';
const rgb=(s:Record<string,any>)=>'rgb('+[s.red,s.green,s.blue].map(v=>Math.round(v*255)).join(',')+')';
import {layoutText,fontFamily} from '../comp-bridge/text-layout.mjs';
export async function renderText(style:Record<string,any>,owner?:{id:string;revision:string}) {
  if(style.pathLayout||style.warp){
    if(!owner)throw new Error('invalid');const result=await window.editor.textTools('render',{id:owner.id,revision:owner.revision,style:JSON.parse(JSON.stringify(style))});if(result.error||!result.png)throw new Error(result.error??'glyph');return new Uint8Array(result.png);
  }
  const [w,h]=style.boxSize.map((v:number)=>Math.ceil(v));if(w*h>16_000_000||w>30000||h>30000)throw new Error('limit');
  const c=makeCanvas(w,h),ctx=c.getContext('2d')!;
  const font=(name:string,size:number)=>size+'px "'+fontFamily(name).replace(/["\\]/g,'')+'", sans-serif';
  const glyphs=layoutText(style,(text:string,name:string,size:number)=>{ctx.font=font(name,size);return ctx.measureText(text).width;});
  ctx.textBaseline='alphabetic';
  for(const glyph of glyphs){ctx.save();ctx.translate(glyph.x,glyph.y);ctx.rotate(glyph.angle);ctx.font=font(glyph.font,style.fontSize);ctx.fillStyle=rgb(glyph.color);ctx.fillText(glyph.text,0,0);ctx.restore();}
  try{return await pngBytes(c);}finally{c.width=c.height=1;}
}
export async function renderShape(style:Record<string,any>,w:number,h:number) {
  w=Math.max(1,Math.ceil(w));h=Math.max(1,Math.ceil(h));if(w*h>16_000_000||w>30000||h>30000)throw new Error('limit');
  const c=makeCanvas(w,h),ctx=c.getContext('2d')!;ctx.fillStyle=ctx.strokeStyle=rgb(style);
  if(style.kind==='Ellipse'){ctx.beginPath();ctx.ellipse(w/2,h/2,w/2,h/2,0,0,Math.PI*2);ctx.fill();}
  else if(style.kind==='Line'){ctx.lineWidth=style.lineWidth;ctx.lineCap='round';ctx.beginPath();ctx.moveTo(style.start[0]*w,style.start[1]*h);ctx.lineTo(style.end[0]*w,style.end[1]*h);ctx.stroke();}
  else{ctx.beginPath();ctx.roundRect(0,0,w,h,Math.min(style.cornerRadius,w/2,h/2));ctx.fill();}
  try{return await pngBytes(c);}finally{c.width=c.height=1;}
}
