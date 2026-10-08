import { app, BrowserWindow, Menu, dialog, ipcMain, protocol, clipboard, ClipboardItem, nativeImage } from 'electron';
import { readFile, lstat, open, rename, rm } from 'node:fs/promises';
import { Worker } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getLanguage, setLanguage } from '../../../packages/platform/preferences.mjs';
import { ProjectSession } from '../../../packages/platform/project-session.mjs';
import { compatibilityReport } from '../../../packages/platform/compatibility-report.mjs';
import { RecoveryStore, recoverSaves, fingerprint } from '../../../packages/platform/save-project.mjs';
import { safeDirectory, safeRead, readProject, jpegDimensions, ProjectError, LIMITS } from '../../../packages/comp-bridge/project.mjs';
import { registerAiAssistant } from './ai-assistant.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const RENDERER = path.join(ROOT, 'out', 'renderer');
const HOME = 'compositor://app/index.html';
protocol.registerSchemesAsPrivileged([{ scheme: 'compositor', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);
app.setName('Compositor Windows');
app.setAppUserModelId('org.compositorzh.windows');
app.setPath('userData', path.join(app.getPath('appData'), 'Compositor-Windows'));
if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
let win, language = 'zh-Hans';
const codecs = createRequire(import.meta.url)(path.join(ROOT, 'out/codecs/index.cjs'));
const recovery = new RecoveryStore(path.join(app.getPath('userData'), 'recovery'));
const journalDirectory = path.join(app.getPath('userData'), 'save-journals');
const session = new ProjectSession(readProject, { codecs, recovery, journalDirectory });
let closing = false, closePending = false;
let preferenceQueue = Promise.resolve();
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };
const headers = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-src 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'no-store'
};
app.on('second-instance', () => { if (win?.isMinimized()) win.restore(); win?.focus(); });
function allowedSender(event) {
  return win && event.sender === win.webContents && event.senderFrame === win.webContents.mainFrame && event.senderFrame.url === HOME;
}
function handler(name, fn) {
  ipcMain.handle(name, async (event, ...args) => {
    if (!allowedSender(event)) throw new Error('Unauthorized caller');
    return fn(...args);
  });
}
function nativeMenu() {
  const zh = language === 'zh-Hans';
  win?.setTitle((zh ? '叠绘 · Windows' : 'Compositor · Windows') + (session.isDirty() ? ' *' : ''));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: zh ? '文件' : 'File', submenu: [
      { id: 'file-new', label: zh ? '新建画布…' : 'New canvas…', accelerator: 'Ctrl+N', click: () => win?.webContents.send('editor:new') },
      { id: 'file-open', label: zh ? '打开项目…' : 'Open project…', accelerator: 'Ctrl+O', click: () => win?.webContents.send('viewer:open') },
      { id: 'file-image', label: zh ? '导入图像…' : 'Import image…', click: () => win?.webContents.send('editor:image') },
      { id: 'file-import-psd', label: zh ? '导入 PSD…' : 'Import PSD…', click: () => win?.webContents.send('editor:importPSD') },
      { id: 'file-save', label: zh ? '保存' : 'Save', accelerator: 'Ctrl+S', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('editor:save') },
      { id: 'file-save-as', label: zh ? '另存为…' : 'Save As…', accelerator: 'Ctrl+Shift+S', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('editor:saveAs') },
      { id: 'file-export-png', label: zh ? '导出 PNG…' : 'Export PNG…', click: () => win?.webContents.send('editor:png') },
      { id: 'file-export-psd', label: zh ? '导出 PSD…' : 'Export PSD…', click: () => win?.webContents.send('editor:exportPSD') },
      { id: 'file-recover', label: zh ? '恢复未保存项目…' : 'Recover unsaved project…', click: () => win?.webContents.send('editor:recover') },
      { id: 'file-reload', label: zh ? '重新加载项目' : 'Reload project', accelerator: 'Ctrl+R', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('viewer:reload') },
      { id: 'file-close', label: zh ? '关闭项目' : 'Close project', accelerator: 'Ctrl+W', enabled: !!session.current || session.pending, click: () => win?.webContents.send('viewer:close') },
      { type: 'separator' }, { label: zh ? '退出' : 'Quit', role: 'quit' }
    ] },
    { label: zh ? '编辑' : 'Edit', submenu: [
      { label: zh ? '撤销' : 'Undo', accelerator: 'Ctrl+Z', enabled: !!session.undoStack.length && !session.pending, click: () => win?.webContents.send('editor:undo') },
      { label: zh ? '重做' : 'Redo', accelerator: 'Ctrl+Shift+Z', enabled: !!session.redoStack.length && !session.pending, click: () => win?.webContents.send('editor:redo') },
      { type: 'separator' }, ...[['cut','剪切','Cut','Ctrl+X'],['copy','复制','Copy','Ctrl+C'],['copyMerged','合并复制','Copy merged','Ctrl+Shift+C'],['paste','粘贴','Paste','Ctrl+V']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,click:()=>win?.webContents.send('editor:'+name)}))
    ] },
    { label: zh ? '显示' : 'View', submenu: [
      { label: zh ? '适合窗口' : 'Fit to window', accelerator: 'Ctrl+0', click: () => win?.webContents.send('viewer:fit') },
      { label: '100%', accelerator: 'Ctrl+1', click: () => win?.webContents.send('viewer:actual') },
      ...[['grid','网格','Grid'],['snap','吸附','Snap']].map(([name,cn,en])=>({label:zh?cn:en,click:()=>win?.webContents.send('editor:'+name)})),
      { label: zh ? '全屏' : 'Full screen', role: 'togglefullscreen' }
    ] },
    { label:zh?'选择':'Select',submenu:[['selectAll','全选','Select all','Ctrl+A'],['deselect','取消选区','Deselect','Ctrl+D'],['invertSelection','反选','Invert selection','Ctrl+Shift+I'],['expandSelection','扩展选区','Expand selection'],['contractSelection','收缩选区','Contract selection'],['featherSelection','羽化选区','Feather selection'],['fill','填充前景色','Fill foreground'],['clear','清除','Clear'],['selectionMask','选区转蒙版','Selection to mask']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,enabled:!!session.current,click:()=>win?.webContents.send('editor:'+name)})) },
    { label:zh?'图像':'Image',submenu:[['canvasSize','画布尺寸…','Canvas size…'],['imageSize','图像尺寸…','Image size…'],['cropSelection','裁剪到选区','Crop to selection'],['trim','修剪透明边缘','Trim transparent edges'],['flipCanvasH','水平翻转画布','Flip canvas horizontally'],['flipCanvasV','垂直翻转画布','Flip canvas vertically']].map(([name,cn,en])=>({label:zh?cn:en,enabled:!!session.current,click:()=>win?.webContents.send('editor:'+name)})) },
    { label: zh ? '图层' : 'Layer', submenu: [
      { id: 'layer-new', label: zh ? '新建像素层' : 'New pixel layer', click: () => win?.webContents.send('editor:addPixels') },
      { id: 'layer-group', label: zh ? '新建组' : 'New group', click: () => win?.webContents.send('editor:addGroup') },
      { id: 'layer-mask', label: zh ? '添加蒙版' : 'Add mask', click: () => win?.webContents.send('editor:addMask') },
      { type: 'separator' },
      ...[['text','新建文字／编辑文字…','New / edit text…'],['shape','新建形状／编辑形状…','New / edit shape…'],['group','编组','Group','Ctrl+G'],['ungroup','解组','Ungroup','Ctrl+Shift+G'],['duplicate','复制图层','Duplicate layers'],['delete','删除图层','Delete layers'],['merge','合并所选图层','Merge selected layers'],['flatten','拼合图像','Flatten image'],['rasterize','栅格化','Rasterize'],['applyMask','应用蒙版','Apply mask']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,enabled:!!session.current,click:()=>win?.webContents.send('editor:'+name)})),
      { type: 'separator' },
      { label: zh ? '图层属性' : 'Layer properties', click: () => win?.webContents.send('editor:properties') },
      { label: zh ? '图层效果' : 'Layer effects', click: () => win?.webContents.send('editor:effects') }
    ] },
    {label:zh?'滤镜':'Filter',submenu:[{label:zh?'滤镜图库…':'Filter gallery…',enabled:!!session.current,click:()=>win?.webContents.send('editor:filter')}]},
    { label: zh ? '帮助' : 'Help', submenu: [
      { id: 'project-details', label: zh ? '项目详情与兼容性' : 'Project details and compatibility', click: () => win?.webContents.send('editor:details') }
    ] }
  ]));
}
async function projectRequest(start) {
  const pending = start();
  nativeMenu();
  try { return await pending; } finally { nativeMenu(); }
}
async function chooseSave(current, as) {
  if (!as && current.location) return { location: current.location, expected: current.fingerprint };
  const selected = await dialog.showSaveDialog(win, { title: language === 'en' ? 'Save project folder' : '保存项目文件夹', defaultPath: current.data.name, filters: [{ name: 'Compositor project folder', extensions: ['comp'] }] });
  if (selected.canceled || !selected.filePath) return null;
  let expected = null;
  try {
    const st = await lstat(selected.filePath);
    if (!st.isDirectory() || st.isSymbolicLink()) throw new ProjectError('path');
    expected = fingerprint(await readProject(selected.filePath));
    if ((await dialog.showMessageBox(win, { type: 'warning', buttons: language === 'en' ? ['Cancel', 'Replace with backup'] : ['取消', '备份后替换'], defaultId: 0, cancelId: 0, message: language === 'en' ? 'Replace this existing project? A complete backup will be retained beside it.' : '替换已有项目？原项目的完整备份会保留在同一文件夹中。' })).response !== 1) return null;
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
  return { location: selected.filePath, expected };
}
async function clearRecovery() {
  clearTimeout(session.recoveryTimer);
  if (session.current) try { await recovery.clear(session.current.data.manifest.documentID); } catch { /* Keep the snapshot if cleanup fails; this must not block quitting. */ }
}
async function canLeave() {
  if (session.pending) return false;
  if (!session.isDirty()) return true;
  session.pending = true;
  let choice;
  try { choice = await dialog.showMessageBox(win, { type: 'warning', message: language === 'en' ? 'Save changes before leaving this project?' : '离开项目前保存修改？', buttons: language === 'en' ? ['Cancel', 'Discard', 'Save'] : ['取消', '放弃修改', '保存'], defaultId: 2, cancelId: 0 }); }
  finally { session.pending = false; }
  if (choice.response === 0) return false;
  if (choice.response === 1) { await clearRecovery(); return true; }
  const result = await session.save(session.current.id, session.revision, c => chooseSave(c, false));
  return !!result.project && !result.error;
}
async function writeExport(destination, bytes) {
  if (bytes.length > LIMITS.encoded) throw new ProjectError('limit');
  const parent = await safeDirectory(path.dirname(destination)), target = path.join(parent, path.basename(destination)), temp = path.join(parent, `.compositor-export-${randomUUID()}`);
  try { const st = await lstat(target); if (!st.isFile() || st.isSymbolicLink()) throw new ProjectError('path'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const h = await open(temp, 'wx'); try { await h.writeFile(bytes); await h.sync(); } finally { await h.close(); }
  try { await rename(temp, target); } catch { await rm(temp, { force: true }); throw new ProjectError('occupied'); }
}
// Return from the ESM entry point before waiting for readiness. In particular,
// Playwright's loader delays ready until the bootstrap has finished importing.
app.whenReady().then(async () => {
language = await getLanguage(app.getPath('userData'));
const recoveredSaves = await recoverSaves(journalDirectory);
protocol.handle('compositor', async request => {
  try {
    const url = new URL(request.url);
    if (request.method !== 'GET') return new Response(null, { status: 405 });
    if (url.host === 'app' && url.pathname.startsWith('/project/')) {
      const [id, index, ...extra] = url.pathname.slice('/project/'.length).split('/');
      if (!session.current || id !== session.current.id || (url.searchParams.has('revision') && url.searchParams.get('revision') !== session.revision) || !/^(0|[1-9][0-9]*)$/.test(index) || extra.length) return new Response(null, { status: 404 });
      const resource = session.current.resources[Number(index)];
      if (!resource) return new Response(null, { status: 404 });
      return new Response(new Uint8Array(resource.bytes), { headers: { ...headers, 'Content-Type': resource.mime } });
    }
    if (url.host !== 'app') return new Response(null, { status: 404 });
    const relative = decodeURIComponent(url.pathname).replace(/^\//, '');
    if (!relative || relative.split(/[\\/]/).some(part => part === '..' || part === '.') || relative.includes(':')) return new Response(null, { status: 403 });
    const location = path.resolve(RENDERER, relative);
    if (!location.startsWith(RENDERER + path.sep)) return new Response(null, { status: 403 });
    return new Response(new Uint8Array(await readFile(location)), { headers: { ...headers, 'Content-Type': mime[path.extname(location)] ?? 'application/octet-stream' } });
  } catch { return new Response(null, { status: 404 }); }
});
win = new BrowserWindow({
  width: 1250, height: 820, minWidth: 850, minHeight: 580, backgroundColor: '#18191c',
  webPreferences: { preload: path.join(ROOT, 'apps/desktop/preload/index.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true, webSecurity: true, spellcheck: false }
});
win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
win.webContents.on('will-navigate', (event, url) => { if (url !== HOME) event.preventDefault(); });
win.webContents.on('will-attach-webview', event => event.preventDefault());
win.on('close', event => {
  if (closing) return;
  event.preventDefault(); if (closePending) return; closePending = true;
  const waitForIdle = async () => { while (session.pending) await new Promise(resolve => setTimeout(resolve, 100)); return canLeave(); };
  waitForIdle().then(async ok => { if (ok) { await clearRecovery(); closing = true; win.close(); } }).catch(() => {}).finally(() => closePending = false);
});
win.on('closed', () => { session.close(); win = null; });
app.on('window-all-closed', () => app.quit());
handler('viewer:settings', () => ({ language, version: app.getVersion() }));
handler('viewer:language', async value => {
  if (!['en', 'zh-Hans'].includes(value)) throw new Error('Invalid language');
  preferenceQueue = preferenceQueue.catch(() => {}).then(() => setLanguage(app.getPath('userData'), value));
  await preferenceQueue; language = value; nativeMenu();
  return { language };
});
handler('viewer:open', async () => { if (!(await canLeave())) return { canceled: true }; return projectRequest(() => session.open(async () => {
    const result = await dialog.showOpenDialog(win, { title: language === 'en' ? 'Select a .comp project folder' : '选择 .comp 项目文件夹', properties: ['openDirectory'], buttonLabel: language === 'en' ? 'Open project' : '打开项目' });
    return result.canceled ? null : result.filePaths[0];
})); });
handler('viewer:drop', async location => {
  if (typeof location !== 'string' || !path.isAbsolute(location) || location.length > 32768 || path.extname(location).toLowerCase() !== '.comp') return { error: 'path' };
  if (!(await canLeave())) return { canceled: true }; return projectRequest(() => session.open(() => location));
});
handler('viewer:reload', async id => { if (!(await canLeave())) return { canceled: true }; return projectRequest(() => session.reload(id)); });
handler('viewer:close', async () => { if (!(await canLeave())) return { closed: false }; await clearRecovery(); const result = session.close(); nativeMenu(); return result; });
handler('editor:new', async (w, h) => { if (!(await canLeave())) return { canceled: true }; return projectRequest(() => Promise.resolve(session.create(w, h))); });
function buildEdit(data,op) {
  return new Promise((resolve,reject)=>{
    const worker=new Worker(new URL('../../../packages/platform/edit-worker.mjs',import.meta.url),{workerData:{data:{manifest:data.manifest,resources:data.resources,sourceBytes:data.sourceBytes,name:data.name,preview:data.preview,analysis:data.analysis,selection:data.selection,locks:data.locks},op,codecPath:path.join(ROOT,'out/codecs/index.cjs')}});
    const timer=setTimeout(()=>{worker.terminate();reject(new ProjectError('limit'));},30000);
    worker.once('message',r=>{clearTimeout(timer);worker.terminate();if(r.error)reject(new ProjectError(r.error));else resolve(r.data);});worker.once('error',()=>{clearTimeout(timer);reject(new ProjectError('invalid'));});
  });
}
handler('editor:edit', (id,revision,op)=>{
  const heavy=o=>['stroke','fill','gradient','bucket','filter','imageSize','applyMask','selectionMask'].includes(o?.kind)||o?.kind==='selection'||(o?.kind==='batch'&&Array.isArray(o.operations)&&o.operations.some(heavy));
  return projectRequest(async()=>{const result=heavy(op)?await session.editAsync(id,revision,op,buildEdit):session.edit(id,revision,op);nativeMenu();return result;});
});
handler('editor:clipboard',async(id,revision,action,png)=>{
  if(session.pending)return {error:'busy'};if(!session.current||session.current.id!==id||session.revision!==revision)return {error:'stale'};
  const owner=session.current;session.pending=true;nativeMenu();
  try {if(action==='copy'){const resource=codecs.validatePNG(png);await clipboard.write([new ClipboardItem({'image/png':new Blob([new Uint8Array(resource.bytes)],{type:'image/png'})})]);return {copied:true};}
    if(action!=='paste')return {error:'invalid'};const items=await clipboard.read(),item=items.find(i=>i.types.includes('image/png')||i.types.includes('image/jpeg'));if(!item)return {error:'asset'};const type=item.types.includes('image/png')?'image/png':'image/jpeg',blob=await item.getType(type);if(blob.size>LIMITS.asset)return {error:'limit'};
    let bytes=Buffer.from(await blob.arrayBuffer());if(type==='image/jpeg'){jpegDimensions(bytes);const image=nativeImage.createFromBuffer(bytes);if(image.isEmpty())return {error:'asset'};bytes=image.toPNG();}
    if(session.current!==owner||session.revision!==revision)return {error:'stale'};session.pending=false;
    return session.edit(id,revision,{kind:'importPixels',name:language==='en'?'Pasted image':'粘贴图像',png:new Uint8Array(bytes)});
  }catch(e){return {error:e.code??'invalid'};}finally{session.pending=false;nativeMenu();}
});
handler('editor:textClipboard',action=>{if(!['copy','cut','paste','selectAll'].includes(action))return;win.webContents[action]();});
handler('editor:history', (id, revision, dir) => { const result = session.history(id, revision, dir); nativeMenu(); return result; });
handler('editor:save', (id, revision, as) => projectRequest(() => session.save(id, revision, c => chooseSave(c, as === true))));
handler('editor:image', async (id, revision) => {
  if (!session.current || session.current.id !== id || session.revision !== revision || session.pending) return { error: 'stale' };
  session.pending = true;
  try {
    const choice = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Image', extensions: ['png', 'jpg', 'jpeg'] }] }); if (choice.canceled) return { canceled: true };
    await safeDirectory(path.dirname(choice.filePaths[0])); let b = await safeRead(choice.filePaths[0], LIMITS.asset);
    if (path.extname(choice.filePaths[0]).toLowerCase() !== '.png') { jpegDimensions(b); const image = nativeImage.createFromBuffer(b); if (image.isEmpty()) throw new ProjectError('asset'); b = image.toPNG(); }
    if (session.current.id !== id || session.revision !== revision) return { error: 'stale' };
    session.pending = false; return session.edit(id, revision, { kind: 'importPixels', png: new Uint8Array(b), name: path.basename(choice.filePaths[0]).slice(0, 256) });
  } catch (e) { return { error: e.code ?? 'asset' }; } finally { session.pending = false; nativeMenu(); }
});
handler('editor:importPSD', async () => {
  if (!(await canLeave())) return { canceled: true }; session.pending = true; const own = session.generation;
  try {
    const choice = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Photoshop', extensions: ['psd'] }] }); if (choice.canceled) return { canceled: true };
    await safeDirectory(path.dirname(choice.filePaths[0])); const b = await safeRead(choice.filePaths[0], LIMITS.asset);
    let result;
    try { result = codecs.importPSD(new Uint8Array(b)); }
    catch (e) {
      if (e.code !== 'psdConversion') throw e;
      const answer = await dialog.showMessageBox(win, { type: 'warning', buttons: language === 'en' ? ['Cancel', 'Import saved composite'] : ['取消', '导入保存的合成图'], defaultId: 0, cancelId: 0, message: language === 'en' ? 'Some PSD features cannot be mapped accurately. Importing the saved composite creates one raster layer and loses editable layers.' : '部分 PSD 属性无法准确映射。导入保存的合成图会转换成一个像素层，原图层不再可编辑。' });
      if (answer.response !== 1) return { canceled: true }; result = codecs.importPSD(new Uint8Array(b), true);
    }
    if (own !== session.generation) return { canceled: true }; session.generation++;
    const view = session.install(result.data); session.scheduleRecovery(); return { ...view, warnings: result.warnings };
  } catch (e) { return { error: e.code ?? 'psdFormat' }; } finally { session.pending = false; nativeMenu(); }
});
handler('editor:export', async (id, revision, type, payload) => {
  if (!session.current || session.current.id !== id || session.revision !== revision || session.pending) return { error: 'stale' };
  if (!['png', 'psd'].includes(type) || session.current.data.analysis.issues.length) return { error: 'unsupported' };
  session.pending = true;
  try {
    const choice = await dialog.showSaveDialog(win, { filters: [{ name: type.toUpperCase(), extensions: [type] }], defaultPath: `Export.${type}` }); if (choice.canceled || !choice.filePath) return { canceled: true };
    if (session.current.id !== id || session.revision !== revision) return { error: 'stale' };
    const bytes = type === 'png' ? codecs.validatePNG(payload.composite).bytes : codecs.exportPSD(session.current.data, payload);
    await writeExport(choice.filePath, bytes); return { exported: true };
  } catch (e) { return { error: e.code ?? 'write' }; } finally { session.pending = false; nativeMenu(); }
});
handler('editor:recover', async () => {
  if (!(await canLeave())) return { canceled: true }; const items = await recovery.list(); if (!items.length) return { error: 'noRecovery' };
  const choice = await dialog.showMessageBox(win, { type: 'question', message: language === 'en' ? 'Restore the most recent unsaved snapshot?' : '恢复最近一次未保存的副本？', detail: items[0].name, buttons: language === 'en' ? ['Cancel', 'Restore'] : ['取消', '恢复'], defaultId: 1, cancelId: 0 }); if (choice.response !== 1) return { canceled: true };
  if (session.pending) return { error: 'busy' }; session.pending = true; const own = session.generation;
  try { const data = await recovery.restore(items[0].key); if (own !== session.generation) return { canceled: true }; session.generation++; return session.install(data); }
  catch (e) { return { error: e.code ?? 'read' }; } finally { session.pending = false; nativeMenu(); }
});
handler('viewer:report', async (id, display) => {
  if (!session.current || session.current.id !== id || session.pending) return { error: 'stale' };
  await clipboard.writeText(JSON.stringify(compatibilityReport(session.current.data, app.getVersion(), display), null, 2));
  return { copied: true };
});
// The directory is a parameter so automated checks can point it at a temporary
// folder. Without that, a check that saves an endpoint would overwrite the real
// settings of the machine it runs on, because APPDATA in the environment does
// not move Electron's user-data directory.
registerAiAssistant({
  handler,
  directory: process.env.COMPOSITOR_AI_DIRECTORY || app.getPath('userData')
});
nativeMenu();
await win.loadURL(HOME);
if (recoveredSaves.includes('manual')) await dialog.showMessageBox(win, { type: 'warning', message: language === 'en' ? 'An interrupted save needs manual attention. The original or its backup has been retained.' : '有一次中断的保存需要人工处理。原项目或完整备份已保留。' });
}).catch(() => {
  dialog.showErrorBox('Compositor Windows', '无法启动应用。请完整解压安装包后重试。 / Unable to start. Extract the complete application package and try again.');
  app.quit();
});
