import {resolveFont,fontNames,fontByteSize}from'./system-fonts.mjs';
import {supportsTextStyle,layoutText,warpTextPoint}from'../comp-bridge/text-layout.mjs';
import {supportsVectorPath,vectorSVG}from'../comp-bridge/layer-styles.mjs';
import {ProjectError}from'../comp-bridge/project.mjs';
import sharp from'./native-imaging.mjs';
export {fontNames};

export async function textOutlines(style){
  if(!supportsTextStyle(style)||!style.boxSize)throw new ProjectError('invalid');
  const [width,height]=style.boxSize,segments=[...new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(style.content)],runs=style.fontRuns??[],prepared=new Map(),fonts=new Set();let ri=0,fontBytes=0;
  for(const segment of segments){if(/^[\r\n\u2028\u2029]+$/.test(segment.segment))continue;while(ri<runs.length&&segment.index>=runs[ri].location+runs[ri].length)ri++;const name=runs[ri]?.location<=segment.index?runs[ri].fontName:style.fontName,font=await resolveFont(name,segment.segment),run=font.layout(segment.segment),scale=style.fontSize/font.unitsPerEm;
    if(!fonts.has(font)){fonts.add(font);fontBytes+=fontByteSize(font);if(fontBytes>128*1024**2)throw new ProjectError('limit');}
    if(run.glyphs.some(glyph=>glyph.id===0)&&!/^\s+$/u.test(segment.segment))throw new ProjectError('glyph');
    prepared.set(segment.index,{run,scale,width:run.positions.reduce((sum,p)=>sum+p.xAdvance,0)*scale});
  }
  const placements=layoutText(style,(_text,_font,_size,index)=>prepared.get(index)?.width??0),contours=[];let anchorCount=0;
  for(const placed of placements){const {run,scale}=prepared.get(placed.index),cs=Math.cos(placed.angle),sn=Math.sin(placed.angle);let cursorX=0,cursorY=0;
    const transform=(x,y,position)=>{const lx=(x+cursorX+position.xOffset)*scale,ly=-(y+cursorY+position.yOffset)*scale,p=warpTextPoint([placed.x+lx*cs-ly*sn,placed.y+lx*sn+ly*cs],style);return[p[0]/width,p[1]/height];};
    for(let i=0;i<run.glyphs.length;i++){const glyph=run.glyphs[i],position=run.positions[i],commands=glyph.path.commands;let contour,current,rawPoint,rawStart;
      if(!commands.length&&!/^\s+$/u.test(placed.text))throw new ProjectError('glyph');
      for(const item of commands){const a=item.args;
        if(item.command==='moveTo'){rawPoint=rawStart=[a[0],a[1]];contour={anchors:[],closed:false,color:placed.color};contours.push(contour);current={point:transform(a[0],a[1],position),smooth:false};contour.anchors.push(current);anchorCount++;}
        else if(item.command==='lineTo'){rawPoint=[a[0],a[1]];current={point:transform(a[0],a[1],position),smooth:false};contour.anchors.push(current);anchorCount++;}
        else if(item.command==='quadraticCurveTo'){const end=[a[2],a[3]],control=[a[0],a[1]],c1=rawPoint.map((v,j)=>v+(control[j]-v)*2/3),c2=end.map((v,j)=>v+(control[j]-v)*2/3);current.outgoing=transform(c1[0],c1[1],position);current={point:transform(end[0],end[1],position),incoming:transform(c2[0],c2[1],position),smooth:true};contour.anchors.push(current);rawPoint=end;anchorCount++;}
        else if(item.command==='bezierCurveTo'){rawPoint=[a[4],a[5]];current.outgoing=transform(a[0],a[1],position);current={point:transform(a[4],a[5],position),incoming:transform(a[2],a[3],position),smooth:true};contour.anchors.push(current);anchorCount++;}
        else if(item.command==='closePath'){rawPoint=rawStart;contour.closed=true;const first=contour.anchors[0],last=contour.anchors.at(-1);if(contour.anchors.length>1&&Math.hypot(first.point[0]-last.point[0],first.point[1]-last.point[1])<1e-9){if(last.incoming)first.incoming=last.incoming;contour.anchors.pop();anchorCount--;}}
        else throw new ProjectError('glyph');
        if(anchorCount>40000||contours.length>10000)throw new ProjectError('limit');
      }
      cursorX+=position.xAdvance;cursorY+=position.yAdvance;
    }
  }
  const vector={contours,evenOdd:false,fillEnabled:true,strokeEnabled:false,strokeColor:{red:0,green:0,blue:0},strokeWidth:0,roundCaps:false};if(!supportsVectorPath(vector))throw new ProjectError('glyph');return vector;
}
export async function renderVectorText(style){
  const vector=await textOutlines(style),[w,h]=style.boxSize.map(Math.ceil),svg=vectorSVG(w,h,vector,{red:style.red,green:style.green,blue:style.blue});
  return {png:await sharp(Buffer.from(svg),{limitInputPixels:16_000_000}).png().timeout({seconds:20}).toBuffer(),vector};
}
