import { newLiquify, validateSavedLiquify, liquifyDab, renderLiquify, sampleField } from '../../../packages/comp-bridge/liquify.mjs';
import { encodeBinary } from '../../../packages/comp-bridge/binary.mjs';
let showsFrozen=true;
let source:any,settings:any,field:Float32Array,past:Float32Array[]=[],future:Float32Array[]=[],before:Float32Array|undefined,last:number[]|undefined;
function trim(){while(past.length>1&&past.length*field.byteLength>64*1024**2)past.shift();}
function saved(){return {...settings,field:encodeBinary(new Uint8Array(field.buffer))};}
function preview(){const image=renderLiquify(source,saved(),800);if(showsFrozen)for(let y=0;y<image.height;y++)for(let x=0;x<image.width;x++){const frozen=sampleField(field,settings.gridWidth,settings.gridHeight,(x+.5)*settings.width/image.width/settings.step,(y+.5)*settings.height/image.height/settings.step)[2],at=(y*image.width+x)*4,a=frozen*110/255,old=image.data[at+3]/255,alpha=a+old*(1-a);if(alpha){image.data[at]=(255*a+image.data[at]*old*(1-a))/alpha;image.data[at+1]=image.data[at+1]*old*(1-a)/alpha;image.data[at+2]=image.data[at+2]*old*(1-a)/alpha;image.data[at+3]=alpha*255;}}self.postMessage({image,canUndo:past.length>0,canRedo:future.length>0},{transfer:[image.data.buffer]});}
self.onmessage=event=>{
  try{const message=event.data;
    if(message.action==='init'){source=message.source;settings=message.saved??newLiquify(source.width,source.height);field=message.saved?validateSavedLiquify(message.saved,source.width,source.height).field:new Float32Array(settings.gridWidth*settings.gridHeight*3);preview();}
    else if(message.action==='stroke'){
      Object.assign(settings,message.settings);if(!before){before=new Float32Array(field);last=undefined;}
      const point=message.point,dx=last?point[0]-last[0]:0,dy=last?point[1]-last[1]:0,steps=Math.max(1,Math.min(128,Math.ceil(Math.hypot(dx,dy)/Math.max(1,settings.diameter*.15))));
      for(let i=1;i<=steps;i++)liquifyDab(field,settings,point[0]-dx*(1-i/steps),point[1]-dy*(1-i/steps),dx/steps,dy/steps,point[2]);last=point;preview();
    }else if(message.action==='end'){if(before){past.push(before);future=[];before=undefined;last=undefined;trim();}preview();}
    else if(message.action==='undo'&&past.length){future.push(field);field=past.pop()!;preview();}
    else if(message.action==='redo'&&future.length){past.push(field);field=future.pop()!;trim();preview();}
    else if(message.action==='reset'){past.push(new Float32Array(field));future=[];for(let i=0;i<field.length;i++)if(i%3!==2)field[i]=0;trim();preview();}
    else if(message.action==='overlay'){showsFrozen=message.show===true;preview();}
    else if(message.action==='save'){Object.assign(settings,message.settings);self.postMessage({saved:saved()});}
  }catch(error){self.postMessage({error:(error as any).code??'invalid'});}
};
