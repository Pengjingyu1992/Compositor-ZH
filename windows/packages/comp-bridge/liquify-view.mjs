export function liquifyMesh(field,settings){
  const{width,height,step,gridWidth,gridHeight}=settings,spacing=Math.max(16,Math.max(width,height)/24),lines=[];
  const point=(x,y)=>{const gx=Math.min(gridWidth-1,Math.max(0,Math.floor(x/step))),gy=Math.min(gridHeight-1,Math.max(0,Math.floor(y/step))),index=(gy*gridWidth+gx)*3;return[x+field[index],y+field[index+1]];};
  for(let x=0;x<=width;x+=spacing){const line=[point(x,0)];for(let y=spacing;y<=height;y+=spacing)line.push(point(x,y));lines.push(line);}
  for(let y=0;y<=height;y+=spacing){const line=[point(0,y)];for(let x=spacing;x<=width;x+=spacing)line.push(point(x,y));lines.push(line);}
  return lines;
}
