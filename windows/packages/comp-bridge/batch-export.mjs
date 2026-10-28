const invalid=()=>Object.assign(new Error('invalid'),{code:'invalid'});
export function batchOptions(value,width,height){
  if(!value||!['png','jpeg'].includes(value.format)||!Array.isArray(value.longSides)||!value.longSides.length||value.longSides.length>20||new Set(value.longSides).size!==value.longSides.length||value.longSides.some(side=>!Number.isInteger(side)||side<0||side>30000)||!Number.isInteger(value.quality)||value.quality<1||value.quality>100||typeof value.prefix!=='string'||value.prefix.length>120||typeof value.individualLayers!=='boolean')throw invalid();
  const dimensions=[],seen=new Set();for(const side of value.longSides){const scale=side?side/Math.max(width,height):1,w=Math.max(1,Math.round(width*scale)),h=Math.max(1,Math.round(height*scale)),key=w+'x'+h;if(w*h>16_000_000)throw Object.assign(new Error('limit'),{code:'limit'});if(!seen.has(key)){seen.add(key);dimensions.push({side,width:w,height:h,key});}}
  return{format:value.format,longSides:[...value.longSides],quality:value.quality,prefix:value.prefix,individualLayers:value.individualLayers,dimensions};
}
export function batchSafeName(value){const name=String(value).replace(/[<>:"/\\|?*\x00-\x1f\x7f]/g,'_').slice(0,120).trim().replace(/[. ]+$/,'');return !name||/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)?'Export-'+name:name;}
export function isolateBatchRows(rows,id){
  const byID=new Map(rows.map(row=>[row.id,row]));if(!byID.has(id))throw invalid();const included=new Set([id]),ancestors=new Set();let parent=byID.get(id).parentID;
  while(parent&&!ancestors.has(parent)){ancestors.add(parent);parent=byID.get(parent)?.parentID;}
  for(const row of rows){let parent=row.parentID;const seen=new Set();while(parent&&!seen.has(parent)){if(parent===id){included.add(row.id);break;}seen.add(parent);parent=byID.get(parent)?.parentID;}}
  if(!rows.some(row=>included.has(row.id)&&row.imageFile))throw invalid();
  const result=rows.map(row=>({...row,isVisible:row.id===id||ancestors.has(row.id)||(included.has(row.id)&&row.isVisible!==false)})),updated=new Map(result.map(row=>[row.id,row]));
  for(const row of result){row.effectiveVisible=row.isVisible;row.effectiveOpacity=row.opacity??1;let parent=row.parentID;const seen=new Set();while(parent&&!seen.has(parent)){seen.add(parent);const folder=updated.get(parent);if(!folder)break;row.effectiveVisible&&=folder.isVisible;row.effectiveOpacity*=folder.opacity??1;parent=folder.parentID;}}
  return result;
}
export function batchTargets(manifest,options,selected,name){
  if(!options.individualLayers)return[{id:null,name:batchSafeName(options.prefix+name.replace(/\.comp$/i,''))}];
  if(!Array.isArray(selected)||!selected.length||selected.length>100||new Set(selected).size!==selected.length||selected.some(id=>!manifest.layers.some(layer=>layer.id===id)))throw invalid();
  const names=new Set();return manifest.layers.filter(layer=>selected.includes(layer.id)).map(layer=>{isolateBatchRows(manifest.layers,layer.id);const base=batchSafeName(options.prefix+layer.name+'-'+layer.id.slice(0,8));let name=base,suffix=1;while(names.has(name.toLowerCase()))name=base.slice(0,100)+'-'+suffix++;names.add(name.toLowerCase());return{id:layer.id,name};});
}
