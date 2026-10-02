// Straight sRGB pixels. Level/curve/exposure/color-balance math follows the
// macOS reference; spatial filters still require cross-platform golden images.
export const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
export function hsl(rgb) {
  const [r, g, b] = rgb, mx = Math.max(...rgb), mn = Math.min(...rgb), d = mx - mn, l = (mx + mn) / 2;
  let h = 0; if (d) h = ((mx === r ? (g - b) / d : mx === g ? (b - r) / d + 2 : (r - g) / d + 4) / 6 + 1) % 1;
  return [h, d ? d / (1 - Math.abs(2 * l - 1)) : 0, l];
}
export function rgb([h, s, l]) {
  const c = (1 - Math.abs(2 * l - 1)) * s, hp = ((h % 1 + 1) % 1) * 6, x = c * (1 - Math.abs(hp % 2 - 1)), m = l - c / 2;
  return (hp < 1 ? [c, x, 0] : hp < 2 ? [x, c, 0] : hp < 3 ? [0, c, x] : hp < 4 ? [0, x, c] : hp < 5 ? [x, 0, c] : [c, 0, x]).map(v => clamp(v + m));
}
export function curveValue(points, value) {
  const x = value * 255, index = Math.max(0, Math.min(points.length - 2, points.findLastIndex(p => p.x <= x)));
  const slopes = points.slice(1).map((p, i) => (p.y - points[i].y) / (p.x - points[i].x));
  const slope = j => j === 0 ? slopes[0] : j === points.length - 1 ? slopes.at(-1) : slopes[j - 1] * slopes[j] <= 0 ? 0 : 2 / (1 / slopes[j - 1] + 1 / slopes[j]);
  const a = points[index], b = points[index + 1], width = b.x - a.x, t = clamp((x - a.x) / width);
  return clamp(((2*t*t*t-3*t*t+1)*a.y + (t*t*t-2*t*t+t)*width*slope(index) + (-2*t*t*t+3*t*t)*b.y + (t*t*t-t*t)*width*slope(index+1)) / 255);
}
const level = (v, r = {}) => ((r.outputBlack ?? 0) + Math.pow(clamp((v * 255 - (r.black ?? 0)) / ((r.white ?? 255) - (r.black ?? 0))), 1 / (r.gamma ?? 1)) * ((r.outputWhite ?? 255) - (r.outputBlack ?? 0))) / 255;
const linear = v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4;
const encoded = v => v <= .0031308 ? v * 12.92 : 1.055 * Math.max(0, v) ** (1 / 2.4) - .055;
const mix32 = value => { let v = value >>> 0; v ^= v >>> 16; v = Math.imul(v, 0x7feb352d); v ^= v >>> 15; v = Math.imul(v, 0x846ca68b); return (v ^ v >>> 16) >>> 0; };
const random = (x, y, seed, c = 0) => (mix32(Math.imul(x, 0x9e3779b1) ^ mix32(Math.imul(y, 0x85ebca77) ^ seed ^ Math.imul(c, 0x27d4eb2d))) + .5) / 4294967296;
function grainField(x, y, size, seed) {
  const ix = Math.floor(x / size), iy = Math.floor(y / size), sx = x / size - ix, sy = y / size - iy, tx = sx*sx*(3-2*sx), ty = sy*sy*(3-2*sy);
  const lattice = (x, y) => { const h = mix32(Math.imul(x, 0x9e3779b1) ^ mix32(Math.imul(y, 0x85ebca77) ^ seed)); return (h & 65535) / 65535 + (h >>> 16) / 65535 - 1; };
  const top = lattice(ix, iy) * (1 - tx) + lattice(ix + 1, iy) * tx, bottom = lattice(ix, iy + 1) * (1 - tx) + lattice(ix + 1, iy + 1) * tx;
  return (top * (1 - ty) + bottom * ty) * 1.6;
}
export function boxPlane(input, w, h, radius) {
  const r = Math.max(0, Math.round(radius)); if (!r) return new Float32Array(input);
  const temp = new Float32Array(w * h), output = new Float32Array(w * h), div = 2 * r + 1;
  for (let y = 0; y < h; y++) {
    let sum = 0; for (let x = -r; x <= r; x++) sum += input[y * w + clamp(x, 0, w - 1)];
    for (let x = 0; x < w; x++) { temp[y*w+x] = sum/div; sum += input[y*w+clamp(x+r+1,0,w-1)]-input[y*w+clamp(x-r,0,w-1)]; }
  }
  for (let x = 0; x < w; x++) {
    let sum = 0; for (let y = -r; y <= r; y++) sum += temp[clamp(y,0,h-1)*w+x];
    for (let y = 0; y < h; y++) { output[y*w+x] = sum/div; sum += temp[clamp(y+r+1,0,h-1)*w+x]-temp[clamp(y-r,0,h-1)*w+x]; }
  }
  return output;
}
export function blurPlane(input, w, h, sigma) {
  if (!sigma) return new Float32Array(input);
  const ideal = Math.sqrt(4 * sigma * sigma + 1), lower = Math.floor(ideal) | 1;
  const widths = [lower, lower, lower + 2];
  let data = input; for (const width of widths) data = boxPlane(data, w, h, (width - 1) / 2);
  return data;
}
function spatial(data, w, h, settings) {
  if (settings.kind === 'Gaussian Blur') {
    const planes = Array.from({ length: 4 }, (_, c) => Float32Array.from({ length: w * h }, (_, i) => c === 3 ? data[i*4+3] / 255 : data[i*4+c] * data[i*4+3] / 65025));
    const blurred = planes.map(p => blurPlane(p, w, h, settings.blurRadius ?? 10));
    for (let i = 0; i < w*h; i++) { for (let c = 0; c < 3; c++) data[i*4+c] = blurred[3][i] ? blurred[c][i] / blurred[3][i] * 255 : 0; data[i*4+3] = blurred[3][i] * 255; }
  } else {
    const original = new Uint8ClampedArray(data), angle = (settings.motionAngle ?? 0) * Math.PI / 180, distance = settings.motionDistance ?? 10;
    const steps = Math.min(128, Math.max(2, Math.ceil(distance))), dx = Math.cos(angle)*distance, dy = -Math.sin(angle)*distance;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const sum = [0,0,0,0];
      for (let n = 0; n < steps; n++) {
        const at = (clamp(Math.round(y + dy * (n/(steps-1)-.5)),0,h-1)*w + clamp(Math.round(x + dx*(n/(steps-1)-.5)),0,w-1))*4, a = original[at+3]/255;
        for (let c = 0; c < 3; c++) sum[c] += original[at+c]*a;
        sum[3] += a;
      }
      const at = (y*w+x)*4; for (let c=0;c<3;c++) data[at+c] = sum[3] ? sum[c]/sum[3] : 0; data[at+3] = sum[3]/steps*255;
    }
  }
}
export function adjustedPixels(image, a) {
  const { width: w, height: h } = image, data = new Uint8ClampedArray(image.data);
  if (['Gaussian Blur', 'Motion Blur'].includes(a.kind)) { spatial(data, w, h, a); return { width: w, height: h, data }; }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const at = (y*w+x)*4; if (!data[at+3]) continue;
    let values = [data[at]/255, data[at+1]/255, data[at+2]/255];
    switch (a.kind) {
      case 'Invert': values = values.map(v => 1 - v); break;
      case 'Levels': values = values.map((v,c) => level(level(v,a.levels?.ranges[c+1]),a.levels?.ranges[0])); break;
      case 'Curves': if (a.curves) values = values.map((v,c) => curveValue(a.curves.channels[0],curveValue(a.curves.channels[c+1],v))); break;
      case 'Exposure': { const s = a.exposureSettings ?? {}; values = values.map(v => clamp(encoded(Math.max(0, linear(v)*2**(s.exposure??0)+(s.offset??0))**(1/(s.gamma??1))))); break; }
      case 'Hue/Saturation': {
        let [hue,s,l] = hsl(values); hue = a.colorize ? (a.hue??0)/360 : hue+(a.hue??0)/360;
        s = a.colorize ? clamp((a.saturation??0)/100) : clamp(s*(1+(a.saturation??0)/100));
        const change = (a.lightness??0)/100; l = change < 0 ? l*(1+change) : l+(1-l)*change; values = rgb([hue,s,l]); break;
      }
      case 'Gradient Map': {
        const s = a.gradientMapSettings ?? {}, c = { red:0,green:0,blue:0 }, white={red:1,green:1,blue:1};
        const lo = s.reversed ? s.highlights??white : s.shadows??c, hi=s.reversed ? s.shadows??c : s.highlights??white, t=values[0]*.2126+values[1]*.7152+values[2]*.0722;
        values=['red','green','blue'].map(k=>lo[k]+(hi[k]-lo[k])*t); break;
      }
      case 'Black & White': {
        const s=a.blackWhiteSettings??{}, [r,g,b]=values,mx=Math.max(...values),mn=Math.min(...values),md=r+g+b-mx-mn;
        const p=mx===r?'reds':mx===g?'greens':'blues', q=mx===r?(g>=b?'yellows':'magentas'):mx===g?(r>=b?'yellows':'cyans'):(g>=r?'cyans':'magentas'), defaults={reds:40,yellows:60,greens:40,cyans:60,blues:20,magentas:80};
        const gray=clamp(mn+(md-mn)*(s[q]??defaults[q])/100+(mx-md)*(s[p]??defaults[p])/100);
        values=s.tint?rgb([(s.tintHue??40)/360,(s.tintSaturation??20)/100,gray]):[gray,gray,gray];break;
      }
      case 'Color Balance': {
        const s=a.colorBalanceSettings??{}, before=values[0]*.299+values[1]*.587+values[2]*.114;
        values=values.map((v,c)=>{ const suffix=['CyanRed','MagentaGreen','YellowBlue'][c],sw=clamp((v-.333)/-.25+.5)*.7,mw=clamp((v-.333)/.25+.5)*clamp((v+.333-1)/-.25+.5)*.7,hw=clamp((v+.333-1)/.25+.5)*.7;return clamp(v+((s['shadow'+suffix]??0)*sw+(s['mid'+suffix]??0)*mw+(s['highlight'+suffix]??0)*hw)/100); });
        if(s.preserveLuminosity!==false){const after=values[0]*.299+values[1]*.587+values[2]*.114;if(after>.0001)values=values.map(v=>clamp(v*before/after));}break;
      }
      case 'Grain': {
        const s=a.grainSettings??{},size=s.size??1.5,seed=s.seed??0, rough=(s.roughness??50)/100;
        const smooth=grainField(x+.5,y+.5,size,seed),fine=grainField(x+.5,y+.5,Math.max(.5,size*.35),mix32(seed^0xa511e9b3)),level=values[0]*.2126+values[1]*.7152+values[2]*.0722,delta=(smooth+(fine-smooth)*rough)*(s.amount??25)/100*.35*(.4+2.4*level*(1-level)); values=values.map(v=>clamp(v+delta));break;
      }
      case 'Add Noise': values=values.map((v,c)=>{const channel=a.noiseMonochromatic?0:c,u=random(x,y,a.noiseSeed??0,channel),z=a.noiseGaussian?Math.sqrt(-2*Math.log(u))*Math.cos(2*Math.PI*random(x,y,a.noiseSeed??0,channel+4)):(u*2-1);return clamp(v+z*(a.noiseAmount??10)/100);});break;
    }
    for(let c=0;c<3;c++)data[at+c]=clamp(values[c])*255;
  }
  return {width:w,height:h,data};
}

