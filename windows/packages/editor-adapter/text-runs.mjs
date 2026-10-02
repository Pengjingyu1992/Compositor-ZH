// Runs use UTF-16 positions, matching Compositor's saved text model.
export function remapRuns(runs,before,after) {
  let start=0,suffix=0;
  while(start<Math.min(before.length,after.length)&&before[start]===after[start])start++;
  while(suffix<Math.min(before.length-start,after.length-start)&&before[before.length-1-suffix]===after[after.length-1-suffix])suffix++;
  const oldEnd=before.length-suffix,newEnd=after.length-suffix,shift=after.length-before.length,pieces=[];
  for(const r of runs){
    const end=r.location+r.length,left=Math.min(end,start),right=Math.max(r.location,oldEnd);
    if(left>r.location)pieces.push({...r,length:left-r.location});
    if(end>right)pieces.push({...r,location:right+shift,length:end-right});
  }
  const inherited=runs.find(r=>r.location<=start&&start<r.location+r.length)??runs.find(r=>r.location<start&&r.location+r.length===start);
  if(inherited&&newEnd>start)pieces.push({...inherited,location:start,length:newEnd-start});
  pieces.sort((a,b)=>a.location-b.location);
  const result=[],style=r=>Object.fromEntries(Object.entries(r).filter(([key])=>!['location','length'].includes(key)));
  for(const r of pieces){const last=result.at(-1);if(last&&last.location+last.length===r.location&&JSON.stringify(style(last))===JSON.stringify(style(r)))last.length+=r.length;else result.push(r);}
  return result;
}
export function rangeStyle(runs,start,end,style) {
  if(end<=start)return runs;
  const next=runs.flatMap(r=>{const right=r.location+r.length;if(right<=start||r.location>=end)return [{...r}];return [...(r.location<start?[{...r,length:start-r.location}]:[]),...(right>end?[{...r,location:end,length:right-end}]:[])];});
  return [...next,{location:start,length:end-start,...style}].sort((a,b)=>a.location-b.location);
}
