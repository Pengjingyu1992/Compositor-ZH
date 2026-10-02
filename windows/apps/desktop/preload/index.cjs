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
const commands = new Set(['new', 'image', 'importPSD', 'save', 'saveAs', 'png', 'exportPSD', 'recover', 'undo', 'redo', 'addPixels', 'addGroup', 'addMask', 'details', 'properties', 'effects','selectAll','deselect','invertSelection','expandSelection','contractSelection','featherSelection','fill','clear','selectionMask','cropSelection','canvasSize','imageSize','trim','filter','group','ungroup','duplicate','delete','merge','flatten','rasterize','applyMask','text','shape','copy','copyMerged','cut','paste','flipCanvasH','flipCanvasV','grid','snap']);
contextBridge.exposeInMainWorld('editor', Object.freeze({
  clipboard: (id,revision,action,png) => ipcRenderer.invoke('editor:clipboard',id,revision,action,png),
  textClipboard: action => ipcRenderer.invoke('editor:textClipboard',action),
  create: (w, h) => ipcRenderer.invoke('editor:new', w, h),
  edit: (id, revision, op) => ipcRenderer.invoke('editor:edit', id, revision, op),
  history: (id, revision, direction) => ipcRenderer.invoke('editor:history', id, revision, direction),
  save: (id, revision, as = false) => ipcRenderer.invoke('editor:save', id, revision, as),
  importImage: (id, revision) => ipcRenderer.invoke('editor:image', id, revision),
  importPSD: () => ipcRenderer.invoke('editor:importPSD'),
  export: (id, revision, type, payload) => ipcRenderer.invoke('editor:export', id, revision, type, payload),
  recover: () => ipcRenderer.invoke('editor:recover'),
  onCommand: (name, callback) => { if (!commands.has(name)) throw new Error('Invalid command'); return subscribe(`editor:${name}`, callback); }
}));
