import { makeCanvas, pngBytes } from './render';
const rgb=(s:Record<string,any>)=>'rgb('+[s.red,s.green,s.blue].map(v=>Math.round(v*255)).join(',')+')';
const family=(v:string)=>({'ArialMT':'Arial','Helvetica':'Arial','MicrosoftYaHei':'Microsoft YaHei','SimSun':'SimSun','SegoeUI':'Segoe UI'} as Record<string,string>)[v]??v;
export function remapRuns(runs:any[],before:string,after:string) {
  let start=0,suffix=0;while(start<Math.min(before.length,after.length)&&before[start]===after[start])start++;
  while(suffix<Math.min(before.length-start,after.length-start)&&before[before.length-1-suffix]===after[after.length-1-suffix])suffix++;
  const oldEnd=before.length-suffix,shift=after.length-before.length;
  return runs.flatMap(r=>{const end=r.location+r.length;if(end<=start)return [{...r}];if(r.location>=oldEnd)return [{...r,location:r.location+shift}];return [{...r,location:Math.min(r.location,start),length:Math.max(0,(end>oldEnd?end+shift:after.length-suffix)-Math.min(r.location,start))}];}).filter(r=>r.length>0&&r.location+r.length<=after.length);
}
export function rangeStyle(runs:any[],start:number,end:number,style:Record<string,unknown>) {
  if(end<=start)return runs;const next=runs.flatMap(r=>{const right=r.location+r.length;if(right<=start||r.location>=end)return [{...r}];return [...(r.location<start?[{...r,length:start-r.location}]:[]),...(right>end?[{...r,location:end,length:right-end}]:[])];});
  return [...next,{location:start,length:end-start,...style}].sort((a,b)=>a.location-b.location);
}
export async function renderText(style:Record<string,any>) {
  const [w,h]=style.boxSize.map((v:number)=>Math.ceil(v));if(w*h>16_000_000||w>30000||h>30000)throw new Error('limit');
  const c=makeCanvas(w,h),ctx=c.getContext('2d')!,size=style.fontSize,leading=style.leading||size*1.2,tracking=style.tracking||0,padding=12;
  const Segmenter=(Intl as any).Segmenter,segments: {segment:string;index:number}[]=Segmenter?[...new Segmenter(undefined,{granularity:'grapheme'}).segment(style.content)]:Array.from(style.content).map((segment,index)=>({segment,index}));
  type Glyph={text:string;index:number;width:number;color:string;font:string};const lines:Glyph[][]=[[]];let width=0;
  for(const seg of segments){if(seg.segment==='\n'){lines.push([]);width=0;continue;}const run=(style.fontRuns??[]).find((r:any)=>seg.index>=r.location&&seg.index<r.location+r.length),col=(style.colorRuns??[]).find((r:any)=>seg.index>=r.location&&seg.index<r.location+r.length);
    const font=size+'px "'+family(run?.fontName??style.fontName).replace(/["\\]/g,'')+'", sans-serif';ctx.font=font;const advance=ctx.measureText(seg.segment).width+tracking;
    if(width+advance>w-padding*2&&lines.at(-1)!.length){lines.push([]);width=0;}lines.at(-1)!.push({text:seg.segment,index:seg.index,width:advance,color:rgb(col??style),font});width+=advance;
  }
  ctx.textBaseline='alphabetic';for(let n=0;n<lines.length;n++){const line=lines[n],length=line.reduce((v,g)=>v+g.width,0)-tracking;let x=style.alignment==='Center'?(w-length)/2:style.alignment==='Right'?w-padding-length:padding;const y=padding+size+n*leading;if(y-size>h)break;for(const g of line){ctx.font=g.font;ctx.fillStyle=g.color;ctx.fillText(g.text,x,y);x+=g.width;}}
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
