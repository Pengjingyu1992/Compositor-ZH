<script setup lang="ts">
import { computed, ref } from 'vue';
const props = defineProps<{ value: Record<string, any>; zh: boolean; disabled: boolean }>();
const emit = defineEmits<{ edit: [value: Record<string, unknown>] }>();
const channel = ref(0);
const defaults: Record<string, any> = {
  levels:{channel:'RGB',ranges:Array.from({length:4},()=>({black:0,white:255,gamma:1,outputBlack:0,outputWhite:255}))},
  curves:{channel:'RGB',channels:Array.from({length:4},()=>[{x:0,y:0},{x:255,y:255}])},
  exposureSettings:{exposure:0,offset:0,gamma:1},gradientMapSettings:{shadows:{red:0,green:0,blue:0},highlights:{red:1,green:1,blue:1},reversed:false},
  grainSettings:{amount:25,size:1.5,roughness:50,seed:0},blackWhiteSettings:{reds:40,yellows:60,greens:40,cyans:60,blues:20,magentas:80,tint:false,tintHue:40,tintSaturation:20},
  colorBalanceSettings:{shadowCyanRed:0,shadowMagentaGreen:0,shadowYellowBlue:0,midCyanRed:0,midMagentaGreen:0,midYellowBlue:0,highlightCyanRed:0,highlightMagentaGreen:0,highlightYellowBlue:0,preserveLuminosity:true}
};
type Control = [string, string, string, number, number, number, number, string?];
const controls = computed<Control[]>(()=>{
  switch(props.value.kind){
    case 'Hue/Saturation': return [['hue','色相','Hue',-360,360,1,0],['saturation','饱和度','Saturation',-100,100,1,0],['lightness','明度','Lightness',-100,100,1,0]];
    case 'Exposure': return [['exposure','曝光','Exposure',-20,20,.1,0,'exposureSettings'],['offset','位移','Offset',-.5,.5,.01,0,'exposureSettings'],['gamma','伽马校正','Gamma',.01,9.99,.01,1,'exposureSettings']];
    case 'Grain': return [['amount','数量','Amount',0,100,1,25,'grainSettings'],['size','大小','Size',.5,20,.1,1.5,'grainSettings'],['roughness','粗糙度','Roughness',0,100,1,50,'grainSettings'],['seed','随机种子','Seed',0,4294967295,1,0,'grainSettings']];
    case 'Gaussian Blur':return [['blurRadius','半径','Radius',.1,250,.1,10]];
    case 'Motion Blur':return [['motionAngle','角度','Angle',-90,90,1,0],['motionDistance','距离','Distance',1,2000,1,10]];
    case 'Add Noise':return [['noiseAmount','数量','Amount',.1,400,.1,10],['noiseSeed','随机种子','Seed',0,4294967295,1,0]];
    case 'Black & White':return ['reds','yellows','greens','cyans','blues','magentas'].map((k,i)=>[k,['红色','黄色','绿色','青色','蓝色','洋红'][i],['Reds','Yellows','Greens','Cyans','Blues','Magentas'][i],-200,300,1,[40,60,40,60,20,80][i],'blackWhiteSettings']);
    case 'Color Balance':return ['shadow','mid','highlight'].flatMap((tone,i)=>['CyanRed','MagentaGreen','YellowBlue'].map((suffix,j)=>[tone+suffix,['阴影','中间调','高光'][i]+' · '+['青/红','洋红/绿','黄/蓝'][j],['Shadows','Midtones','Highlights'][i]+' · '+['Cyan/red','Magenta/green','Yellow/blue'][j],-100,100,1,0,'colorBalanceSettings'] as Control));
    default:return [];
  }
});
function change(field: string, value: unknown, path?: (string|number)[]) {
  if (path && props.value[field] === undefined) {
    const initial=structuredClone(defaults[field]);let v=initial;for(const k of path.slice(0,-1))v=v[k];v[path.at(-1)!]=value;emit('edit',{field,value:initial});
  } else emit('edit',{field,value,...(path?{path}:{})});
}
function number(c: Control,e:Event){const n=Number((e.target as HTMLInputElement).value);if(Number.isFinite(n))change(c[7]??c[0],Math.max(c[3],Math.min(c[4],n)),c[7]?[c[0]]:undefined);}
const curve = computed(()=>props.value.curves?.channels[channel.value]??defaults.curves.channels[channel.value]);
function curveClick(e:MouseEvent){if(props.disabled)return;const rect=(e.currentTarget as SVGElement).getBoundingClientRect(),x=Math.max(1,Math.min(254,Math.round((e.clientX-rect.left)/rect.width*255))),y=Math.max(0,Math.min(255,Math.round(255-(e.clientY-rect.top)/rect.height*255)));const points=curve.value.filter((p:any)=>p.x!==x).map((p:any)=>({x:p.x,y:p.y}));if(points.length>=32)return;change('curves',[...points,{x,y}].sort((a:any,b:any)=>a.x-b.x),['channels',channel.value]);}
function resetCurve(){change('curves',[{x:0,y:0},{x:255,y:255}],['channels',channel.value]);}
</script>
<template>
  <div class="parameter-form">
    <label v-for="c in controls" :key="c[0]">{{ zh ? c[1] : c[2] }}<input type="number" :disabled="disabled" :min="c[3]" :max="c[4]" :step="c[5]" :value="c[7] ? value[c[7]]?.[c[0]] ?? c[6] : value[c[0]] ?? c[6]" @change="number(c,$event)"></label>
    <label v-if="value.kind === 'Hue/Saturation'"><input type="checkbox" :disabled="disabled" :checked="value.colorize" @change="change('colorize',($event.target as HTMLInputElement).checked)">{{ zh ? '着色' : 'Colorize' }}</label>
    <template v-if="value.kind === 'Add Noise'"><label v-for="(title,k) in {noiseGaussian:zh?'高斯分布':'Gaussian',noiseMonochromatic:zh?'单色':'Monochromatic'}" :key="k"><input type="checkbox" :disabled="disabled" :checked="value[k]" @change="change(k,($event.target as HTMLInputElement).checked)">{{ title }}</label></template>
    <label v-if="value.kind === 'Color Balance'"><input type="checkbox" :disabled="disabled" :checked="value.colorBalanceSettings?.preserveLuminosity !== false" @change="change('colorBalanceSettings',($event.target as HTMLInputElement).checked,['preserveLuminosity'])">{{ zh?'保持明度':'Preserve luminosity' }}</label>
    <template v-if="value.kind === 'Levels' || value.kind === 'Curves'">
      <select v-model.number="channel" :aria-label="zh?'通道':'Channel'"><option v-for="(c,i) in (zh?['RGB','红','绿','蓝']:['RGB','Red','Green','Blue'])" :value="i">{{ c }}</option></select>
      <template v-if="value.kind === 'Levels'"><label v-for="(k,i) in ['black','gamma','white','outputBlack','outputWhite']" :key="k">{{ (zh?['输入黑场','伽马','输入白场','输出黑场','输出白场']:['Input black','Gamma','Input white','Output black','Output white'])[i] }}<input type="number" :disabled="disabled" :min="k==='gamma'?.1:0" :max="k==='gamma'?9.99:255" :step="k==='gamma'?.01:1" :value="value.levels?.ranges[channel]?.[k] ?? defaults.levels.ranges[channel][k]" @change="change('levels',Number(($event.target as HTMLInputElement).value),['ranges',channel,k])"></label></template>
      <template v-else><svg class="curve-editor" viewBox="0 0 255 255" :aria-label="zh?'点击添加曲线点':'Click to add curve points'" @click="curveClick"><path d="M0 255 L255 0" stroke="#535960" fill="none"/><polyline :points="curve.map((p:any)=>`${p.x},${255-p.y}`).join(' ')" fill="none" stroke="#b0e5cf" stroke-width="2"/><circle v-for="p in curve" :cx="p.x" :cy="255-p.y" r="3" fill="#b0e5cf"/></svg><button type="button" :disabled="disabled" @click="resetCurve">{{ zh?'重置曲线':'Reset curve' }}</button></template>
    </template>
    <template v-if="value.kind === 'Gradient Map'"><div v-for="(end,i) in ['shadows','highlights']" :key="end"><strong>{{ (zh?['暗部','亮部']:['Shadows','Highlights'])[i] }}</strong><label v-for="c in ['red','green','blue']" :key="c">{{ c.toUpperCase().slice(0,1) }}<input type="number" min="0" max="1" step=".01" :disabled="disabled" :value="value.gradientMapSettings?.[end]?.[c] ?? i" @change="change('gradientMapSettings',Number(($event.target as HTMLInputElement).value),[end,c])"></label></div><label><input type="checkbox" :disabled="disabled" :checked="value.gradientMapSettings?.reversed" @change="change('gradientMapSettings',($event.target as HTMLInputElement).checked,['reversed'])">{{ zh?'反向':'Reverse' }}</label></template>
  </div>
</template>
