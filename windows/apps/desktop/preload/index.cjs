const { contextBridge, ipcRenderer } = require('electron');
const subscribe = (channel, callback) => {
  const listener = () => callback();
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};
contextBridge.exposeInMainWorld('viewer', Object.freeze({
  settings: () => ipcRenderer.invoke('viewer:settings'),
  language: value => ipcRenderer.invoke('viewer:language', value),
  open: () => ipcRenderer.invoke('viewer:open'),
  fixture: () => ipcRenderer.invoke('viewer:fixture'),
  onOpen: callback => subscribe('viewer:open', callback),
  onFit: callback => subscribe('viewer:fit', callback),
  onActual: callback => subscribe('viewer:actual', callback)
}));
