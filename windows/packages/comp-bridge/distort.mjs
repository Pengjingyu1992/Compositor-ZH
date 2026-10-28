import{bounds,union,toLocal,toDocument,validSurface}from'./editor-math.mjs';
import{inverseHomography}from'./camera-raw-geometry.mjs';
const fail=code=>{throw Object.assign(new Error(code),{code});};
const area=(a,b,c)=>(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);
export function usableQuad(c){return Array.isArray(c)&&c.length===4&&c.every(p=>Array.isArray(p)&&p.length===2&&p.every(n=>typeof n==='number'&&Number.isFinite(n)&&Math.abs(n)<=1e6))&&Math.abs(area(c[0],c[1],c[2]))>.01&&Math.abs(area(c[0],c[2],c[3]))>.01;}
export function convexQuad(c){if(!usableQuad(c))return false;const signs=c.map((_,i)=>area(c[i],c[(i+1)%4],c[(i+2)%4]));return signs.every(n=>n>.01)||signs.every(n=>n<-.01);}
export function quadBounds(c){if(!usableQuad(c))fail('invalid');const x=Math.floor(Math.min(...c.map(p=>p[0]))),y=Math.floor(Math.min(...c.map(p=>p[1]))),width=Math.ceil(Math.max(...c.map(p=>p[0])))-x,height=Math.ceil(Math.max(...c.map(p=>p[1])))-y;validSurface(width,height);return{x,y,width,height};}
export function transformCorners(t){const plain={...t,flipX:false,flipY:false};return[[0,0],[1,0],[1,1],[0,1]].map(p=>toDocument(p,plain,1,1));}
function homography(c){
 const sx=c[0][0]-c[1][0]+c[2][0]-c[3][0],sy=c[0][1]-c[1][1]+c[2][1]-c[3][1];let g=0,h=0;
 if(Math.abs(sx)>1e-9||Math.abs(sy)>1e-9){const dx1=c[1][0]-c[2][0],dx2=c[3][0]-c[2][0],dy1=c[1][1]-c[2][1],dy2=c[3][1]-c[2][1],den=dx1*dy2-dx2*dy1;if(Math.abs(den)>1e-12){g=(sx*dy2-dx2*sy)/den;h=(dx1*sy-sx*dy1)/den;}}
 return p=>{const w=g*p[0]+h*p[1]+1;return[((c[1][0]-c[0][0]+g*c[1][0])*p[0]+(c[3][0]-c[0][0]+h*c[3][0])*p[1]+c[0][0])/w,((c[1][1]-c[0][1]+g*c[1][1])*p[0]+(c[3][1]-c[0][1]+h*c[3][1])*p[1]+c[0][1])/w];};
}
export function carriedCorners(placement,box,corners){const map=homography(corners),plain={...box,flipX:false,flipY:false};return transformCorners(placement).map(p=>map(toLocal(p,plain,1,1)));}
// The same target plan drives the preview and the authoritative edit. Groups
// expand once, including hidden children; a single layer keeps its rotated box.
export function distortionPlan(rows,ids,target='content'){
 if(!['content','mask'].includes(target)||!Array.isArray(ids)||!ids.length||ids.length>10000||ids.some(id=>typeof id!=='string'||!rows.some(row=>row.id===id)))fail('stale');
 const selected=new Set(ids.map(id=>id.toUpperCase()));
 if(target==='mask'){if(ids.length!==1)fail('unsupported');const row=rows.find(row=>row.id===ids[0]);if(!row.maskFile)fail('unsupported');return{box:row.maskPlacement??row.transform,rows:[row],target};}
 for(let depth=0;depth<64;depth++)for(const row of rows)if(selected.has(row.parentID?.toUpperCase()))selected.add(row.id.toUpperCase());
 const layers=rows.filter(row=>selected.has(row.id.toUpperCase())),images=layers.filter(row=>row.imageFile);if(!images.length)fail('unsupported');
 const rect=union(images.map(row=>bounds(row.transform))),box=ids.length===1&&layers.length===1?images[0].transform:{origin:[rect.x,rect.y],size:[rect.w,rect.h],rotation:0,flipX:false,flipY:false,sampling:'High quality'};
 return{box,rows:layers,target};
}
function pixel(image,x,y,nearest,mask){
 if(nearest){const sx=Math.max(0,Math.min(image.width-1,Math.floor(x))),sy=Math.max(0,Math.min(image.height-1,Math.floor(y))),at=(sy*image.width+sx)*4;return mask?[image.data[at],image.data[at],image.data[at],255]:Array.from(image.data.subarray(at,at+4));}
 x-=.5;y-=.5;const ix=Math.floor(x),iy=Math.floor(y),fx=x-ix,fy=y-iy,sums=[0,0,0,0];
 for(let row=0;row<2;row++)for(let col=0;col<2;col++){const sx=Math.max(0,Math.min(image.width-1,ix+col)),sy=Math.max(0,Math.min(image.height-1,iy+row)),weight=(col?fx:1-fx)*(row?fy:1-fy),at=(sy*image.width+sx)*4,a=mask?255:image.data[at+3];sums[3]+=a*weight;for(let c=0;c<3;c++)sums[c]+=image.data[at+c]*a*weight;}
 return[sums[3]?Math.round(sums[0]/sums[3]):0,sums[3]?Math.round(sums[1]/sums[3]):0,sums[3]?Math.round(sums[2]/sums[3]):0,Math.round(sums[3])];
}
function trianglePoint(p,a,b,c){const det=area(a,b,c),u=area(a,p,c)/det,v=area(a,b,p)/det;return u>=-1e-10&&v>=-1e-10&&u+v<=1+1e-10?[u,v]:undefined;}
function over(data,at,rgba){const a=rgba[3]/255,b=data[at+3]/255,alpha=a+b*(1-a);for(let c=0;c<3;c++)data[at+c]=alpha?Math.round((rgba[c]*a+data[at+c]*b*(1-a))/alpha):0;data[at+3]=Math.round(alpha*255);}
export function warpQuad(image,transform,corners,{mask=false,background=0,limit}={}){
 const rect=quadBounds(corners),placed={origin:[rect.x,rect.y],size:[rect.width,rect.height],rotation:0,flipX:false,flipY:false,sampling:transform.sampling};
 validSurface(image.width,image.height);if(image.data?.length!==image.width*image.height*4)fail('invalid');
 if(mask&&image.width===1&&image.height===1)return{image,transform:placed};
 if(limit!==undefined&&(!Number.isFinite(limit)||limit<1||limit>4096))fail('invalid');
 const factor=limit?Math.min(1,limit/Math.max(rect.width,rect.height)):1,width=Math.max(1,Math.ceil(rect.width*factor)),height=Math.max(1,Math.ceil(rect.height*factor)),data=new Uint8ClampedArray(width*height*4),convex=convexQuad(corners),nearest=transform.sampling==='Nearest';
 if(mask)for(let i=0;i<width*height;i++){data[i*4]=data[i*4+1]=data[i*4+2]=background;data[i*4+3]=255;}
 // Translation before solving avoids loss of precision for far-away layers.
 const local=corners.map(p=>[p[0]-rect.x,p[1]-rect.y]),matrix=convex?inverseHomography(local,[[0,0],[1,0],[1,1],[0,1]]):undefined,folded=[[0,0],[1,0],[1,1],[0,1]].map(([u,v])=>local[[0,1,3,2][(transform.flipY?1-v:v)*2+(transform.flipX?1-u:u)]]);
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
  const p=[(x+.5)*rect.width/width,(y+.5)*rect.height/height],at=(y*width+x)*4,coordinates=[];
  if(matrix){const den=matrix[6]*p[0]+matrix[7]*p[1]+1;if(Math.abs(den)<1e-12)continue;const u=(matrix[0]*p[0]+matrix[1]*p[1]+matrix[2])/den,v=(matrix[3]*p[0]+matrix[4]*p[1]+matrix[5])/den;if(u>=-1e-10&&u<=1+1e-10&&v>=-1e-10&&v<=1+1e-10)coordinates.push([u,v]);}
  else{const first=trianglePoint(p,folded[0],folded[1],folded[2]),second=trianglePoint(p,folded[0],folded[2],folded[3]);if(first)coordinates.push([first[0]+first[1],first[1]]);if(second&&!(first&&Math.abs(second[1])<1e-10))coordinates.push([second[0],second[0]+second[1]]);}
  for(let[u,v]of coordinates){if(convex&&transform.flipX)u=1-u;if(convex&&transform.flipY)v=1-v;const rgba=pixel(image,u*image.width,v*image.height,nearest,mask);if(mask)data.set(rgba,at);else over(data,at,rgba);}
 }
 return{image:{width,height,data},transform:placed};
}
export function trimWarp(warp){
 const{image}=warp;let left=image.width,top=image.height,right=0,bottom=0;
 for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++)if(image.data[(y*image.width+x)*4+3]){left=Math.min(left,x);top=Math.min(top,y);right=Math.max(right,x+1);bottom=Math.max(bottom,y+1);}
 if(right<=left||bottom<=top){left=top=0;right=image.width;bottom=image.height;}
 const crop={x:left,y:top,width:right-left,height:bottom-top};return{image:cropWarp(image,crop),transform:{...warp.transform,origin:[warp.transform.origin[0]+left,warp.transform.origin[1]+top],size:[crop.width,crop.height]},crop};
}
export function cropWarp(image,crop){
 if(crop.x===0&&crop.y===0&&crop.width===image.width&&crop.height===image.height)return image;
 const data=new Uint8ClampedArray(crop.width*crop.height*4);for(let y=0;y<crop.height;y++)data.set(image.data.subarray(((y+crop.y)*image.width+crop.x)*4,((y+crop.y)*image.width+crop.x+crop.width)*4),y*crop.width*4);return{width:crop.width,height:crop.height,data};
}
export function maskBackground(image){let total=0,count=0;for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++)if(!x||!y||x===image.width-1||y===image.height-1){total+=image.data[(y*image.width+x)*4];count++;}return total>=count*127.5?255:0;}
export function distortLayer(original,box,corners,{image,mask},target='content',limit){
 const row=structuredClone(original),result={row,image:undefined,mask:undefined};
 if(target==='mask'){
  const moved=warpQuad(mask,box,corners,{mask:true,background:maskBackground(mask),limit});result.mask=moved.image;row.maskPlacement=moved.transform;row.maskLinked=false;delete row.vectorMask;return result;
 }
 const shape=box===original.transform?corners:carriedCorners(original.transform,box,corners);
 // A single rotated box also passes through this map without changing its
 // corner ordering. Flips affect the pixels, never the handle order.
 if(image){
  const full=warpQuad(image,original.transform,shape,{limit}),warped=limit?full:trimWarp(full);result.image=warped.image;row.transform=warped.transform;delete row.text;delete row.shape;delete row.fill;delete row.editableFilters;
  if(mask&&original.maskLinked!==false&&!original.maskPlacement){const moved=warpQuad(mask,original.transform,shape,{mask:true,limit});result.mask=moved.image.width===1&&moved.image.height===1||limit?moved.image:cropWarp(moved.image,warped.crop);delete row.vectorMask;}
 }
 if(mask&&(original.maskPlacement||!image||original.maskLinked===false)){
  const placement=original.maskPlacement??original.transform,carried=original.maskLinked!==false?carriedCorners(placement,box,corners):undefined;
  if(carried&&convexQuad(carried)){const moved=warpQuad(mask,placement,carried,{mask:true,background:maskBackground(mask),limit});result.mask=moved.image;row.maskPlacement=moved.transform;delete row.vectorMask;}
  else row.maskPlacement=structuredClone(placement);
 }
 return result;
}
