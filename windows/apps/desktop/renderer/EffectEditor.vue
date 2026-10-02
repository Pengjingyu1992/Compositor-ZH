<script setup lang="ts">
const props=defineProps<{value:Record<string,Record<string,any>>;zh:boolean;disabled:boolean;names:readonly string[]}>();
const emit=defineEmits<{edit:[op:Record<string,unknown>]}>();
const keys=['stroke','shadow','colorOverlay','innerShadow','outerGlow','innerGlow'];
const fields=(key:string)=>['red','green','blue','opacity',...(key.includes('hadow')?['angle','distance','blur']:key==='colorOverlay'?[]:['size'])];
const labels:Record<string,string[]>= {red:['红','Red'],green:['绿','Green'],blue:['蓝','Blue'],opacity:['不透明度','Opacity'],angle:['角度','Angle'],distance:['距离','Distance'],blur:['模糊','Blur'],size:['大小','Size']};
function change(effect:string,field:string,e:Event){emit('edit',{effect,field,value:Number((e.target as HTMLInputElement).value)});}
</script>
<template>
  <div class="parameter-form"><details v-for="(effect,i) in keys.filter(k=>value[k])" :key="effect" open><summary>{{ names[keys.indexOf(effect)] }}</summary><label><input type="checkbox" :disabled="disabled" :checked="value[effect].enabled!==false" @change="emit('edit',{effect,field:'enabled',value:($event.target as HTMLInputElement).checked})">{{ zh?'启用':'Enabled' }}</label><label v-for="field in fields(effect)" :key="field">{{ labels[field][zh?0:1] }}<input type="number" :disabled="disabled" :value="value[effect][field]??0" :min="field==='angle'?-360:0" :max="['red','green','blue','opacity'].includes(field)?1:field==='angle'?360:field==='distance'?5000:500" :step="['red','green','blue','opacity'].includes(field)?.01:1" @change="change(effect,field,$event)"></label><label v-if="effect==='stroke'"><input type="checkbox" :disabled="disabled" :checked="value[effect].inside" @change="emit('edit',{effect,field:'inside',value:($event.target as HTMLInputElement).checked})">{{ zh?'内描边':'Inside stroke' }}</label><button :disabled="disabled" @click="emit('edit',{effect,remove:true})">{{ zh?'移除':'Remove' }}</button></details></div>
</template>
