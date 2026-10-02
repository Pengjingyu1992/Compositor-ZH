const { contextBridge, ipcRenderer, webUtils } = require('electron');
const subscribe = (channel, callback) => {
  const listener = () => callback();
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};
contextBridge.exposeInMainWorld('viewer', Object.freeze({
  settings: () => ipcRenderer.invoke('viewer:settings'),
  language: value => ipcRenderer.invoke('viewer:language', value),
  open: () => ipcRenderer.invoke('viewer:open'),
  drop: file => {
    try { return ipcRenderer.invoke('viewer:drop', webUtils.getPathForFile(file)); }
    catch { return Promise.resolve({ error: 'path' }); }
  },
  reload: id => ipcRenderer.invoke('viewer:reload', id),
  close: () => ipcRenderer.invoke('viewer:close'),
  copyReport: (id, display) => ipcRenderer.invoke('viewer:report', id, display),
  onOpen: callback => subscribe('viewer:open', callback),
  onReload: callback => subscribe('viewer:reload', callback),
  onClose: callback => subscribe('viewer:close', callback),
  onFit: callback => subscribe('viewer:fit', callback),
  onActual: callback => subscribe('viewer:actual', callback)
}));
