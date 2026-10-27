// Portable counterparts of macOS PosterColor / ColorLUT / PosterPixels.
// Pixels here use straight alpha; the native routines use premultiplied samples.
import { limit, validSurface } from './editor-math.mjs';

const fail = (code = 'invalid') => { const error = new Error(code); error.code = code; throw error; };
const finite = (n, min, max) => typeof n === 'number' && Number.isFinite(n) && n >= min && n <= max;
export const SELECTIVE_RANGES = ['Reds', 'Yellows', 'Greens', 'Cyans', 'Blues', 'Magentas', 'Whites', 'Neutrals', 'Blacks'];
export const IDENTITY_MIXER = [100,0,0,0,0,100,0,0,0,0,100,0];

export function validateColorLUT(table) {
  if (!table || typeof table.is1D !== 'boolean' || !Number.isInteger(table.size) || table.size < 2 || table.size > (table.is1D ? 65536 : 65) ||
    typeof table.name !== 'string' || new TextEncoder().encode(table.name).length > 16384 ||
    ![table.minimum, table.maximum].every(v => Array.isArray(v) && v.length === 3 && v.every(n => finite(n, -16, 16))) ||
    table.minimum.some((n, i) => n >= table.maximum[i]) || !Array.isArray(table.values) || table.values.length !== (table.is1D ? table.size : table.size ** 3) ||
    !table.values.every(v => Array.isArray(v) && v.length === 3 && v.every(n => finite(n, -16, 16)))) fail();
  return table;
}
export function parseColorLUT(value, name = 'Color LUT') {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > 16 * 1024 ** 2) fail('limit');
  let text; try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { fail(); }
  let size, is1D = false, minimum = [0,0,0], maximum = [1,1,1];
  const values = [], headers = new Set(), numeric = words => {
    if (words.length !== 3 || words.some(v => !/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(v))) fail();
    const result = words.map(Number); if (result.some(n => !finite(n, -16, 16))) fail(); return result;
  };
  for (const source of text.split(/\r?\n|\r/)) {
    const line = source.split('#', 1)[0].trim(); if (!line) continue;
    const [key, ...words] = line.split(/\s+/);
    if (key === 'TITLE') { if (values.length) fail(); continue; }
    if (['LUT_1D_SIZE', 'LUT_3D_SIZE'].includes(key)) {
      if (values.length || size !== undefined || words.length !== 1 || !/^\d+$/.test(words[0])) fail();
      size = Number(words[0]); is1D = key === 'LUT_1D_SIZE'; if (size < 2 || size > (is1D ? 65536 : 65)) fail();
    } else if (['DOMAIN_MIN', 'DOMAIN_MAX'].includes(key)) {
      if (values.length || headers.has(key)) fail(); headers.add(key);
      if (key === 'DOMAIN_MIN') minimum = numeric(words); else maximum = numeric(words);
    } else {
      if (size === undefined || values.length >= (is1D ? size : size ** 3)) fail();
      values.push(numeric([key, ...words]));
    }
  }
  return validateColorLUT({ name, size, is1D, minimum, maximum, values });
}
export function sampleColorLUT(table, color) {
  const low = [], high = [], weight = [], result = [0,0,0];
  for (let c = 0; c < 3; c++) { const at = limit((color[c] - table.minimum[c]) / (table.maximum[c] - table.minimum[c]) * (table.size - 1), 0, table.size - 1); low[c] = Math.floor(at); high[c] = Math.min(table.size - 1, low[c] + 1); weight[c] = at - low[c]; }
  if (table.is1D) return result.map((_, c) => table.values[low[c]][c] * (1 - weight[c]) + table.values[high[c]][c] * weight[c]);
  for (let z = 0; z < 2; z++) for (let y = 0; y < 2; y++) for (let x = 0; x < 2; x++) {
    const index = (x ? high[0] : low[0]) + table.size * ((y ? high[1] : low[1]) + table.size * (z ? high[2] : low[2]));
    const w = (x ? weight[0] : 1 - weight[0]) * (y ? weight[1] : 1 - weight[1]) * (z ? weight[2] : 1 - weight[2]);
    for (let c = 0; c < 3; c++) result[c] += table.values[index][c] * w;
  }
  return result;
}
function mapRGB(image, transform) {
  const data = new Uint8ClampedArray(image.data);
  for (let i = 0; i < data.length; i += 4) if (data[i + 3]) {
    const result = transform(image.data[i] / 255, image.data[i + 1] / 255, image.data[i + 2] / 255);
    for (let c = 0; c < 3; c++) data[i + c] = Math.round(limit(result[c], 0, 1) * 255);
  }
  return { width: image.width, height: image.height, data };
}

