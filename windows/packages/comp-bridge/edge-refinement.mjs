import{toDocument,toLocal,selectionCoverage}from'./editor-math.mjs';
import{encodeBinary,decodeBinary}from'./binary.mjs';
const f=Math.fround,clamp=(v,a=0,b=1)=>Math.max(a,Math.min(b,v));
const fail=(code='invalid')=>{const error=new Error(code);error.code=code;throw error;};
export const EDGE_LIMIT=1536;
export function edgeSize(width,height){if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>30000||height>30000||width*height>16_000_000)fail('limit');const scale=Math.min(1,EDGE_LIMIT/Math.max(width,height));return{width:Math.max(1,Math.floor(width*scale)),height:Math.max(1,Math.floor(height*scale))};}
export function validateEdgeSettings(value){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(key=>!['feather','shift','contrast','decontaminate','copy'].includes(key))||typeof value.copy!=='boolean')fail();
  for(const[key,minimum]of [['feather',0],['shift',-100],['contrast',0],['decontaminate',0]])if(typeof value[key]!=='number'||!Number.isFinite(value[key])||value[key]<minimum||value[key]>100)fail();return value;
}
export function readEdgeLevels(record,sourceWidth,sourceHeight){
  const size=edgeSize(sourceWidth,sourceHeight);if(!record||record.version!==1||record.width!==size.width||record.height!==size.height||Object.keys(record).some(key=>!['version','width','height','levels'].includes(key)))fail();
  const bytes=decodeBinary(record.levels,size.width*size.height*4),levels=new Float32Array(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength));if(levels.some(value=>!Number.isFinite(value)||value<0||value>1))fail();return levels;
}
export function saveEdgeLevels(levels,width,height){return{version:1,width,height,levels:encodeBinary(new Uint8Array(levels.buffer,levels.byteOffset,levels.byteLength))};}
// Native GuidedMatte uses Float for every running sum and intermediate value.
export function edgeBox(source,width,height,radius){
  const span=f(radius*2+1),pass=new Float32Array(source.length),result=new Float32Array(source.length);
  for(let y=0;y<height;y++){const row=y*width;let sum=0;for(let x=-radius;x<=radius;x++)sum=f(sum+source[row+clamp(x,0,width-1)]);for(let x=0;x<width;x++){pass[row+x]=f(sum/span);sum=f(sum-source[row+clamp(x-radius,0,width-1)]);sum=f(sum+source[row+clamp(x+radius+1,0,width-1)]);}}
  for(let x=0;x<width;x++){let sum=0;for(let y=-radius;y<=radius;y++)sum=f(sum+pass[clamp(y,0,height-1)*width+x]);for(let y=0;y<height;y++){result[y*width+x]=f(sum/span);sum=f(sum-pass[clamp(y-radius,0,height-1)*width+x]);sum=f(sum+pass[clamp(y+radius+1,0,height-1)*width+x]);}}return result;
}
export function guidedEdge(mask,guide,width,height,radius=8,epsilon=.001){
  const mg=edgeBox(guide,width,height,radius),mm=edgeBox(mask,width,height,radius),squares=Float32Array.from(guide,value=>f(value*value)),products=Float32Array.from(guide,(value,index)=>f(value*mask[index])),ms=edgeBox(squares,width,height,radius),mp=edgeBox(products,width,height,radius),slope=new Float32Array(mask.length),offset=new Float32Array(mask.length);
  for(let i=0;i<mask.length;i++){const variance=f(ms[i]-f(mg[i]*mg[i])),covariance=f(mp[i]-f(mg[i]*mm[i]));slope[i]=f(covariance/f(variance+f(epsilon)));offset[i]=f(mm[i]-f(slope[i]*mg[i]));}
  const a=edgeBox(slope,width,height,radius),b=edgeBox(offset,width,height,radius);return Float32Array.from(mask,(_,i)=>clamp(f(f(a[i]*guide[i])+b[i])));
}
export function edgeGuide(image){return Float32Array.from({length:image.width*image.height},(_,i)=>{const at=i*4,a=image.data[at+3];if(!a)return 0;const channel=c=>Math.round(image.data[at+c]*a/255);return f(f(f(f(channel(0)*f(.2126))+f(channel(1)*f(.7152)))+f(channel(2)*f(.0722)))/a);});}
function bilinear(values,width,height,x,y,outside){
  if(outside!==undefined&&(x<-.5||y<-.5||x>=width-.5||y>=height-.5))return outside;
  const xx=clamp(x,0,width-1),yy=clamp(y,0,height-1),left=Math.floor(xx),top=Math.floor(yy),fx=xx-left,fy=yy-top;
  return(values[top*width+left]*(1-fx)+values[top*width+Math.min(width-1,left+1)]*fx)*(1-fy)+(values[Math.min(height-1,top+1)*width+left]*(1-fx)+values[Math.min(height-1,top+1)*width+Math.min(width-1,left+1)]*fx)*fy;
}
export function initialEdgeLevels(sourceWidth,sourceHeight,layer,mask,selection){
  const{width,height}=edgeSize(sourceWidth,sourceHeight),result=new Float32Array(width*height);
  if(mask&&layer.maskEnabled!==false){
    const values=Float32Array.from({length:mask.width*mask.height},(_,i)=>mask.data[i*4]/255);let background=0,count=0;
    for(let y=0;y<mask.height;y++)for(let x=0;x<mask.width;x++)if(!x||!y||x===mask.width-1||y===mask.height-1){background+=values[y*mask.width+x];count++;}background=background*2>=count?1:0;
    for(let y=0;y<height;y++)for(let x=0;x<width;x++){if(mask.width===1&&mask.height===1){result[y*width+x]=values[0];continue;}const point=layer.maskPlacement?toLocal(toDocument([x+.5,y+.5],layer.transform,width,height),layer.maskPlacement,mask.width,mask.height):[(x+.5)*mask.width/width,(y+.5)*mask.height/height];result[y*width+x]=f(bilinear(values,mask.width,mask.height,point[0]-.5,point[1]-.5,layer.maskPlacement?background:undefined));}
  }else if(selection){for(let y=0;y<height;y++)for(let x=0;x<width;x++)result[y*width+x]=f(selectionCoverage(selection,toDocument([x+.5,y+.5],layer.transform,width,height)));}
  else result.fill(1);return{width,height,levels:result};
}
export function edgeBrush(levels,width,height,from,to,{diameter,strength,mode,sourceWidth},guided){
  if(levels.length!==width*height||!Number.isFinite(sourceWidth)||sourceWidth<1||!Array.isArray(to)||to.length!==2||from&&(!Array.isArray(from)||from.length!==2||from.some(value=>!Number.isFinite(value)))||!['refine','reveal','hide'].includes(mode)||!Number.isFinite(diameter)||diameter<2||diameter>1000||!Number.isFinite(strength)||strength<0||strength>1||to.some(value=>!Number.isFinite(value)||Math.abs(value)>40000)||mode==='refine'&&guided?.length!==levels.length)fail();
  const radius=Math.max(1,diameter/2*width/sourceWidth),old=from??to,steps=Math.max(1,Math.ceil(Math.hypot(to[0]-old[0],to[1]-old[1])/Math.max(1,radius/3)));
  for(let step=1;step<=Math.min(steps,1000);step++){const t=step/steps,cx=old[0]+(to[0]-old[0])*t,cy=old[1]+(to[1]-old[1])*t;
    for(let y=Math.max(0,Math.floor(cy-radius));y<=Math.min(height-1,Math.ceil(cy+radius));y++)for(let x=Math.max(0,Math.floor(cx-radius));x<=Math.min(width-1,Math.ceil(cx+radius));x++){const distance=Math.hypot(x+.5-cx,y+.5-cy)/radius;if(distance>=1)continue;const i=y*width+x,amount=f((1-distance)*strength),target=mode==='refine'?guided[i]:mode==='reveal'?1:0;levels[i]=clamp(f(levels[i]+f(f(target-levels[i])*amount)));}}
}
function diskMorph(source,width,height,radius,maximum){
  if(!radius)return source;const result=new Float32Array(source.length);if(!maximum)result.fill(255);const queue=new Int32Array(width+radius*2+1);
  for(let dy=-radius;dy<=radius;dy++){const span=Math.floor(Math.sqrt(radius*radius-dy*dy));
    for(let y=0;y<height;y++){const row=(y+dy)*width,output=y*width;if(y+dy<0||y+dy>=height){if(!maximum)result.fill(0,output,output+width);continue;}let head=0,tail=0;
      const value=x=>x<0||x>=width?0:source[row+x];for(let x=-span;x<width+span;x++){const v=value(x);while(tail>head&&(maximum?value(queue[tail-1])<=v:value(queue[tail-1])>=v))tail--;queue[tail++]=x;while(queue[head]<x-2*span)head++;if(x>=span){const at=output+x-span;result[at]=maximum?Math.max(result[at],value(queue[head])):Math.min(result[at],value(queue[head]));}}}}
  return result;
}
function gaussian(source,width,height,sigma){
  if(sigma<=.01)return source;
  if(sigma>8){const ideal=Math.sqrt(4*sigma*sigma+1);let low=Math.max(1,Math.floor(ideal));if(!(low%2))low--;const high=low+2,n=clamp(Math.round((12*sigma*sigma-3*low*low-12*low-9)/(-4*low-4)),0,3);let output=source;for(let i=0;i<3;i++)output=edgeBox(output,width,height,Math.max(0,((i<n?low:high)-1)/2));return output;}
  const radius=Math.ceil(sigma*3),kernel=Float64Array.from({length:2*radius+1},(_,i)=>Math.exp(-((i-radius)**2)/(2*sigma*sigma))),sum=kernel.reduce((a,b)=>a+b,0);for(let i=0;i<kernel.length;i++)kernel[i]/=sum;
  const pass=new Float32Array(source.length),output=new Float32Array(source.length);for(let y=0;y<height;y++)for(let x=0;x<width;x++){let value=0;for(let dx=-radius;dx<=radius;dx++)value+=source[y*width+clamp(x+dx,0,width-1)]*kernel[dx+radius];pass[y*width+x]=value;}
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){let value=0;for(let dy=-radius;dy<=radius;dy++)value+=pass[clamp(y+dy,0,height-1)*width+x]*kernel[dy+radius];output[y*width+x]=value;}return output;
}
export function renderEdgeMask(levels,width,height,settings,sourceWidth){
  validateEdgeSettings(settings);if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>EDGE_LIMIT||height>EDGE_LIMIT||levels.length!==width*height||levels.some(value=>!Number.isFinite(value)||value<0||value>1)||!Number.isFinite(sourceWidth)||sourceWidth<1)fail();const scale=width/sourceWidth,shift=settings.shift*scale;let values=Float32Array.from(levels,value=>Math.round(clamp(value)*255));
  if(Math.abs(shift)>.01){const radius=Math.min(100,Math.abs(shift)),low=Math.floor(radius),fraction=radius-low,a=diskMorph(values,width,height,low,shift>0);if(fraction){const b=diskMorph(values,width,height,low+1,shift>0);values=Float32Array.from(a,(value,i)=>value*(1-fraction)+b[i]*fraction);}else values=a;}
  values=gaussian(values,width,height,Math.min(100,settings.feather*scale)/2);return Uint8Array.from(values,value=>Math.round(clamp((value/255-.5)*(1+settings.contrast/25)+.5)*255));
}
export function resizeEdgeMask(mask,width,height,targetWidth,targetHeight){return Uint8Array.from({length:targetWidth*targetHeight},(_,i)=>Math.round(clamp(bilinear(mask,width,height,(i%targetWidth+.5)*width/targetWidth-.5,(Math.floor(i/targetWidth)+.5)*height/targetHeight-.5),0,255)));}
const directions=[[-1,0],[1,0],[0,-1],[0,1],[-1,-1],[1,1],[-1,1],[1,-1]];
export function decontaminateEdges(image,mask,amount){
  if(!Number.isFinite(amount)||amount<0||amount>1||mask.length!==image.width*image.height)fail();if(!amount)return image;const{width,height,data}=image,output=new Uint8ClampedArray(data);for(let at=0;at<data.length;at+=4){const alpha=data[at+3];for(let c=0;c<3;c++)output[at+c]=alpha?Math.round(Math.round(data[at+c]*alpha/255)*255/alpha):0;}
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){const index=y*width+x,coverage=f(mask[index]/255),at=index*4,alpha=data[at+3];if(coverage<=.01||coverage>=.98||!alpha)continue;let done=false;
    for(const radius of [1,2,4,8,16]){for(const[dx,dy]of directions){const nx=x+dx*radius,ny=y+dy*radius;if(nx<0||ny<0||nx>=width||ny>=height)continue;const neighbor=(ny*width+nx)*4,a=data[neighbor+3];if(mask[ny*width+nx]/255<=.98||!a)continue;const blend=amount*f(1-coverage);for(let c=0;c<3;c++){const retained=Math.round(data[at+c]*alpha/255)*(1-blend),near=Math.round(data[neighbor+c]*a/255)/a*alpha*blend,premultiplied=clamp(Math.round(retained+near),0,alpha);output[at+c]=Math.round(premultiplied*255/alpha);}done=true;break;}if(done)break;}}
  return{width,height,data:output};
}
export function edgePreview(image,levels,settings,sourceWidth,maskOnly=false){const mask=renderEdgeMask(levels,image.width,image.height,settings,sourceWidth),cleaned=decontaminateEdges(image,mask,settings.decontaminate/100),data=new Uint8ClampedArray(image.data.length);for(let i=0;i<mask.length;i++){const at=i*4;if(maskOnly){data[at]=data[at+1]=data[at+2]=mask[i];data[at+3]=255;}else{data.set(cleaned.data.subarray(at,at+4),at);data[at+3]=Math.round(data[at+3]*mask[i]/255);}}return{width:image.width,height:image.height,data};}
