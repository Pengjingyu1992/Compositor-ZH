import { validSurface, limit } from './editor-math.mjs';
import { decodeBinary as binaryBytes } from './binary.mjs';
export const LIQUIFY_TOOLS=['Forward Warp','Twirl','Pinch','Bloat','Reconstruct','Freeze','Thaw'];
const fail=()=>{const error=new Error('invalid');error.code='invalid';throw error;};
const finite=(v,a,b)=>typeof v==='number'&&Number.isFinite(v)&&v>=a&&v<=b;
export function validateSavedLiquify(value,width,height) {
  validSurface(width,height);
  const step=Math.max(1,Math.ceil(Math.max(width,height)/1536)),gw=Math.ceil((width-1)/step)+1,gh=Math.ceil((height-1)/step)+1;
  if(!value||Object.keys(value).some(k=>!['width','height','step','gridWidth','gridHeight','field','coverage','keepsAlpha','diameter','hardness','strength','rate','fixedEdges','usesPressure','reversesDirection','tool'].includes(k))||value.width!==width||value.height!==height||value.step!==step||value.gridWidth!==gw||value.gridHeight!==gh||!finite(value.diameter,2,3000)||!finite(value.hardness,0,1)||!finite(value.strength,.01,1)||!finite(value.rate,.1,3)||!LIQUIFY_TOOLS.includes(value.tool)||!['keepsAlpha','fixedEdges','usesPressure','reversesDirection'].every(k=>typeof value[k]==='boolean'))fail();
  const bytes=binaryBytes(value.field,gw*gh*12),view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),field=new Float32Array(gw*gh*3);
  for(let i=0;i<field.length;i++){const number=view.getFloat32(i*4,true);if(!finite(number,i%3===2?0:-120000,i%3===2?1:120000))fail();field[i]=number;}
  return {field,coverage:value.coverage!=null?binaryBytes(value.coverage,width*height):undefined};
}
export function newLiquify(width,height) {
  validSurface(width,height);const step=Math.max(1,Math.ceil(Math.max(width,height)/1536));
  return {width,height,step,gridWidth:Math.ceil((width-1)/step)+1,gridHeight:Math.ceil((height-1)/step)+1,keepsAlpha:false,diameter:180,hardness:.3,strength:.6,rate:1,fixedEdges:true,usesPressure:true,reversesDirection:false,tool:'Forward Warp'};
}
export function sampleField(field,width,height,x,y) {
  x=limit(x,0,width-1);y=limit(y,0,height-1);const a=Math.floor(x),b=Math.floor(y),c=Math.min(width-1,a+1),d=Math.min(height-1,b+1),fx=x-a,fy=y-b;
  return [0,1,2].map(k=>(field[(b*width+a)*3+k]*(1-fx)+field[(b*width+c)*3+k]*fx)*(1-fy)+(field[(d*width+a)*3+k]*(1-fx)+field[(d*width+c)*3+k]*fx)*fy);
}
export function liquifyDab(field,settings,cx,cy,mx=0,my=0,pressure=1) {
  const {gridWidth:gw,gridHeight:gh,width,height,step}=settings,old=new Float32Array(field),radius=settings.diameter/2,amount=settings.strength*settings.rate*(settings.usesPressure?limit(pressure,0,1):1)*(settings.reversesDirection&&['Twirl','Pinch','Bloat'].includes(settings.tool)?-1:1),tool=settings.tool;
  if(![cx,cy,mx,my,pressure].every(Number.isFinite)||!LIQUIFY_TOOLS.includes(tool))fail();
  for(let y=Math.max(0,Math.floor((cy-radius)/step));y<=Math.min(gh-1,Math.ceil((cy+radius)/step));y++)for(let x=Math.max(0,Math.floor((cx-radius)/step));x<=Math.min(gw-1,Math.ceil((cx+radius)/step));x++){
    const px=Math.min(width-1,x*step),py=Math.min(height-1,y*step),dx=px-cx,dy=py-cy,u=Math.hypot(dx,dy)/radius;if(u>=1)continue;let w=u<=settings.hardness?1:limit((1-u)/(1-settings.hardness),0,1);w=w*w*(3-2*w);const i=(y*gw+x)*3;
    if(tool==='Freeze'||tool==='Thaw'){const f=limit(w*amount,0,1);field[i+2]=tool==='Freeze'?old[i+2]+(1-old[i+2])*f:old[i+2]*(1-f);continue;}
    w*=1-old[i+2];if(settings.fixedEdges)w*=limit(Math.min(px,py,width-1-px,height-1-py)/radius,0,1);if(w<=0)continue;const k=w*amount;let sx=px,sy=py;
    if(tool==='Reconstruct'){field[i]=old[i]*(1-k)||0;field[i+1]=old[i+1]*(1-k)||0;continue;}
    if(tool==='Forward Warp'){sx-=mx*k;sy-=my*k;}
    if(tool==='Twirl'){const c=Math.cos(-k),s=Math.sin(-k);sx=cx+c*dx-s*dy;sy=cy+s*dx+c*dy;}
    if(tool==='Pinch'||tool==='Bloat'){const scale=Math.exp((tool==='Pinch'?1:-1)*k);sx=cx+dx*scale;sy=cy+dy*scale;}
    const offset=sampleField(old,gw,gh,sx/step,sy/step);field[i]=limit(sx-px+offset[0],-width,width);field[i+1]=limit(sy-py+offset[1],-height,height);
  }
  return field;
}
export function renderLiquify(image,settings,longEdge) {
  const {width:w,height:h}=image,{field,coverage}=validateSavedLiquify(settings,w,h),scale=longEdge?Math.min(1,longEdge/Math.max(w,h)):1,ow=Math.max(1,Math.round(w*scale)),oh=Math.max(1,Math.round(h*scale)),data=new Uint8ClampedArray(ow*oh*4),src=image.data;
  for(let y=0;y<oh;y++)for(let x=0;x<ow;x++){
    const px=(x+.5)*w/ow-.5,py=(y+.5)*h/oh-.5,at=(Math.round(py)*w+Math.round(px))*4,out=(y*ow+x)*4,d=sampleField(field,settings.gridWidth,settings.gridHeight,px/settings.step,py/settings.step),sx=limit(px+d[0],0,w-1),sy=limit(py+d[1],0,h-1),ix=Math.floor(sx),iy=Math.floor(sy),jx=Math.min(w-1,ix+1),jy=Math.min(h-1,iy+1),fx=sx-ix,fy=sy-iy,weight=coverage?coverage[at/4]/255:1;
    const locations=[(iy*w+ix)*4,(iy*w+jx)*4,(jy*w+ix)*4,(jy*w+jx)*4],weights=[(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy];
    const alpha=locations.reduce((sum,p,i)=>sum+src[p+3]*weights[i],0),outAlpha=alpha*weight+src[at+3]*(1-weight);
    for(let c=0;c<3;c++){const color=locations.reduce((sum,p,i)=>sum+src[p+c]*src[p+3]*weights[i],0)*weight+src[at+c]*src[at+3]*(1-weight);data[out+c]=outAlpha?Math.round(color/outAlpha):src[at+c];}
    data[out+3]=settings.keepsAlpha?src[at+3]:Math.round(outAlpha);
  }
  return {width:ow,height:oh,data};
}