export function posterColorFilter(image, kind, settings = {}) {
  validSurface(image.width, image.height);
  if (!ArrayBuffer.isView(image.data) || image.data.BYTES_PER_ELEMENT !== 1 || image.data.length !== image.width * image.height * 4) fail();
  if (kind === 'Color Halftone') return halftonePixels(image, settings.halftone ?? settings);
  if (kind === 'Channel Mixer') {
    const coefficients = (settings.channelMixer ?? settings).coefficients ?? IDENTITY_MIXER;
    if (!Array.isArray(coefficients) || coefficients.length !== 12 || coefficients.some(n => !finite(n, -200, 200))) fail();
    return mapRGB(image, (r,g,b) => [0,4,8].map(i => (coefficients[i] * r + coefficients[i+1] * g + coefficients[i+2] * b + coefficients[i+3]) / 100));
  }
  if (kind === 'Selective Color') {
    const value = settings.selectiveColor ?? settings, adjustments = value.adjustments ?? {};
    if (!adjustments || typeof adjustments !== 'object' || Array.isArray(adjustments) || value.relative !== undefined && typeof value.relative !== 'boolean' || Object.entries(adjustments).some(([key, v]) => !SELECTIVE_RANGES.includes(key) || !Array.isArray(v) || v.length !== 4 || v.some(n => !finite(n, -100, 100)))) fail();
    return mapRGB(image, (r,g,b) => {
      const high = Math.max(r,g,b), low = Math.min(r,g,b), light = (high + low) / 2, result = [r,g,b];
      const weights = { Reds: Math.max(0,r-Math.max(g,b)), Greens:Math.max(0,g-Math.max(r,b)), Blues:Math.max(0,b-Math.max(r,g)), Cyans:Math.max(0,Math.min(g,b)-r), Magentas:Math.max(0,Math.min(r,b)-g), Yellows:Math.max(0,Math.min(r,g)-b), Whites:Math.max(0,(light-.5)*2), Blacks:Math.max(0,(.5-light)*2), Neutrals:Math.max(0,1-Math.abs(light-.5)*2)*(1-high+low) };
      for (const key of SELECTIVE_RANGES) if (adjustments[key]) for (let c = 0; c < 3; c++) { const component=[r,g,b][c], v=adjustments[key]; result[c] -= weights[key] * (v[c] / 100 * (value.relative === false ? 1 : 1-component) + v[3] / 100 * (value.relative === false ? 1 : component)); }
      return result;
    });
  }
  if (kind === 'Color Lookup') {
    const value = settings.colorLUT ?? settings.lut ?? settings, strength = value.strength ?? 100, space = value.space ?? 'Encoded sRGB';
    if (!finite(strength, 0, 100) || !['Encoded sRGB','Linear sRGB'].includes(space) || !value.table) fail();
    const table = validateColorLUT(value.table), amount = strength / 100;
    const linear = v => v <= .04045 ? v / 12.92 : ((v+.055)/1.055)**2.4, encoded = v => v <= .0031308 ? v*12.92 : 1.055*Math.max(0,v)**(1/2.4)-.055;
    return mapRGB(image,(r,g,b)=>{const original=[r,g,b], result=sampleColorLUT(table,space==='Linear sRGB'?original.map(linear):original);return original.map((v,c)=>v*(1-amount)+(space==='Linear sRGB'?encoded(result[c]):result[c])*amount);});
  }
  fail();
}

