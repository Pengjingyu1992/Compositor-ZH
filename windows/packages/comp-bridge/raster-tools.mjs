import { limit, toDocument, toLocal, symmetryPoints, selectionCoverage, floodMask, validSurface } from './editor-math.mjs';
import { adjustedPixels, blurPlane } from '../editor-adapter/pixels.mjs';
export const FILTERS = ['Gaussian Blur','Motion Blur','Add Noise','Sharpen','Mosaic','Dither','Vignette','Bloom / Glow','Tonal Contrast','Lens Correction','Camera Raw Filter','Remove Background','Content-Aware Fill','Curves','Exposure','Gradient Map','Grain','Black & White','Color Balance','Invert','Desaturate'];
const color = v => v.map(n=>limit(n,0,255));
function blend(data,at,rgb,alpha,erase=false,lockAlpha=false) {
  const old=data[at+3]/255;
  if(erase){if(!lockAlpha)data[at+3]*=1-alpha;return;}
  const a=alpha+(old*(1-alpha));if(!a)return;
  for(let c=0;c<3;c++)data[at+c]=(rgb[c]*alpha+data[at+c]*old*(1-alpha))/a;
  data[at+3]=(lockAlpha?old:a)*255;
}
export function fillPixels(image,t,selection,settings={},coverage) {
  const out={...image,data:new Uint8ClampedArray(image.data)},w=image.width,h=image.height;
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
    const doc=toDocument([x+.5,y+.5],t,w,h),mask=selectionCoverage(selection,doc)*(coverage?coverage[y*w+x]/255:1),at=(y*w+x)*4;
    if(!mask)continue;
    if(settings.action==='clear'){if(settings.mask)blend(out.data,at,[0,0,0],mask*(settings.opacity??1));else blend(out.data,at,[0,0,0],mask,true);continue;}
    let rgb=settings.color??[0,0,0],alpha=(settings.opacity??1)*mask;
    if(settings.action==='gradient'){
      const [a,b]=settings.points,dx=b[0]-a[0],dy=b[1]-a[1],length=Math.max(1,dx*dx+dy*dy);
      let v=settings.radial?Math.hypot(doc[0]-a[0],doc[1]-a[1])/Math.sqrt(length):((doc[0]-a[0])*dx+(doc[1]-a[1])*dy)/length;
      v=limit(v,0,1);if(settings.reverse)v=1-v;
      rgb=rgb.map((n,c)=>n+(settings.background[c]-n)*v);if(settings.transparent)alpha*=1-v;
    }
    blend(out.data,at,rgb,alpha,false,settings.lockAlpha);
  }
  return out;
}
const nearest=(src,w,h,x,y)=>{x=Math.round(x);y=Math.round(y);return x<0||y<0||x>=w||y>=h?null:Array.from(src.slice((y*w+x)*4,(y*w+x)*4+4));};
export function strokePixels(image,t,selection,settings) {
  const {width:w,height:h}=image;validSurface(w,h);
  const original=image.data,out=new Uint8ClampedArray(original),coverage=new Float32Array(w*h),size=settings.size??24,opacity=settings.opacity??1,hardness=settings.hardness??1;
  const points=settings.points,mode=settings.mode??'brush',spacing=Math.max(.5,size*(settings.spacing??.18));
  let initial=points[0],previous;
  const stamp=(doc,pressure)=>{
    const p=toLocal(doc,t,w,h),rx=size/2*w/t.size[0],ry=size/2*h/t.size[1],x0=Math.max(0,Math.floor(p[0]-rx)),x1=Math.min(w-1,Math.ceil(p[0]+rx)),y0=Math.max(0,Math.floor(p[1]-ry)),y1=Math.min(h-1,Math.ceil(p[1]+ry));
    let offset=[0,0],correction=[0,0,0];
    if(mode==='clone'){if(!settings.source)throw new Error('source');const start=toLocal(initial,t,w,h),source=toLocal(settings.source,t,w,h);offset=[source[0]-start[0],source[1]-start[1]];}
    if(mode==='healing'){
      const center=nearest(original,w,h,...p);let score=Infinity;
      for(const [dx,dy] of [[2,0],[-2,0],[0,2],[0,-2],[1.5,1.5],[-1.5,-1.5],[1.5,-1.5],[-1.5,1.5]]){
        const sample=nearest(original,w,h,p[0]+dx*rx,p[1]+dy*ry);if(!sample||!sample[3])continue;
        const value=center?sample.slice(0,3).reduce((n,v,c)=>n+(v-center[c])**2,0):0;
        if(value<score){score=value;offset=[dx*rx,dy*ry];correction=center?sample.slice(0,3).map((v,c)=>center[c]-v):[0,0,0];}
      }if(!Number.isFinite(score))return;
    }
    for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++){
      const distance=Math.hypot((x+.5-p[0])/Math.max(.5,rx),(y+.5-p[1])/Math.max(.5,ry));if(distance>1)continue;
      const edge=distance<=hardness?1:(1-distance)/Math.max(.001,1-hardness),docPoint=toDocument([x+.5,y+.5],t,w,h);
      const i=y*w+x,at=i*4,cov=opacity*pressure*edge*selectionCoverage(selection,docPoint)*(settings.lockAlpha?original[at+3]/255:1);
      if(cov<=coverage[i])continue;const delta=(cov-coverage[i])/(1-coverage[i]||1);coverage[i]=cov;
      let sample=settings.color??[0,0,0];
      if(mode==='clone'||mode==='healing'){const src=nearest(original,w,h,x+offset[0],y+offset[1]);if(!src)continue;sample=color(src.slice(0,3).map((v,c)=>v+correction[c]));blend(out,at,sample,delta*src[3]/255,false,settings.lockAlpha);continue;}
      if(mode==='blur'){
        const values=[0,0,0,0];let n=0;
        for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++){const src=nearest(original,w,h,x+dx,y+dy);if(src){n++;for(let c=0;c<4;c++)values[c]+=src[c];}}
        if(n)for(let c=0;c<4;c++)out[at+c]=out[at+c]*(1-delta)+values[c]/n*delta;continue;
      }
      if(mode==='smudge'||mode==='liquify'){
        const src=nearest(out,w,h,x-(doc[0]-(previous?.[0]??doc[0]))*w/t.size[0],y-(doc[1]-(previous?.[1]??doc[1]))*h/t.size[1]);
        if(src)for(let c=0;c<4;c++)out[at+c]=out[at+c]*(1-delta)+src[c]*delta;continue;
      }
      if(settings.mask)sample=mode==='eraser'?[0,0,0]:[255,255,255];
      blend(out,at,sample,delta,mode==='eraser'&&!settings.mask,settings.lockAlpha);
    }
  };
  let stamps=0;
  for(let n=0;n<points.length;n++){
    const a=points[Math.max(0,n-1)],b=points[n],steps=n?Math.max(1,Math.ceil(Math.hypot(b[0]-a[0],b[1]-a[1])/spacing)):1;
    if(stamps+steps>20000)throw new Error('limit');
    for(let k=n?1:0;k<=(n?steps:0);k++){
      const f=n?k/steps:0,doc=[a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f],pressure=settings.pressure?limit((a[2]??1)+((b[2]??1)-(a[2]??1))*f,.05,1):1;
      for(const p of symmetryPoints(doc,settings.symmetry,settings.cx??0,settings.cy??0,settings.sectors))stamp(p,pressure);
      previous=doc;stamps++;
    }
  }
  return {width:w,height:h,data:out};
}
export function resizePixels(image,w,h,nearestNeighbor=false) {
  validSurface(w,h);const out=new Uint8ClampedArray(w*h*4),sw=image.width,sh=image.height;
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
    const sx=(x+.5)*sw/w-.5,sy=(y+.5)*sh/h-.5,at=(y*w+x)*4;
    if(nearestNeighbor){const p=nearest(image.data,sw,sh,limit(Math.round(sx),0,sw-1),limit(Math.round(sy),0,sh-1));out.set(p,at);continue;}
    const x0=Math.floor(sx),y0=Math.floor(sy),fx=sx-x0,fy=sy-y0,sum=[0,0,0,0];
    for(const [dx,dy,weight] of [[0,0,(1-fx)*(1-fy)],[1,0,fx*(1-fy)],[0,1,(1-fx)*fy],[1,1,fx*fy]]){
      const p=(limit(y0+dy,0,sh-1)*sw+limit(x0+dx,0,sw-1))*4,a=image.data[p+3]/255;
      for(let c=0;c<3;c++)sum[c]+=image.data[p+c]*a*weight;sum[3]+=a*weight;
    }
    for(let c=0;c<3;c++)out[at+c]=sum[3]?sum[c]/sum[3]:0;out[at+3]=sum[3]*255;
  }return {width:w,height:h,data:out};
}
export function filterPixels(image,kind,s={}) {
  if(!FILTERS.includes(kind))throw new Error('invalid');
  const {width:w,height:h,data:src}=image,data=new Uint8ClampedArray(src),amount=s.amount??50,radius=s.radius??4;
  const adjustments=['Gaussian Blur','Motion Blur','Add Noise','Curves','Exposure','Gradient Map','Grain','Black & White','Color Balance','Invert'];
  if(adjustments.includes(kind))return adjustedPixels(image,{...s,kind,blurRadius:s.blurRadius??radius,motionAngle:s.motionAngle??s.angle??0,motionDistance:s.motionDistance??s.distance??10,noiseAmount:s.noiseAmount??amount,noiseSeed:s.noiseSeed??s.seed??0});
  if(kind==='Desaturate')for(let i=0;i<data.length;i+=4)data[i]=data[i+1]=data[i+2]=src[i]*.2126+src[i+1]*.7152+src[i+2]*.0722;
  if(kind==='Mosaic'){
    const size=Math.max(1,Math.round(s.size??16));
    for(let y=0;y<h;y+=size)for(let x=0;x<w;x+=size){let sum=[0,0,0,0],count=0;
      for(let dy=y;dy<Math.min(y+size,h);dy++)for(let dx=x;dx<Math.min(x+size,w);dx++){const i=(dy*w+dx)*4,a=src[i+3]/255;for(let c=0;c<3;c++)sum[c]+=src[i+c]*a;sum[3]+=a;count++;}
      for(let dy=y;dy<Math.min(y+size,h);dy++)for(let dx=x;dx<Math.min(x+size,w);dx++){const i=(dy*w+dx)*4;for(let c=0;c<3;c++)data[i+c]=sum[3]?sum[c]/sum[3]:0;data[i+3]=sum[3]/count*255;}
    }
  }
  if(kind==='Dither'){const bayer=[0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5],levels=limit(Math.round(s.levels??4),2,32);
    for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=(y*w+x)*4,threshold=(bayer[(y%4)*4+x%4]/16-.5)/(levels-1);for(let c=0;c<3;c++)data[i+c]=Math.round(limit(src[i+c]/255+threshold,0,1)*(levels-1))/(levels-1)*255;}}
  if(['Sharpen','Tonal Contrast','Bloom / Glow'].includes(kind)){
    const planes=Array.from({length:3},(_,c)=>Float32Array.from({length:w*h},(_,i)=>kind==='Bloom / Glow'?Math.max(0,src[i*4+c]-(s.threshold??180))*src[i*4+3]/255:src[i*4+c]));
    const blurred=planes.map(p=>blurPlane(p,w,h,radius));
    for(let i=0;i<w*h;i++)for(let c=0;c<3;c++)data[i*4+c]=kind==='Bloom / Glow'?src[i*4+c]+blurred[c][i]*amount/100:src[i*4+c]+(src[i*4+c]-blurred[c][i])*amount/100;
  }
  if(kind==='Vignette')for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=(y*w+x)*4,d=Math.hypot((x-w/2)/Math.max(1,w/2),(y-h/2)/Math.max(1,h/2)),v=limit((d-(s.midpoint??.35))/(1-(s.midpoint??.35)),0,1);for(let c=0;c<3;c++)data[i+c]=src[i+c]*(1-v*v*amount/100);}
  if(kind==='Camera Raw Filter')for(let i=0;i<data.length;i+=4){const gray=src[i]*.2126+src[i+1]*.7152+src[i+2]*.0722;
    for(let c=0;c<3;c++){let value=src[i+c]*2**(s.exposure??0);value=128+(value-128)*(1+(s.contrast??0)/100);value=gray+(value-gray)*(1+(s.saturation??0)/100);value+=(c===0?1:c===2?-1:0)*(s.temperature??0)*.5;data[i+c]=value;}}
  if(kind==='Lens Correction')for(let y=0;y<h;y++)for(let x=0;x<w;x++){const dx=(x-w/2)/(w/2),dy=(y-h/2)/(h/2),scale=1+(s.distortion??0)/100*(dx*dx+dy*dy),p=nearest(src,w,h,w/2+(x-w/2)*scale,h/2+(y-h/2)*scale);data.set(p??[0,0,0,0],(y*w+x)*4);}
  if(kind==='Remove Background'){
    const visited=new Uint8Array(w*h),queue=new Int32Array(w*h);let head=0,tail=0;const tolerance=s.tolerance??28,reference=[0,0,0],samples=[[0,0],[w-1,0],[0,h-1],[w-1,h-1]].map(([x,y])=>(y*w+x)*4);
    for(let c=0;c<3;c++)reference[c]=samples.reduce((n,i)=>n+src[i+c],0)/4;
    const enqueue=i=>{if(!visited[i]){visited[i]=1;queue[tail++]=i;}};for(let x=0;x<w;x++){enqueue(x);enqueue((h-1)*w+x);}for(let y=0;y<h;y++){enqueue(y*w);enqueue(y*w+w-1);}
    while(head<tail){const i=queue[head++],at=i*4;if(src[at+3]&&Math.max(...reference.map((v,c)=>Math.abs(src[at+c]-v)))>tolerance)continue;data[at+3]=0;const x=i%w;for(const n of [x?i-1:-1,x<w-1?i+1:-1,i>=w?i-w:-1,i<w*(h-1)?i+w:-1])if(n>=0)enqueue(n);}
  }
  return {width:w,height:h,data};
}
export function inpaintPixels(image,selection,t) {
  if(!selection)throw new Error('selection');
  const {width:w,height:h}=image,data=new Uint8ClampedArray(image.data),known=new Uint8Array(w*h),queue=new Int32Array(w*h);let head=0,tail=0;
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=y*w+x;if(selectionCoverage(selection,toDocument([x+.5,y+.5],t,w,h))<.5&&data[i*4+3])known[i]=1;}
  const neighbors=i=>{const x=i%w;return [x?i-1:-1,x<w-1?i+1:-1,i>=w?i-w:-1,i<w*(h-1)?i+w:-1].filter(n=>n>=0);};
  for(let i=0;i<w*h;i++)if(!known[i]&&neighbors(i).some(n=>known[n]===1)){known[i]=2;queue[tail++]=i;}
  if(!tail)throw new Error('selection');
  while(head<tail){const i=queue[head++],next=neighbors(i),samples=next.filter(n=>known[n]===1);if(!samples.length)continue;for(let c=0;c<4;c++)data[i*4+c]=samples.reduce((v,n)=>v+data[n*4+c],0)/samples.length;known[i]=1;for(const n of next)if(!known[n]){known[n]=2;queue[tail++]=n;}}
  return {width:w,height:h,data};
}
export function applySelectedFilter(image,t,selection,kind,settings) {
  const changed=kind==='Content-Aware Fill'?inpaintPixels(image,selection,t):filterPixels(image,kind,settings),out=new Uint8ClampedArray(image.data);
  for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++){const a=selectionCoverage(selection,toDocument([x+.5,y+.5],t,image.width,image.height)),at=(y*image.width+x)*4;const before=image.data[at+3]/255,after=changed.data[at+3]/255,alpha=before*(1-a)+after*a;for(let c=0;c<3;c++)out[at+c]=alpha?(image.data[at+c]*before*(1-a)+changed.data[at+c]*after*a)/alpha:0;out[at+3]=alpha*255;}
  return {width:image.width,height:image.height,data:out};
}
