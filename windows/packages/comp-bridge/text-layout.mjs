import {supportsVectorPath,validRGB} from './layer-styles.mjs';
const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const known=(v,keys)=>object(v)&&Object.keys(v).every(key=>keys.includes(key));
const finite=(v,a,b)=>typeof v==='number'&&Number.isFinite(v)&&v>=a&&v<=b;
export const fontFamily=name=>({'ArialMT':'Arial','Helvetica':'Arial','MicrosoftYaHei':'Microsoft YaHei','SegoeUI':'Segoe UI'}[name]??name);
export function supportsTextStyle(style) {
  if(!known(style,['content','fontName','fontSize','red','green','blue','alignment','vertical','pathLayout','warp','tracking','leading','boxSize','colorRuns','fontRuns'])||typeof style.content!=='string'||style.content.length>100000||typeof style.fontName!=='string'||!style.fontName.length||style.fontName.length>200||/[\r\n\u2028\u2029]/.test(style.fontName)||!finite(style.fontSize,1,2000)||!validRGB({red:style.red,green:style.green,blue:style.blue})||!['Left','Center','Right','Justified'].includes(style.alignment)||!finite(style.tracking,-100,1000)||!finite(style.leading,0,5000)||style.vertical!=null&&typeof style.vertical!=='boolean')return false;
  if(style.boxSize!=null&&(!Array.isArray(style.boxSize)||style.boxSize.length!==2||style.boxSize.some(n=>!finite(n,16,30000))||style.boxSize[0]*style.boxSize[1]>16_000_000))return false;
  for(const field of ['colorRuns','fontRuns']){let end=0;if(style[field]!=null&&(!Array.isArray(style[field])||style[field].length>10000))return false;
    for(const run of style[field]??[]){if(!known(run,field==='colorRuns'?['location','length','red','green','blue']:['location','length','fontName'])||!Number.isInteger(run.location)||!Number.isInteger(run.length)||run.location<end||run.length<1||(end=run.location+run.length)>style.content.length)return false;
      if(field==='colorRuns'&&!validRGB({red:run.red,green:run.green,blue:run.blue}))return false;
      if(field==='fontRuns'&&(typeof run.fontName!=='string'||!run.fontName.length||run.fontName.length>200||/[\r\n\u2028\u2029]/.test(run.fontName)))return false;
    }
  }
  if(style.warp!=null&&(!known(style.warp,['bend'])||!finite(style.warp.bend,-1,1)))return false;
  if(style.pathLayout!=null){const p=style.pathLayout;if(!known(p,['path','offset','reversed'])||!supportsVectorPath(p.path)||p.path.contours.length!==1||p.path.contours[0].anchors.length<2||p.path.contours[0].anchors.length>3000||!finite(p.offset,-30000,30000)||typeof p.reversed!=='boolean'||style.vertical||/[\r\n\u2028\u2029]/.test(style.content)||style.warp!=null)return false;}
  return true;
}
const fail=code=>{const error=new Error(code);error.code=code;throw error;};
export function pathSamples(vector,width,height,reversed=false) {
  const contour=vector.contours[0],anchors=[...contour.anchors,...(contour.closed?[contour.anchors[0]]:[])],points=[[anchors[0].point[0]*width,anchors[0].point[1]*height]];
  for(let i=1;i<anchors.length;i++){const a=anchors[i-1].point,b=anchors[i-1].outgoing??a,d=anchors[i].point,c=anchors[i].incoming??d;
    for(let n=1;n<=32;n++){const t=n/32,u=1-t;points.push([width*(u*u*u*a[0]+3*u*u*t*b[0]+3*u*t*t*c[0]+t*t*t*d[0]),height*(u*u*u*a[1]+3*u*u*t*b[1]+3*u*t*t*c[1]+t*t*t*d[1])]);}}
  return reversed?points.reverse():points;
}
export function layoutText(style,measure) {
  if(!supportsTextStyle(style)||!style.boxSize)fail('invalid');const [width,height]=style.boxSize,padding=12,size=style.fontSize,tracking=style.tracking,leading=style.leading||size*1.2;
  const segments=[...new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(style.content)],glyphs=[];let fi=0,ci=0;
  for(const segment of segments){const index=segment.index;while(fi<(style.fontRuns?.length??0)&&index>=style.fontRuns[fi].location+style.fontRuns[fi].length)fi++;while(ci<(style.colorRuns?.length??0)&&index>=style.colorRuns[ci].location+style.colorRuns[ci].length)ci++;
    const font=style.fontRuns?.[fi]?.location<=index?style.fontRuns[fi].fontName:style.fontName,paint=style.colorRuns?.[ci]?.location<=index?style.colorRuns[ci]:style,color={red:paint.red,green:paint.green,blue:paint.blue},text=segment.segment,newline=/^[\r\n\u2028\u2029]+$/.test(text),metric=newline?0:measure(text,font,size,index),upright=/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Extended_Pictographic}]/u.test(text);
    if(!finite(metric,0,1_000_000))fail('invalid');glyphs.push({text,index,font,color,metric,advance:(style.vertical&&upright?size:metric)+tracking,newline,upright});
  }
  const placed=[];
  if(style.pathLayout){const p=style.pathLayout,points=pathSamples(p.path,width,height,p.reversed),lengths=[0];for(let i=1;i<points.length;i++)lengths.push(lengths.at(-1)+Math.hypot(points[i][0]-points[i-1][0],points[i][1]-points[i-1][1]));
    const total=lengths.at(-1),textWidth=glyphs.reduce((sum,g)=>sum+g.advance,0)-(glyphs.length?tracking:0),offset=p.offset+(style.alignment==='Center'?(total-textWidth)/2:style.alignment==='Right'?total-textWidth:0);if(offset<0||textWidth<0||offset+textWidth>total+.01)fail('pathLength');let cursor=offset;
    for(const glyph of glyphs){const distance=cursor+glyph.metric/2;if(distance<0||distance>total+.01)fail('pathLength');let low=1,high=points.length-1;while(low<high){const middle=(low+high)>>1;if(lengths[middle]<distance)low=middle+1;else high=middle;}const a=points[low-1],b=points[low],t=(distance-lengths[low-1])/Math.max(.00001,lengths[low]-lengths[low-1]),angle=Math.atan2(b[1]-a[1],b[0]-a[0]);placed.push({...glyph,x:a[0]+(b[0]-a[0])*t-Math.cos(angle)*glyph.metric/2,y:a[1]+(b[1]-a[1])*t-Math.sin(angle)*glyph.metric/2,angle});cursor+=glyph.advance;}
    return placed;
  }
  const extent=(style.vertical?height:width)-padding*2,lines=[{glyphs:[],length:0,paragraphEnd:false}];
  for(const glyph of glyphs){let line=lines.at(-1);if(glyph.newline){line.paragraphEnd=true;lines.push({glyphs:[],length:0,paragraphEnd:false});continue;}if(line.glyphs.length&&line.length+glyph.advance-tracking>extent){line={glyphs:[],length:0,paragraphEnd:false};lines.push(line);}line.glyphs.push(glyph);line.length+=glyph.advance;}
  lines.at(-1).paragraphEnd=true;
  lines.forEach((line,index)=>{const length=line.length-(line.glyphs.length?tracking:0),spaces=line.glyphs.filter(g=>/^\s+$/u.test(g.text)).length,gaps=spaces||Math.max(0,line.glyphs.length-1),justify=style.alignment==='Justified'&&!line.paragraphEnd&&gaps&&length<extent?(extent-length)/gaps:0;let cursor=padding+(style.alignment==='Center'?(extent-length)/2:style.alignment==='Right'?extent-length:0);
    for(let i=0;i<line.glyphs.length;i++){const glyph=line.glyphs[i];let x=cursor,y=padding+size+index*leading,angle=0;
      if(style.vertical){const center=width-padding-size/2-index*leading;if(center+size/2<0)return;if(glyph.upright){x=center-glyph.metric/2;y=cursor+size*.85;}else{x=center-size*.35;y=cursor;angle=Math.PI/2;}}
      else if(y-size>height)return;
      placed.push({...glyph,x,y,angle});cursor+=glyph.advance+(justify&&(!spaces||/^\s+$/u.test(glyph.text))?justify:0);
    }
  });return placed;
}
export function warpTextPoint(point,style) {const [w,h]=style.boxSize;return [point[0],point[1]-(style.warp?.bend??0)*4*(point[0]/w)*(1-point[0]/w)*h];}
