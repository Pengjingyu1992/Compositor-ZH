import { validSurface, limit, toDocument, toLocal } from './editor-math.mjs';
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const known = (value, keys) => object(value) && Object.keys(value).every(key => keys.includes(key));
const finite = (n, low, high) => typeof n === 'number' && Number.isFinite(n) && n >= low && n <= high;
const flag = value => typeof value === 'boolean';
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const point = value => Array.isArray(value) && value.length === 2 && value.every(n => finite(n,-1000,1000));
export const validRGB = value => known(value,['red','green','blue']) && ['red','green','blue'].every(key=>finite(value[key],0,1));
export function supportsFillStyle(value) {
  return known(value,['kind','stops','angle','scale','reversed','pattern','cellSize']) &&
    ['Solid Color','Linear','Radial','Pattern'].includes(value.kind) && Array.isArray(value.stops) && value.stops.length >= 2 && value.stops.length <= 32 &&
    new Set(value.stops.map(stop=>String(stop?.id).toUpperCase())).size === value.stops.length &&
    value.stops.every((stop,index)=>known(stop,['id','position','color']) && uuid.test(stop.id) && finite(stop.position,0,1) && (!index || value.stops[index-1].position <= stop.position) && known(stop.color,['red','green','blue','alpha']) && ['red','green','blue','alpha'].every(key=>finite(stop.color[key],0,1))) &&
    finite(value.angle,-180,180) && finite(value.scale,.01,10) && flag(value.reversed) && ['Checkerboard','Stripes','Dots'].includes(value.pattern) && finite(value.cellSize,4,512);
}
export function supportsVectorPath(value) {
  if(!known(value,['contours','evenOdd','fillEnabled','strokeEnabled','strokeColor','strokeWidth','roundCaps']) || !Array.isArray(value.contours) || !value.contours.length || value.contours.length>10000 || !['evenOdd','fillEnabled','strokeEnabled','roundCaps'].every(key=>flag(value[key])) || !validRGB(value.strokeColor) || !finite(value.strokeWidth,0,5000)) return false;
  let count=0;
  return value.contours.every(contour=>known(contour,['anchors','closed','color']) && flag(contour.closed) && (!contour.color||validRGB(contour.color)) && Array.isArray(contour.anchors) && contour.anchors.length>0 && (count+=contour.anchors.length)<=40000 && contour.anchors.every(anchor=>known(anchor,['point','incoming','outgoing','smooth']) && point(anchor.point) && (anchor.incoming===undefined||point(anchor.incoming)) && (anchor.outgoing===undefined||point(anchor.outgoing)) && (anchor.smooth===undefined||flag(anchor.smooth))));
}
export function defaultFillStyle(id=()=>globalThis.crypto.randomUUID().toUpperCase()) {
  return {kind:'Solid Color',stops:[{id:id(),position:0,color:{red:1,green:.35,blue:.65,alpha:1}},{id:id(),position:1,color:{red:1,green:.9,blue:.6,alpha:1}}],angle:90,scale:1,reversed:false,pattern:'Checkerboard',cellSize:32};
}
export function defaultVectorPath() { return {contours:[{anchors:[],closed:false}],evenOdd:false,fillEnabled:true,strokeEnabled:false,strokeColor:{red:0,green:0,blue:0},strokeWidth:2,roundCaps:false}; }
export function mapVectorPath(vector, source, destination) {
  if(!supportsVectorPath(vector))invalid();
  const result=structuredClone(vector);
  for(const contour of result.contours)for(const anchor of contour.anchors)for(const key of ['point','incoming','outgoing'])if(anchor[key])anchor[key]=toLocal(toDocument(anchor[key],source,1,1),destination,1,1);
  if(!supportsVectorPath(result))invalid();return result;
}
const invalid = () => { const error=new Error('invalid');error.code='invalid';throw error; };
export function fillSampler(width,height,style) {
  validSurface(width,height);if(!supportsFillStyle(style))invalid();
  const cs=Math.cos(style.angle*Math.PI/180),sn=Math.sin(style.angle*Math.PI/180),radius=(Math.abs(cs)*width+Math.abs(sn)*height)*style.scale/2,cell=style.cellSize*style.scale;
  const stops=style.reversed?[...style.stops].reverse().map(stop=>({...stop,position:1-stop.position})):style.stops;
  const blend=(a,b,t)=>{const alpha=a.alpha*(1-t)+b.alpha*t;return {alpha,red:alpha?(a.red*a.alpha*(1-t)+b.red*b.alpha*t)/alpha:0,green:alpha?(a.green*a.alpha*(1-t)+b.green*b.alpha*t)/alpha:0,blue:alpha?(a.blue*a.alpha*(1-t)+b.blue*b.alpha*t)/alpha:0};};
  const gradient=t=>{if(t<stops[0].position)return stops[0].color;let index=0;while(index+1<stops.length&&t>=stops[index+1].position)index++;if(index===stops.length-1)return stops[index].color;return blend(stops[index].color,stops[index+1].color,limit((t-stops[index].position)/(stops[index+1].position-stops[index].position),0,1));};
  return (x,y)=>{
    let color=style.stops[0].color;const dx=x-width/2,dy=y-height/2;
    if(style.kind==='Linear')color=gradient(limit(((dx*cs+dy*sn)/(radius||1)+1)/2,0,1));
    if(style.kind==='Radial')color=gradient(limit(Math.hypot(dx,dy)/(Math.max(width,height)*style.scale/2),0,1));
    if(style.kind==='Pattern'){
      const extent=Math.hypot(width,height),u=((dx*cs+dy*sn+extent)%(2*cell)+2*cell)%(2*cell),v=((-dx*sn+dy*cs+extent)%(2*cell)+2*cell)%(2*cell);
      const first=style.pattern==='Checkerboard'?(u<cell)===(v<cell):style.pattern==='Stripes'?u<cell:Math.hypot(u-cell,v-cell)<=cell/2;
      color=style.stops[first?0:1].color;
    }
    return color;
  };
}
export function renderFillPixels(width,height,style) {
  const sample=fillSampler(width,height,style),data=new Uint8ClampedArray(width*height*4);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){const color=sample(x+.5,y+.5),at=(y*width+x)*4;for(const [index,key]of ['red','green','blue','alpha'].entries())data[at+index]=Math.round(color[key]*255);}
  return {width,height,data};
}
export function vectorPathData(contours,width=1,height=1) {
  return contours.map(contour=>{
    const xy=point=>`${point[0]*width} ${point[1]*height}`,anchors=contour.anchors;let data=`M ${xy(anchors[0].point)}`;
    for(let index=1;index<anchors.length+(contour.closed?1:0);index++){const before=anchors[index-1],after=anchors[index%anchors.length];data+=` C ${xy(before.outgoing??before.point)} ${xy(after.incoming??after.point)} ${xy(after.point)}`;}
    return data+(contour.closed?' Z':'');
  }).join(' ');
}
export function vectorSVG(width,height,vector,color={red:0,green:0,blue:0},mask=false) {
  validSurface(width,height);if(!supportsVectorPath(vector)||!validRGB(color))invalid();
  const rgb=value=>`rgb(${['red','green','blue'].map(key=>Math.round(value[key]*255)).join(',')})`,rule=vector.evenOdd?'evenodd':'nonzero';
  const groups=[];
  for(const contour of vector.contours){const paint=mask?{red:1,green:1,blue:1}:contour.color??color,key=rgb(paint);if(groups.at(-1)?.color===key)groups.at(-1).contours.push(contour);else groups.push({color:key,contours:[contour]});}
  const fills=mask||vector.fillEnabled?groups.map(group=>`<path d="${vectorPathData(group.contours,width,height)}" fill="${group.color}" fill-rule="${rule}"/>`).join(''):'';
  const stroke=!mask&&vector.strokeEnabled?`<path d="${vectorPathData(vector.contours,width,height)}" fill="none" stroke="${rgb(vector.strokeColor)}" stroke-width="${vector.strokeWidth}" stroke-linejoin="round" stroke-linecap="${vector.roundCaps?'round':'butt'}"/>`:'';
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${mask?`<rect width="100%" height="100%" fill="black"/>`:''}${fills}${stroke}</svg>`;
}
