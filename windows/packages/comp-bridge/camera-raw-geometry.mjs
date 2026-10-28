const fail=()=>{throw Object.assign(new Error('invalid'),{code:'invalid'});};
export function cameraRawCorners(width,height,g){
  let vertical=g.vertical,horizontal=g.horizontal,rotate=g.rotate;const guides=g.guides.filter(line=>Math.hypot(line.endX-line.startX,line.endY-line.startY)>.01);
  if(g.upright==='Guided'&&guides.length){const first=guides[0],angle=Math.atan2(first.endY-first.startY,first.endX-first.startX)*180/Math.PI;let correction=-angle;if(correction>45)correction-=90;else if(correction< -45)correction+=90;rotate+=correction;if(guides.length>1){const second=guides[1],angle=Math.atan2(second.endY-second.startY,second.endX-second.startX)*180/Math.PI;vertical+=Math.abs(angle)>45?(angle>0?25:-25):0;horizontal+=Math.abs(angle)<=45?(angle>0?25:-25):0;}}
  const strength=g.projection==='Perspective'?1:.55,v=vertical/100*width*.18*strength,hz=horizontal/100*height*.18*strength,aspect=1+g.aspect/200,zoom=1+g.scale/100,dx=g.offsetX/100*width*.15,dy=g.offsetY/100*height*.15,cx=width/2+dx,cy=height/2+dy,radians=rotate*Math.PI/180,c=Math.cos(radians),s=Math.sin(radians);
  return[[-v+dx,height+dy],[width+v+dx,height+dy],[width+hz+dx,-dy],[-hz+dx,-dy]].map(([x,y])=>{const px=x-cx,py=y-cy;return[cx+(px*c-py*s)*aspect*zoom,height-(cy+(px*s+py*c)/aspect*zoom)];});
}
// Solve the inverse homography once, then sample premultiplied coverage. This
// preserves holes/soft transparency through perspective and guided correction.
export function inverseHomography(from,to){
  const rows=[];for(let index=0;index<4;index++){const[x,y]=from[index],[u,v]=to[index];rows.push([x,y,1,0,0,0,-u*x,-u*y,u],[0,0,0,x,y,1,-v*x,-v*y,v]);}
  for(let column=0;column<8;column++){let pivot=column;for(let row=column+1;row<8;row++)if(Math.abs(rows[row][column])>Math.abs(rows[pivot][column]))pivot=row;if(Math.abs(rows[pivot][column])<1e-10)fail();[rows[column],rows[pivot]]=[rows[pivot],rows[column]];const divisor=rows[column][column];for(let j=column;j<9;j++)rows[column][j]/=divisor;for(let row=0;row<8;row++){if(row===column)continue;const amount=rows[row][column];for(let j=column;j<9;j++)rows[row][j]-=amount*rows[column][j];}}
  return rows.map(row=>row[8]);
}
function sample(image,x,y,out,offset){
  const ix=Math.floor(x),iy=Math.floor(y),fx=x-ix,fy=y-iy,sums=[0,0,0,0];for(let row=0;row<2;row++)for(let column=0;column<2;column++){const sx=ix+column,sy=iy+row;if(sx<0||sy<0||sx>=image.width||sy>=image.height)continue;const weight=(column?fx:1-fx)*(row?fy:1-fy),index=(sy*image.width+sx)*4,alpha=image.data[index+3];sums[3]+=alpha*weight;for(let c=0;c<3;c++)sums[c]+=image.data[index+c]*alpha*weight;}
  for(let c=0;c<3;c++)out[offset+c]=sums[3]?Math.round(sums[c]/sums[3]):0;out[offset+3]=Math.round(sums[3]);
}
export function cameraRawGeometry(image,g){
  if(!g.guides.some(line=>g.upright==='Guided'&&Math.hypot(line.endX-line.startX,line.endY-line.startY)>.01)&&['vertical','horizontal','rotate','aspect','scale','offsetX','offsetY'].every(key=>g[key]===0))return image;
  const{width:w,height:h}=image,corners=cameraRawCorners(w,h,g),matrix=inverseHomography(corners,[[0,0],[w,0],[w,h],[0,h]]),data=new Uint8ClampedArray(w*h*4);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){const px=x+.5,py=y+.5,denominator=matrix[6]*px+matrix[7]*py+1;if(Math.abs(denominator)>1e-8)sample(image,(matrix[0]*px+matrix[1]*py+matrix[2])/denominator-.5,(matrix[3]*px+matrix[4]*py+matrix[5])/denominator-.5,data,(y*w+x)*4);}
  const result={width:w,height:h,data};if(!g.constrainCrop)return result;let left=w,top=h,right=0,bottom=0;for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(data[(y*w+x)*4+3]){left=Math.min(left,x);top=Math.min(top,y);right=Math.max(right,x+1);bottom=Math.max(bottom,y+1);}if(right<=left||bottom<=top||(left===0&&top===0&&right===w&&bottom===h))return result;
  const scale=Math.min(w/(right-left),h/(bottom-top)),dx=(w-(right-left)*scale)/2,dy=(h-(bottom-top)*scale)/2,fitted=new Uint8ClampedArray(data.length);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const sx=(x+.5-dx)/scale+left-.5,sy=(y+.5-dy)/scale+top-.5;if(sx>=left-.5&&sx<right-.5&&sy>=top-.5&&sy<bottom-.5)sample(result,sx,sy,fitted,(y*w+x)*4);}return{width:w,height:h,data:fitted};
}
