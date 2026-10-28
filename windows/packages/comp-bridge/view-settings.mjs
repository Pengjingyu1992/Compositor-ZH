export const VIEW_OPTION_KEYS=['grid','snap','rulers','navigator','palette','gridSpacing','gridSubdivisions','gridColor','gridOpacity','rulerUnit'];
export const DEFAULT_VIEW_SETTINGS=Object.freeze({appearance:'system',grid:false,snap:false,rulers:false,navigator:false,palette:false,gridSpacing:10,gridSubdivisions:1,gridColor:'#ffffff',gridOpacity:25,rulerUnit:'px',foreground:'#bae9d6',background:'#ffffff',swatches:Object.freeze(['#000000','#ffffff','#808080','#e54c4c','#ed9c3c','#f0d84b','#59b867','#3bbeb4','#4a8cdd','#785bcb','#b657b7','#ed9db9'])});
export const validHex=value=>typeof value==='string'&&/^#[0-9a-f]{6}$/i.test(value);
export function validateViewSettings(value){
  // Older workspace records have every original field but no appearance key.
  if(value&&typeof value==='object'&&!Array.isArray(value)&&!Object.hasOwn(value,'appearance'))value={...value,appearance:'system'};
  const finite=(n,a,b)=>typeof n==='number'&&Number.isFinite(n)&&n>=a&&n<=b;
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==Object.keys(DEFAULT_VIEW_SETTINGS).length||Object.keys(value).some(key=>!Object.hasOwn(DEFAULT_VIEW_SETTINGS,key))||!['system','light','dark'].includes(value.appearance)||!['grid','snap','rulers','navigator','palette'].every(key=>typeof value[key]==='boolean')||!finite(value.gridSpacing,1,30000)||!Number.isInteger(value.gridSubdivisions)||!finite(value.gridSubdivisions,1,100)||!validHex(value.gridColor)||!finite(value.gridOpacity,0,100)||!['px','in','cm'].includes(value.rulerUnit)||!validHex(value.foreground)||!validHex(value.background)||!Array.isArray(value.swatches)||value.swatches.length>64||!value.swatches.every(validHex)){const error=new Error('invalid');error.code='invalid';throw error;}
  return {...value,swatches:[...value.swatches]};
}
export const rgbToHex=values=>'#'+values.map(v=>Math.round(Math.max(0,Math.min(255,v))).toString(16).padStart(2,'0')).join('');
export const hexToRGB=value=>validHex(value)?[1,3,5].map(i=>parseInt(value.slice(i,i+2),16)):[0,0,0];
export function rgbToHSV(rgb){const [r,g,b]=rgb.map(v=>v/255),high=Math.max(r,g,b),low=Math.min(r,g,b),delta=high-low;let h=0;if(delta)h=high===r?((g-b)/delta)%6:high===g?(b-r)/delta+2:(r-g)/delta+4;return[(h*60+360)%360,high?delta/high*100:0,high*100];}
export function hsvToRGB(hsv){let[h,s,v]=hsv;h=((h%360)+360)%360;s=Math.max(0,Math.min(100,s))/100;v=Math.max(0,Math.min(100,v))/100;const chroma=v*s,x=chroma*(1-Math.abs(h/60%2-1)),m=v-chroma,values=h<60?[chroma,x,0]:h<120?[x,chroma,0]:h<180?[0,chroma,x]:h<240?[0,x,chroma]:h<300?[x,0,chroma]:[chroma,0,x];return values.map(value=>Math.round((value+m)*255));}
export function rulerTicks(length,zoom,start=0,visible=length){
  const target=80/zoom,power=10**Math.floor(Math.log10(target)),major=[1,2,5,10].map(value=>value*power).find(value=>value>=target),minor=major/5,ticks=[];
  for(let index=Math.max(0,Math.floor(start/minor));index*minor<=Math.min(length,start+visible);index++){const position=index*minor;ticks.push({position,major:index%5===0});if(ticks.length>2000)break;}return ticks;
}
