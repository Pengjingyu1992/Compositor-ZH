// Arrangement and symmetry follow Pentrado's Rect/Delta and stamp-transform
// contracts. Geometry stays independent of UI, history and resource ownership.
export const limit = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
export function bounds(p) {
  const [x,y]=p.origin,[w,h]=p.size,a=p.rotation*Math.PI/180,c=Math.abs(Math.cos(a)),s=Math.abs(Math.sin(a));
  const bw=w*c+h*s,bh=w*s+h*c;
  return {x:x+w/2-bw/2,y:y+h/2-bh/2,w:bw,h:bh};
}
export function union(rects) {
  if(!rects.length)return {x:0,y:0,w:0,h:0};
  const x=Math.min(...rects.map(r=>r.x)),y=Math.min(...rects.map(r=>r.y));
  return {x,y,w:Math.max(...rects.map(r=>r.x+r.w))-x,h:Math.max(...rects.map(r=>r.y+r.h))-y};
}
export function arrange(rects,op,reference) {
  const factors={left:['x',0],hcenter:['x',.5],right:['x',1],top:['y',0],vcenter:['y',.5],bottom:['y',1]};
  const delta=rects.map(()=>[0,0]);
  if(factors[op]){
    const [axis,f]=factors[op],size=axis==='x'?'w':'h',index=axis==='x'?0:1,ref=reference??union(rects);
    return rects.map(r=>{const d=[0,0];d[index]=ref[axis]+ref[size]*f-r[axis]-r[size]*f;return d;});
  }
  if(!['hspread','vspread','hgap','vgap'].includes(op))throw new Error('invalid');
  if(rects.length<3)return delta;
  const axis=op.startsWith('h')?'x':'y',size=axis==='x'?'w':'h',index=axis==='x'?0:1,gap=op.endsWith('gap');
  const order=rects.map((r,i)=>({r,i})).sort((a,b)=>(a.r[axis]+(gap?0:a.r[size]/2))-(b.r[axis]+(gap?0:b.r[size]/2)));
  const first=order[0].r,last=order.at(-1).r;
  if(!gap){const step=(last[axis]+last[size]/2-first[axis]-first[size]/2)/(order.length-1);for(let n=1;n<order.length-1;n++)delta[order[n].i][index]=first[axis]+first[size]/2+n*step-order[n].r[axis]-order[n].r[size]/2;}
  else {const spacing=(last[axis]-first[axis]-order.slice(0,-1).reduce((n,v)=>n+v.r[size],0))/(order.length-1);let at=first[axis]+first[size];for(let n=1;n<order.length-1;n++){delta[order[n].i][index]=at+spacing-order[n].r[axis];at+=spacing+order[n].r[size];}}
  return delta;
}
export function toLocal(p,t,w,h) {
  const [x,y]=t.origin,[tw,th]=t.size,a=-t.rotation*Math.PI/180,dx=p[0]-x-tw/2,dy=p[1]-y-th/2;
  return [((Math.cos(a)*dx-Math.sin(a)*dy)*(t.flipX?-1:1)+tw/2)*w/tw,((Math.sin(a)*dx+Math.cos(a)*dy)*(t.flipY?-1:1)+th/2)*h/th];
}
export function toDocument(p,t,w,h) {
  const [tw,th]=t.size,a=t.rotation*Math.PI/180,dx=(p[0]*tw/w-tw/2)*(t.flipX?-1:1),dy=(p[1]*th/h-th/2)*(t.flipY?-1:1);
  return [t.origin[0]+tw/2+Math.cos(a)*dx-Math.sin(a)*dy,t.origin[1]+th/2+Math.sin(a)*dx+Math.cos(a)*dy];
}
export function symmetryPoints(p,mode,cx,cy,sectors=6) {
  if(mode==='horizontal')return [p,[2*cx-p[0],p[1]]];
  if(mode==='vertical')return [p,[p[0],2*cy-p[1]]];
  if(mode==='both')return [p,[2*cx-p[0],p[1]],[p[0],2*cy-p[1]],[2*cx-p[0],2*cy-p[1]]];
  if(mode==='radial')return Array.from({length:limit(Math.round(sectors),2,16)},(_,i)=>{const a=i*2*Math.PI/limit(Math.round(sectors),2,16),x=p[0]-cx,y=p[1]-cy;return [cx+x*Math.cos(a)-y*Math.sin(a),cy+x*Math.sin(a)+y*Math.cos(a)];});
  return [p];
}
export function validSurface(w,h) {
  if(![w,h].every(n=>Number.isInteger(n)&&n>0&&n<=30000)||w*h>16_000_000)throw new Error('limit');
}
export function maskBounds(mask,w,h) {
  let x=w,y=h,right=0,bottom=0;
  for(let at=0;at<mask.length;at++)if(mask[at]){const px=at%w,py=Math.floor(at/w);x=Math.min(x,px);y=Math.min(y,py);right=Math.max(right,px+1);bottom=Math.max(bottom,py+1);}
  return right>x&&bottom>y?{x,y,w:right-x,h:bottom-y}:undefined;
}
export function shapeMask(w,h,kind,start,end,points=[]) {
  validSurface(w,h);const out=new Uint8Array(w*h);
  const x0=Math.min(start[0],end[0]),y0=Math.min(start[1],end[1]),rw=Math.max(1,Math.abs(end[0]-start[0])),rh=Math.max(1,Math.abs(end[1]-start[1]));
  let rect=kind==='lasso'?union(points.map(p=>({x:p[0],y:p[1],w:1,h:1}))):{x:x0,y:y0,w:rw,h:rh};
  for(let y=Math.max(0,Math.floor(rect.y));y<Math.min(h,Math.ceil(rect.y+rect.h));y++)for(let x=Math.max(0,Math.floor(rect.x));x<Math.min(w,Math.ceil(rect.x+rect.w));x++){
    let inside=true;
    if(kind==='ellipse')inside=((x+.5-x0-rw/2)/(rw/2))**2+((y+.5-y0-rh/2)/(rh/2))**2<=1;
    if(kind==='lasso'){inside=false;for(let i=0,j=points.length-1;i<points.length;j=i++){const a=points[i],b=points[j];if((a[1]>y+.5)!==(b[1]>y+.5)&&x+.5<(b[0]-a[0])*(y+.5-a[1])/(b[1]-a[1])+a[0])inside=!inside;}}
    if(inside)out[y*w+x]=255;
  }
  return out;
}
export function combineMasks(before,incoming,mode='replace') {
  if(before&&before.length!==incoming.length)throw new Error('invalid');
  return Uint8Array.from(incoming,(v,i)=>mode==='add'?Math.max(before?.[i]??0,v):mode==='subtract'?Math.max(0,(before?.[i]??0)-v):mode==='intersect'?Math.min(before?.[i]??0,v):v);
}
export function floodMask(image,x,y,tolerance=24,contiguous=true) {
  const {width:w,height:h,data}=image;validSurface(w,h);x=Math.floor(x);y=Math.floor(y);
  const out=new Uint8Array(w*h);if(x<0||y<0||x>=w||y>=h)return out;
  const at=(y*w+x)*4,ref=Array.from(data.slice(at,at+4)),match=i=>{const a=data[i*4+3],alpha=ref[3]/255;return Math.max(Math.abs(a-ref[3]),...ref.slice(0,3).map((v,c)=>Math.abs(data[i*4+c]*a/255-v*alpha)))<=tolerance;};
  if(!contiguous){for(let i=0;i<w*h;i++)if(match(i))out[i]=255;return out;}
  // Mark neighbors on enqueue, bounding the queue to one entry per pixel.
  const seen=new Uint8Array(w*h),queue=new Int32Array(w*h);let head=0,tail=1;queue[0]=y*w+x;seen[queue[0]]=1;
  while(head<tail){const i=queue[head++];if(!match(i))continue;out[i]=255;const px=i%w;
    for(const n of [px?i-1:-1,px<w-1?i+1:-1,i>=w?i-w:-1,i<w*(h-1)?i+w:-1])if(n>=0&&!seen[n]){seen[n]=1;queue[tail++]=n;}
  }
  return out;
}
function extremum(mask,w,h,radius,max) {
  const r=limit(Math.round(radius),0,500),temp=new Uint8Array(mask.length),out=new Uint8Array(mask.length);
  const line=(size,read,write)=>{const queue=new Int32Array(size+2*r+1);let head=0,tail=0;for(let i=-r;i<size+r;i++){while(tail>head&&(max?read(queue[tail-1])<=read(i):read(queue[tail-1])>=read(i)))tail--;queue[tail++]=i;while(queue[head]<i-2*r)head++;if(i>=r)write(i-r,read(queue[head]));}};
  for(let y=0;y<h;y++)line(w,x=>x<0||x>=w?0:mask[y*w+x],(x,v)=>temp[y*w+x]=v);
  for(let x=0;x<w;x++)line(h,y=>y<0||y>=h?0:temp[y*w+x],(y,v)=>out[y*w+x]=v);
  return out;
}
export function modifyMask(mask,w,h,op,amount=1) {
  if(op==='invert')return Uint8Array.from(mask,v=>255-v);
  if(op==='expand'||op==='contract')return extremum(mask,w,h,amount,op==='expand');
  if(op!=='feather')throw new Error('invalid');
  const r=limit(Math.round(amount),0,500),temp=new Float32Array(mask.length),out=new Uint8Array(mask.length),span=r*2+1;
  for(let y=0;y<h;y++){let sum=0;for(let x=-r;x<=r;x++)sum+=x<0||x>=w?0:mask[y*w+x];for(let x=0;x<w;x++){temp[y*w+x]=sum/span;sum+=(x+r+1<w?mask[y*w+x+r+1]:0)-(x-r>=0?mask[y*w+x-r]:0);}}
  for(let x=0;x<w;x++){let sum=0;for(let y=-r;y<=r;y++)sum+=y<0||y>=h?0:temp[y*w+x];for(let y=0;y<h;y++){out[y*w+x]=Math.round(sum/span);sum+=(y+r+1<h?temp[(y+r+1)*w+x]:0)-(y-r>=0?temp[(y-r)*w+x]:0);}}
  return out;
}
export function selectionCoverage(selection,point) {
  if(!selection)return 1;
  const x=Math.floor(point[0]),y=Math.floor(point[1]);
  return x<0||y<0||x>=selection.width||y>=selection.height?0:selection.data[y*selection.width+x]/255;
}
