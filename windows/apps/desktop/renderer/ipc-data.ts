import { toRaw } from 'vue';

// Electron cannot clone Vue proxies. Keep binary payloads as typed arrays.
export function ipcData<T>(value:T):T {
  const raw=toRaw(value);
  if(ArrayBuffer.isView(raw)||raw instanceof ArrayBuffer)return raw;
  if(Array.isArray(raw))return raw.map(ipcData) as T;
  if(raw&&typeof raw==='object')return Object.fromEntries(Object.entries(raw).map(([key,item])=>[key,ipcData(item)])) as T;
  return raw;
}