function circleArea(radius) {
  let area = Math.PI * radius * radius;
  if (radius > .5) area -= 4 * (radius * radius * Math.acos(.5/radius) - .5*Math.sqrt(radius*radius-.25));
  return limit(area,0,1);
}
export function halftonePixels(image, settings = {}) {
  const { width, height, data:source }=image;
  validSurface(width,height);
  if (!ArrayBuffer.isView(source) || source.BYTES_PER_ELEMENT !== 1 || source.length !== width * height * 4) fail();
  const size=settings.size??8, strength=(settings.strength??100)/100, shape=settings.shape??'Round', screen=settings.screen;
  const angles=[settings.cyan??108,settings.magenta??162,settings.yellow??90,settings.black??45];
  if (!finite(size,2,128) || !finite(strength,0,1) || !['Round','Square','Line'].includes(shape) || angles.some(n=>!finite(n,-180,180)) || screen!==undefined&&!['Automatic Channels','RGB Channels','Grayscale Screen','Legacy CMYK Print'].includes(screen)) fail();
  const data=new Uint8ClampedArray(source);if(!strength)return {width,height,data};
  const radii=new Float64Array(256);for(let i=0;i<256;i++){let low=0,high=.707106781186548;for(let j=0;j<20;j++){const mid=(low+high)/2;if(circleArea(mid)<i/255)low=mid;else high=mid;}radii[i]=(low+high)/2;}
  if(screen===undefined||screen==='Legacy CMYK Print') {
    const cs=angles.map(v=>Math.cos(v*.0174532925199433)),sn=angles.map(v=>Math.sin(v*.0174532925199433));
    const ink=(at,c)=>{if(!source[at+3])return 0;const black=1-Math.max(source[at],source[at+1],source[at+2])/255;return c===3?black:black>=.99999?0:limit((1-source[at+c]/255-black)/(1-black),0,1);};
    for(let y=0;y<height;y++)for(let x=0;x<width;x++){const at=(y*width+x)*4;if(!source[at+3])continue;const dots=[];
      for(let c=0;c<4;c++){const u=((x+.5)*cs[c]+(y+.5)*sn[c])/size,v=(-(x+.5)*sn[c]+(y+.5)*cs[c])/size,cu=Math.floor(u)+.5,cv=Math.floor(v)+.5,sx=limit(Math.floor((cu*cs[c]-cv*sn[c])*size),0,width-1),sy=limit(Math.floor((cu*sn[c]+cv*cs[c])*size),0,height-1),tone=ink((sy*width+sx)*4,c),dx=Math.abs(u-cu),dy=Math.abs(v-cv),distance=shape==='Square'?Math.max(dx,dy):shape==='Line'?dy:Math.hypot(dx,dy),r=shape==='Square'?Math.sqrt(tone)/2:shape==='Line'?tone/2:radii[Math.round(tone*255)];dots[c]=tone<=0?0:tone>=1?1:limit((r-distance)*size+.5,0,1);}
      for(let c=0;c<3;c++)data[at+c]=Math.round(source[at+c]*(1-strength)+(1-dots[c])*(1-dots[3])*255*strength);
    }
    return {width,height,data};
  }
  let gray=screen==='Grayscale Screen';
  if(screen==='Automatic Channels'){gray=true;for(let i=0;i<source.length;i+=4)if(source[i+3]&&(Math.abs(source[i]-source[i+1])>1||Math.abs(source[i+1]-source[i+2])>1)){gray=false;break;}}
  const cell=size*Math.SQRT2,coverage=new Uint16Array(width*height),popcount=v=>{v=v-((v>>>1)&0x5555);v=(v&0x3333)+((v>>>2)&0x3333);return (((v+(v>>>4))&0x0f0f)*0x0101>>>8)&31;};
  for(let channel=0;channel<(gray?1:3);channel++){
    coverage.fill(0);const angle=angles[gray?3:channel]*.0174532925199433,cs=Math.cos(angle),sn=Math.sin(angle),corners=[[0,0],[width,0],[0,height],[width,height]],us=corners.map(([x,y])=>(x*cs+y*sn)/cell),vs=corners.map(([x,y])=>(-x*sn+y*cs)/cell);
    for(let j=Math.floor(Math.min(...vs))-1;j<=Math.ceil(Math.max(...vs))+1;j++)for(let i=Math.floor(Math.min(...us))-1;i<=Math.ceil(Math.max(...us))+1;i++){
      const cx=((i+.5)*cs-(j+.5)*sn)*cell,cy=((i+.5)*sn+(j+.5)*cs)*cell;let darkness=0,alpha=0;
      for(let yy=0;yy<4;yy++)for(let xx=0;xx<4;xx++){const u=((xx+.5)/4-.5)*cell,v=((yy+.5)/4-.5)*cell,x=limit(Math.floor(cx+u*cs-v*sn),0,width-1),y=limit(Math.floor(cy+u*sn+v*cs),0,height-1),at=(y*width+x)*4,a=source[at+3]/255,value=gray?.2126*source[at]+.7152*source[at+1]+.0722*source[at+2]:source[at+channel];darkness+=(255-value)*a;alpha+=source[at+3];}
      const tone=alpha?limit(darkness/alpha,0,1):0;if(!tone)continue;
      const radius=shape==='Square'?Math.sqrt(tone)*cell/2:shape==='Line'?tone*cell/2:radii[Math.round(tone*255)]*cell,halfU=shape==='Line'?cell/2:radius,reach=shape==='Round'?radius:halfU*Math.abs(cs)+radius*Math.abs(sn),reachY=shape==='Round'?radius:halfU*Math.abs(sn)+radius*Math.abs(cs);
      for(let y=Math.max(0,Math.floor(cy-reachY-1));y<=Math.min(height-1,Math.ceil(cy+reachY+1));y++)for(let x=Math.max(0,Math.floor(cx-reach-1));x<=Math.min(width-1,Math.ceil(cx+reach+1));x++){
        const index=y*width+x;if(coverage[index]===65535)continue;const dx=x+.5-cx,dy=y+.5-cy,u=dx*cs+dy*sn,v=-dx*sn+dy*cs;
        if(shape==='Round'){const d2=dx*dx+dy*dy;if(radius>=.531&&d2<=(radius-.531)**2){coverage[index]=65535;continue;}if(d2>(radius+.531)**2)continue;}
        else if(Math.abs(u)<=halfU-.531&&Math.abs(v)<=radius-.531){coverage[index]=65535;continue;}
        for(let sy=0;sy<4;sy++)for(let sx=0;sx<4;sx++){const px=dx+(sx+.5)/4-.5,py=dy+(sy+.5)/4-.5,inside=shape==='Round'?px*px+py*py<=radius*radius:Math.abs(px*cs+py*sn)<=halfU&&Math.abs(-px*sn+py*cs)<=radius;if(inside)coverage[index]|=1<<(sy*4+sx);}
      }
    }
    for(let i=0;i<width*height;i++)if(source[i*4+3])for(let c=gray?0:channel;c<(gray?3:channel+1);c++)data[i*4+c]=Math.round(source[i*4+c]*(1-strength)+(1-popcount(coverage[i])/16)*255*strength);
  }
  return {width,height,data};
}
