import{distortLayer,distortionPlan}from'../../../packages/comp-bridge/distort.mjs';
let rows:any[]=[],ids:string[]=[],target='content',assets:Record<string,any>={};
self.onmessage=event=>{try{const m=event.data;if(m.action==='init'){rows=m.rows;ids=m.ids;target=m.target;assets=m.assets;self.postMessage({ready:true});return;}
 const plan=distortionPlan(rows,ids,target),result=plan.rows.map((row:any)=>distortLayer(row,plan.box,m.corners,{image:target==='content'?assets[row.imageFile]:undefined,mask:assets[row.maskFile]},target,768));
 self.postMessage({result},{transfer:result.flatMap((item:any)=>[item.image?.data.buffer,item.mask?.data.buffer].filter(Boolean))});
}catch(error){self.postMessage({error:(error as any).code??'invalid'});}};
