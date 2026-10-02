import { createWebGLCompositor, type EffectiveMode, type BlendFn } from 'pentrado/engine';
import type { LayerRow, Placement, ViewerProject } from '../../apps/desktop/renderer/types';

export const NORMAL_MODE: EffectiveMode = Object.freeze({ blend: 'normal', blendSpace: 'perceptual', compositeSpace: 'perceptual', composite: 'union', legacy: false });
const names = ['Normal','Darken','Multiply','Color Burn','Linear Burn','Lighten','Screen','Color Dodge','Linear Dodge (Add)','Overlay','Soft Light','Hard Light','Vivid Light','Linear Light','Pin Light','Hard Mix','Difference','Exclusion','Subtract','Divide','Hue','Saturation','Color','Luminosity'];
const blends: BlendFn[] = ['normal','darken','multiply','color-burn','linear-burn','lighten','screen','color-dodge','linear-dodge','overlay','soft-light','hard-light','vivid-light','linear-light','pin-light','hard-mix','difference','exclusion','subtract','divide','hue','saturation','color','luminosity'];
const mode = (name?: string): EffectiveMode => ({ ...NORMAL_MODE, blend: blends[names.indexOf(name ?? 'Normal')] ?? 'normal' });
export function makeCanvas(w: number, h: number) { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; }
const context = (c: HTMLCanvasElement) => { const x = c.getContext('2d', { willReadFrequently: true }); if (!x) throw new Error('gpu'); return x; };
export async function pngBytes(c: HTMLCanvasElement) { const b = await new Promise<Blob | null>(resolve => c.toBlob(resolve, 'image/png')); if (!b) throw new Error('asset'); return new Uint8Array(await b.arrayBuffer()); }
export async function placedImage(url: string, p: Placement, w: number, h: number) {
  const response = await fetch(url); if (!response.ok) throw new Error('asset');
  const bitmap = await createImageBitmap(await response.blob());
  try {
    const canvas = makeCanvas(w,h), ctx = context(canvas), [x,y] = p.origin, [pw,ph] = p.size;
    ctx.imageSmoothingEnabled = p.sampling !== 'Nearest'; ctx.imageSmoothingQuality = 'high';
    ctx.translate(x+pw/2,y+ph/2); ctx.rotate(p.rotation*Math.PI/180); ctx.scale(p.flipX?-1:1,p.flipY?-1:1); ctx.drawImage(bitmap,-pw/2,-ph/2,pw,ph);
    return canvas;
  } finally { bitmap.close(); }
}
export async function exportPlaced(url:string,p:Placement){
  const [w,h]=p.size,[x,y]=p.origin,angle=p.rotation*Math.PI/180,c=Math.abs(Math.cos(angle)),s=Math.abs(Math.sin(angle)),bw=w*c+h*s,bh=w*s+h*c;
  const left=Math.floor(x+w/2-bw/2),top=Math.floor(y+h/2-bh/2),right=Math.ceil(x+w/2+bw/2),bottom=Math.ceil(y+h/2+bh/2);
  if(right-left>30000||bottom-top>30000||(right-left)*(bottom-top)>16_000_000)throw new Error('limit');
  const surface=await placedImage(url,{...p,origin:[x-left,y-top]},right-left,bottom-top);
  try{return {image:await pngBytes(surface),left,top};}finally{surface.width=surface.height=1;}
}
export function createPreviewRenderer() {
  const engine = createWebGLCompositor(), worker = new Worker(new URL('./pixels-worker.ts', import.meta.url), { type: 'module' });
  let live = true, width = 0, height = 0, frame = 0, requestID = 0, lossTimer: ReturnType<typeof setTimeout> | undefined;
  const pending = new Map<number, { resolve: (v: ImageData) => void; reject: (e: Error) => void }>();
  worker.onmessage = event => { const p = pending.get(event.data.id); if (!p) return; pending.delete(event.data.id); if (event.data.error) p.reject(new Error('asset')); else { const r = event.data.result; p.resolve(new ImageData(r.data,r.width,r.height)); } };
  worker.onerror = () => { for (const p of pending.values()) p.reject(new Error('asset')); pending.clear(); };
  function process(image: ImageData, adjustment?: Record<string, unknown>, effects?: Record<string, unknown>) {
    return new Promise<ImageData>((resolve,reject) => { const id = ++requestID; pending.set(id,{resolve,reject}); worker.postMessage({id,image,adjustment,effects},[image.data.buffer]); });
  }
  function pixels(c: HTMLCanvasElement) { return context(c).getImageData(0,0,width,height); }
  function put(c: HTMLCanvasElement, data: ImageData) { context(c).putImageData(data,0,0); }
  function composite(below: HTMLCanvasElement, above: HTMLCanvasElement, blend?: string) {
    if (!live) throw new Error('stale');
    engine.beginFrame?.(); const version = ++frame;
    const input = (source: HTMLCanvasElement, key: string, blend?: string) => ({ texture: { source, rect:{x:0,y:0,w:width,h:height}, linear:false, key, version }, mode: mode(blend), opacity:1 });
    engine.composite([input(below,'below'),input(above,'above',blend)]);
    const gl = engine.getCanvas()?.getContext('webgl2') as WebGL2RenderingContext | null;
    if (!gl || gl.isContextLost()) throw new Error('gpu');
    put(below,engine.readback()); if (gl.isContextLost()) throw new Error('gpu');
  }
  const release = (c: HTMLCanvasElement) => { c.width=c.height=1; };
  return {
    async render(project: ViewerProject, output: HTMLCanvasElement, failed: () => void) {
      width=project.manifest.width; height=project.manifest.height;
      const probe = new OffscreenCanvas(1,1), gl=probe.getContext('webgl2');
      if (!gl || !gl.getExtension('EXT_color_buffer_float')) throw new Error('gpu');
      const limit=Math.min(gl.getParameter(gl.MAX_TEXTURE_SIZE),gl.getParameter(gl.MAX_RENDERBUFFER_SIZE)); gl.getExtension('WEBGL_lose_context')?.loseContext();
      if(width>limit||height>limit)throw new Error('gpu');
      output.width=width;output.height=height;
      if(!engine.init({width,height,onContextRestored:failed}))throw new Error('gpu');
      engine.getCanvas()?.addEventListener('webglcontextlost',()=>{lossTimer=setTimeout(()=>{if(live)failed();},1500);});
      const rows=project.analysis.rows, byID=new Map(rows.map(l=>[l.id.toUpperCase(),l]));
      const backdrop=makeCanvas(width,height), masks=new Map<string,Uint8ClampedArray>();
      const maskFor=async(l:LayerRow)=>{
        if(!l.maskFile)return undefined;
        if(!masks.has(l.id)){const c=await placedImage(project.urls[`images/${l.maskFile}`],l.maskLinked===false&&l.maskPlacement?l.maskPlacement:l.transform,width,height);const p=pixels(c);for(let i=0;i<p.data.length;i+=4)p.data[i]=Math.round(p.data[i]*p.data[i+3]/255);masks.set(l.id,p.data);release(c);}return masks.get(l.id);
      };
      const cover=async(c:HTMLCanvasElement,l:LayerRow,folders:boolean,opacity=1)=>{
        const p=pixels(c), own=l.maskEnabled===false?undefined:await maskFor(l), parents:Uint8ClampedArray[]=[];
        if(folders){let id=l.parentID,depth=0;while(id&&depth++<64){const parent=byID.get(id.toUpperCase());if(!parent)break;const mask=parent.maskEnabled===false?undefined:await maskFor(parent);if(mask)parents.push(mask);id=parent.parentID;}}
        for(let i=0;i<p.data.length;i+=4){let alpha=opacity*(own?own[i]/255:1);for(const mask of parents)alpha*=mask[i]/255;p.data[i+3]*=alpha;}put(c,p);
      };
      const own=async(l:LayerRow,folders=true)=>{
        const c=l.imageFile?await placedImage(project.urls[`images/${l.imageFile}`],l.transform,width,height):makeCanvas(width,height);
        await cover(c,l,false);
        if(l.effects&&Object.values(l.effects).some(v=>v&&typeof v==='object'&&(v as {enabled?:boolean}).enabled!==false))put(c,await process(pixels(c),undefined,l.effects));
        if(folders)await cover(c,{...l,maskFile:undefined},true,l.effectiveOpacity);return c;
      };
      const adjust=async(below:HTMLCanvasElement,l:LayerRow,folders=true)=>{
        const original=pixels(below),changed=await process(pixels(below),l.adjustment),candidate=makeCanvas(width,height);put(candidate,changed);
        if((l.blendMode??'Normal')!=='Normal'){
          const opaque=makeCanvas(width,height),p=new ImageData(new Uint8ClampedArray(original.data),width,height);for(let i=3;i<p.data.length;i+=4){p.data[i]=255;changed.data[i]=255;}put(opaque,p);put(candidate,changed);composite(opaque,candidate,l.blendMode);const mixed=pixels(opaque);for(let i=3;i<mixed.data.length;i+=4)mixed.data[i]=original.data[i];put(candidate,mixed);release(opaque);
        }
        const coverage=makeCanvas(width,height),cp=new ImageData(width,height);for(let i=0;i<cp.data.length;i+=4)cp.data[i]=cp.data[i+1]=cp.data[i+2]=cp.data[i+3]=255;put(coverage,cp);await cover(coverage,l,folders,l.effectiveOpacity);const mask=pixels(coverage),result=pixels(candidate);
        for(let i=0;i<result.data.length;i+=4){const a=mask.data[i+3]/255,alpha=original.data[i+3]*(1-a)+result.data[i+3]*a;for(let c=0;c<3;c++)result.data[i+c]=alpha?(original.data[i+c]*original.data[i+3]*(1-a)+result.data[i+c]*result.data[i+3]*a)/alpha:0;result.data[i+3]=alpha;}put(below,result);release(candidate);release(coverage);
      };
      try {
        const consumed=new Set<string>();
        for(const l of rows){
          if(!live)throw new Error('stale');if(l.isGroup||!l.effectiveVisible||!l.effectiveOpacity||consumed.has(l.id))continue;
          if(l.adjustment&&!l.maskSourceID){await adjust(backdrop,l);continue;}
          const siblings=rows.filter(s=>s.parentID===l.parentID&&!s.isGroup),index=siblings.indexOf(l),clipped:LayerRow[]=[];
          if(!l.maskSourceID)for(let i=index+1;i<siblings.length&&siblings[i].maskSourceID?.toUpperCase()===l.id.toUpperCase();i++)clipped.push(siblings[i]);
          let image=await own(l,false);
          if(clipped.length){const base=pixels(image),opaque=pixels(image);for(let i=3;i<opaque.data.length;i+=4)opaque.data[i]=255;put(image,opaque);
            for(const child of clipped){consumed.add(child.id);if(!child.effectiveVisible)continue;if(child.adjustment)await adjust(image,child,false);else{const c=await own(child,false);await cover(c,{...child,maskFile:undefined},false,child.effectiveOpacity);composite(image,c,child.blendMode);release(c);}}
            const p=pixels(image);for(let i=3;i<p.data.length;i+=4)p.data[i]=base.data[i];put(image,p);
          }else if(l.maskSourceID){const src=byID.get(l.maskSourceID.toUpperCase());if(!src||src.adjustment)throw new Error('asset');const c=await own(src,false),coverage=pixels(c),p=pixels(image);for(let i=3;i<p.data.length;i+=4)p.data[i]*=coverage.data[i]/255*src.effectiveOpacity;put(image,p);release(c);}
          await cover(image,{...l,maskFile:undefined},true,l.effectiveOpacity);composite(backdrop,image,l.blendMode);release(image);
          await new Promise<void>(resolve=>setTimeout(resolve,0));
        }
        if(!live)throw new Error('stale');put(output,pixels(backdrop));
      }finally{release(backdrop);masks.clear();}
    },
    dispose(){live=false;clearTimeout(lossTimer);worker.terminate();for(const p of pending.values())p.reject(new Error('stale'));pending.clear();const surface=engine.getCanvas();engine.dispose();(surface?.getContext('webgl2') as WebGL2RenderingContext|null)?.getExtension('WEBGL_lose_context')?.loseContext();}
  };
}