// Linear-time sliding windows keep the effect cost independent of its radius.
function extreme(input,w,h,r,max) {
  const temp=new Float32Array(w*h),out=new Float32Array(w*h),radius=Math.round(r);
  const line=(size,read,write)=>{const queue=new Int32Array(size+radius*2+2);let head=0,tail=0;
    for(let i=-radius;i<size+radius;i++){const v=read(i);while(tail>head&&(max?read(queue[tail-1])<=v:read(queue[tail-1])>=v))tail--;queue[tail++]=i;while(tail>head&&queue[head]<i-radius*2)head++;if(i>=radius)write(i-radius,read(queue[head]));}};
  for(let y=0;y<h;y++)line(w,x=>x<0||x>=w?0:input[y*w+x],(x,v)=>temp[y*w+x]=v);
  for(let x=0;x<w;x++)line(h,y=>y<0||y>=h?0:temp[y*w+x],(y,v)=>out[y*w+x]=v);
  return out;
}
export function effectPixels(image,effects) {
  const {width:w,height:h}=image,alpha=Float32Array.from({length:w*h},(_,i)=>image.data[i*4+3]/255),out=new Uint8ClampedArray(image.data.length);
  function paint(plane,e,inside=false) {
    const color=[e.red??0,e.green??0,e.blue??0],opacity=e.opacity??.5;
    for(let i=0;i<w*h;i++){const a=clamp(plane[i])*opacity*(inside?alpha[i]:1),at=i*4,old=out[at+3]/255,next=a+old*(1-a);for(let c=0;c<3;c++)out[at+c]=next?(color[c]*a+out[at+c]/255*old*(1-a))/next*255:0;out[at+3]=next*255;}
  }
  function shifted(input,e,invert=false){const angle=(e.angle??135)*Math.PI/180,dx=Math.round(-Math.cos(angle)*(e.distance??10)),dy=Math.round(Math.sin(angle)*(e.distance??10)),plane=new Float32Array(w*h);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const sx=x-dx,sy=y-dy,v=sx>=0&&sy>=0&&sx<w&&sy<h?input[sy*w+sx]:0;plane[y*w+x]=invert?1-v:v;}return blurPlane(plane,w,h,e.blur??8);}
  const enabled=k=>effects[k]&&effects[k].enabled!==false;
  if(enabled('shadow'))paint(shifted(alpha,effects.shadow),effects.shadow);
  if(enabled('outerGlow')){const e=effects.outerGlow,blur=blurPlane(alpha,w,h,e.size??8);paint(Float32Array.from(blur,(v,i)=>v*(1-alpha[i])),e);}
  // The layer goes over its outer effects.
  for(let i=0;i<w*h;i++){const at=i*4,a=alpha[i],old=out[at+3]/255,next=a+old*(1-a);for(let c=0;c<3;c++)out[at+c]=next?(image.data[at+c]/255*a+out[at+c]/255*old*(1-a))/next*255:0;out[at+3]=next*255;}
  if(enabled('colorOverlay'))paint(new Float32Array(w*h).fill(1),effects.colorOverlay,true);
  if(enabled('innerShadow'))paint(shifted(alpha,effects.innerShadow,true),effects.innerShadow,true);
  if(enabled('innerGlow')){const e=effects.innerGlow,inv=Float32Array.from(alpha,v=>1-v);paint(blurPlane(inv,w,h,e.size??8),e,true);}
  if(enabled('stroke')){const e=effects.stroke,edge=extreme(alpha,w,h,e.size??8,!e.inside);paint(Float32Array.from(edge,(v,i)=>e.inside?alpha[i]-v:v-alpha[i]),e);}
  // Inner effects recolor coverage; they must not thicken a soft alpha edge.
  if(!enabled('shadow')&&!enabled('outerGlow')&&(!enabled('stroke')||effects.stroke.inside))for(let i=0;i<w*h;i++)out[i*4+3]=image.data[i*4+3];
  return {width:w,height:h,data:out};
}
