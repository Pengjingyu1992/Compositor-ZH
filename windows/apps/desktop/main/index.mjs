import { app, BrowserWindow, Menu, dialog, ipcMain, protocol, clipboard, ClipboardItem, nativeTheme } from 'electron';
import { canvasCreation } from '../../../packages/comp-bridge/new-canvas.mjs';
import { readFile, lstat, open, rename, rm } from 'node:fs/promises';
import { Worker } from 'node:worker_threads';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {ViewPreferences}from'../../../packages/platform/view-preferences.mjs';
import { getLanguage, setLanguage } from '../../../packages/platform/preferences.mjs';
import {RecentProjects}from'../../../packages/platform/recent-projects.mjs';
import { ProjectWorkspace } from '../../../packages/platform/project-workspace.mjs';
import { editProject, projectData,newProject } from '../../../packages/comp-bridge/edit.mjs';
import { compatibilityReport } from '../../../packages/platform/compatibility-report.mjs';
import { RecoveryStore, recoverSaves, fingerprint } from '../../../packages/platform/save-project.mjs';
import { safeDirectory, safeRead, readProject, jpegDimensions, pngDimensions, ProjectError, LIMITS } from '../../../packages/comp-bridge/project.mjs';
import { registerAiAssistant } from './ai-assistant.mjs';
import { renderEPS } from '../../../packages/platform/eps-import.mjs';
import { EPS_LIMITS } from '../../../packages/comp-bridge/eps-raster.mjs';
import { OUTPUT_FORMATS, validateCMYKProfile } from '../../../packages/platform/image-output.mjs';
import { desktopEdition } from '../../../packages/platform/desktop.mjs';
import {BatchExportRun}from'../../../packages/platform/batch-export.mjs';
import {captureLayers}from'../../../packages/platform/layer-clipboard.mjs';
import {ImageImportRun,insertImportedImage}from'../../../packages/platform/image-import.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const RENDERER = path.join(ROOT, 'out', 'renderer');
const HOME = 'compositor://app/index.html';
protocol.registerSchemesAsPrivileged([{ scheme: 'compositor', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);
const edition = desktopEdition();
app.setName(edition.name);
if (process.platform === 'win32') app.setAppUserModelId(edition.appId);
if (process.platform === 'linux') app.setDesktopName(`${edition.appId}.desktop`);
const userData = process.env.COMPOSITOR_USER_DATA_DIRECTORY;
app.setPath('userData', userData && path.isAbsolute(userData) ? userData : path.join(app.getPath('appData'), edition.directory));
if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
let win, language = 'zh-Hans';
const codecs = createRequire(import.meta.url)(path.join(ROOT, 'out/codecs/index.cjs'));
const recovery = new RecoveryStore(path.join(app.getPath('userData'), 'recovery'));
const journalDirectory = path.join(app.getPath('userData'), 'save-journals');
const viewPreferences=new ViewPreferences(app.getPath('userData'));
const workspace=new ProjectWorkspace(readProject,{codecs,recovery,journalDirectory});
let session=workspace.active;const recentProjects=new RecentProjects(app.getPath('userData'));
let batchJob;
let imageImportJob;
async function stopBatch(job=batchJob){if(!job)return;clearTimeout(job.timer);await job.run.cancel();if(batchJob===job){batchJob=undefined;job.owner.pending=false;nativeMenu();}}
function touchBatch(job){clearTimeout(job.timer);job.timer=setTimeout(()=>{void stopBatch(job).catch(()=>{});},180000);job.timer.unref();}
let rendererReady=false,pendingNativeCommand;
function sendNativeCommand(channel){if(!rendererReady){pendingNativeCommand=channel;return;}win?.webContents.send(channel);}
let closing = false, closePending = false;
let preferenceQueue = Promise.resolve();
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };
const headers = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-src 'none'",
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
    const result=await fn(...args);
    if(name==='editor:save'&&result?.didSave)workspace.seenExternal.delete(workspace.activeID);
    if(result?.project&&['viewer:open','viewer:drop','viewer:reload','editor:save','editor:workspace'].includes(name)&&session.current?.location)await recentProjects.record(session.current.location).catch(()=>{});
    return result;
  });
}
function nativeMenu() {
  const zh = language === 'zh-Hans';
  win?.setTitle(`${zh ? '叠绘' : 'Compositor'} · ${edition.label}` + (session.isDirty() ? ' *' : ''));
  const menu=Menu.buildFromTemplate([
    { label: zh ? '文件' : 'File', submenu: [
      { id: 'file-new', label: zh ? '新建画布…' : 'New canvas…', accelerator: 'Ctrl+N', click: () => sendNativeCommand('editor:new') },
      ... [['newTab','新建标签页…','New tab…','Ctrl+Alt+N'],['openTab','在新标签页打开…','Open in new tab…','Ctrl+Alt+O'],['recentProjects','最近项目…','Recent projects…'],['unlockedCopy','创建未锁定副本','Create unlocked copy'],['grayscaleCopy','创建灰度副本','Create grayscale copy']].map(([name,cn,en,accelerator])=>({id:`file-${name}`,label:zh?cn:en,accelerator,enabled:!session.pending,click:()=>sendNativeCommand(`editor:${name}`)})),
      { id: 'file-open', label: zh ? '打开项目…' : 'Open project…', accelerator: 'Ctrl+O', click: () => sendNativeCommand('viewer:open') },
      { id: 'file-image', label: zh ? '导入图像…' : 'Import image…', click: () => sendNativeCommand('editor:image') },
      { id: 'file-import-psd', label: zh ? '导入 PSD…' : 'Import PSD…', click: () => sendNativeCommand('editor:importPSD') },
      { id: 'file-save', label: zh ? '保存' : 'Save', accelerator: 'Ctrl+S', enabled: !!session.current && !session.pending, click: () => sendNativeCommand('editor:save') },
      { id: 'file-save-as', label: zh ? '另存为…' : 'Save As…', accelerator: 'Ctrl+Shift+S', enabled: !!session.current && !session.pending, click: () => sendNativeCommand('editor:saveAs') },
      { id: 'file-export-png', label: zh ? '导出 PNG…' : 'Export PNG…', click: () => sendNativeCommand('editor:png') },
      { id: 'file-export-as', label: zh ? '导出为 / 印刷预览…' : 'Export As / Print proof…', enabled: !!session.current && !session.pending, accelerator: 'Ctrl+Alt+Shift+S', click: () => sendNativeCommand('editor:exportAs') },
      {id:'file-batch-export',label:zh?'批量导出…':'Batch Export…',enabled:!!session.current&&!session.pending,click:()=>sendNativeCommand('editor:batchExport')},
      { id: 'file-export-psd', label: zh ? '导出 PSD…' : 'Export PSD…', click: () => sendNativeCommand('editor:exportPSD') },
      ...['gif', 'eps'].map(type => ({ id: `file-export-${type}`, label: zh ? `导出 ${type.toUpperCase()}…` : `Export ${type.toUpperCase()}…`, enabled: !!session.current && !session.pending, click: () => sendNativeCommand(`editor:${type}`) })),
      { id: 'file-recover', label: zh ? '恢复未保存项目…' : 'Recover unsaved project…', click: () => sendNativeCommand('editor:recover') },
      { id: 'file-reload', label: zh ? '重新加载项目' : 'Reload project', accelerator: 'Ctrl+R', enabled: !!session.current && !session.pending, click: () => sendNativeCommand('viewer:reload') },
      { id: 'file-close', label: zh ? '关闭项目' : 'Close project', accelerator: 'Ctrl+W', enabled: !!session.current || session.pending, click: () => sendNativeCommand('viewer:close') },
      { type: 'separator' }, { label: zh ? '退出' : 'Quit', role: 'quit' }
    ] },
    { label: zh ? '编辑' : 'Edit', submenu: [
      // Text fields have their own history, even when the project has no edits.
      { id: 'edit-undo', label: zh ? '撤销' : 'Undo', accelerator: 'Ctrl+Z', enabled: !session.pending, click: () => sendNativeCommand('editor:undo') },
      { id: 'edit-redo', label: zh ? '重做' : 'Redo', accelerator: 'Ctrl+Shift+Z', enabled: !session.pending, click: () => sendNativeCommand('editor:redo') },
      { type: 'separator' }, ...[['cut','剪切','Cut','Ctrl+X'],['copy','复制','Copy','Ctrl+C'],['copyMerged','合并复制','Copy merged','Ctrl+Shift+C'],['paste','粘贴','Paste','Ctrl+V']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,click:()=>sendNativeCommand('editor:'+name)}))
    ] },
    { label: zh ? '显示' : 'View', submenu: [
      { label: zh ? '适合窗口' : 'Fit to window', accelerator: 'Ctrl+0', click: () => sendNativeCommand('viewer:fit') },
      { label: '100%', accelerator: 'Ctrl+1', click: () => sendNativeCommand('viewer:actual') },
      ...[['grid','网格','Grid'],['snap','吸附','Snap']].map(([name,cn,en])=>({label:zh?cn:en,click:()=>sendNativeCommand('editor:'+name)})),
      { label: zh ? '全屏' : 'Full screen', role: 'togglefullscreen' }
    ,... [['navigator','导航缩略图','Navigator'],['rulers','标尺','Rulers'],['palette','颜色面板','Color panel'],['viewSettings','网格与标尺设置…','Grid and ruler settings…']].map(([name,cn,en])=>({id:`view-${name}`,label:zh?cn:en,click:()=>sendNativeCommand(`editor:${name}`)}))] },
    { label:zh?'选择':'Select',submenu:[['colorRange','色彩范围…','Color Range…'],['selectAll','全选','Select all','Ctrl+A'],['deselect','取消选区','Deselect','Ctrl+D'],['invertSelection','反选','Invert selection','Ctrl+Shift+I'],['expandSelection','扩展选区','Expand selection'],['contractSelection','收缩选区','Contract selection'],['featherSelection','羽化选区','Feather selection'],['fill','填充前景色','Fill foreground'],['clear','清除','Clear'],['selectionMask','选区转蒙版','Selection to mask']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,enabled:!!session.current,click:()=>sendNativeCommand('editor:'+name)})) },
    { label:zh?'图像':'Image',submenu:[['canvasSize','画布尺寸…','Canvas size…'],['imageSize','图像尺寸…','Image size…'],['cropSelection','裁剪到选区','Crop to selection'],['trim','修剪透明边缘','Trim transparent edges'],['flipCanvasH','水平翻转画布','Flip canvas horizontally'],['flipCanvasV','垂直翻转画布','Flip canvas vertically']].map(([name,cn,en])=>({label:zh?cn:en,enabled:!!session.current,click:()=>sendNativeCommand('editor:'+name)})) },
    { label: zh ? '图层' : 'Layer', submenu: [
      { id: 'layer-new', label: zh ? '新建像素层' : 'New pixel layer', click: () => sendNativeCommand('editor:addPixels') },
      { id: 'layer-group', label: zh ? '新建组' : 'New group', click: () => sendNativeCommand('editor:addGroup') },
      { id: 'layer-mask', label: zh ? '添加蒙版' : 'Add mask', click: () => sendNativeCommand('editor:addMask') },
      ...[['distort','透视／自由扭曲…','Perspective / Free Distort…'],['textOutlines','文字转轮廓','Convert text to outlines'],['newFill','新建填充图层…','New fill layer…'],['editFill','编辑填充图层…','Edit fill layer…'],['newPath','钢笔／新建路径…','Pen / New path…'],['editPath','编辑路径…','Edit path…'],['newVectorMask','新建矢量蒙版…','New vector mask…'],['editVectorMask','编辑矢量蒙版…','Edit vector mask…'],['vectorMaskFromPath','在下方图层创建矢量蒙版','Path to vector mask on layer below']].map(([name,cn,en])=>({id:`layer-${name}`,label:zh?cn:en,enabled:!!session.current&&!session.pending,click:()=>sendNativeCommand(`editor:${name}`)})),
      { type: 'separator' },
      ...[['text','新建文字／编辑文字…','New / edit text…'],['shape','新建形状／编辑形状…','New / edit shape…'],['group','编组','Group','Ctrl+G'],['ungroup','解组','Ungroup','Ctrl+Shift+G'],['duplicate','复制图层','Duplicate layers'],['delete','删除图层','Delete layers'],['merge','合并所选图层','Merge selected layers'],['flatten','拼合图像','Flatten image'],['rasterize','栅格化','Rasterize'],['applyMask','应用蒙版','Apply mask']].map(([name,cn,en,accelerator])=>({label:zh?cn:en,accelerator,enabled:!!session.current,click:()=>sendNativeCommand('editor:'+name)})),
      { type: 'separator' },
      { label: zh ? '图层属性' : 'Layer properties', click: () => sendNativeCommand('editor:properties') },
      { label: zh ? '图层效果' : 'Layer effects', click: () => sendNativeCommand('editor:effects') }
    ] },
    {label:zh?'滤镜':'Filter',submenu:[{id:'filter-repeat',label:zh?'重复上次滤镜':'Repeat last filter',accelerator:'Ctrl+Alt+F',enabled:!!session.current,click:()=>sendNativeCommand('editor:repeatFilter')},... [['refineEdges','图层修边…','Refine Layer Edges…'],['cameraRaw','Camera Raw 滤镜…','Camera Raw Filter…'],['filterStack','可编辑滤镜…','Editable filters…'],['advancedLiquify','高级液化…','Advanced Liquify…']].map(([name,cn,en])=>({id:`filter-${name}`,label:zh?cn:en,enabled:!!session.current&&!session.pending,click:()=>sendNativeCommand(`editor:${name}`)})),{label:zh?'滤镜图库…':'Filter gallery…',enabled:!!session.current,click:()=>sendNativeCommand('editor:filter')}]},
    { label: zh ? '帮助' : 'Help', submenu: [
      {id:'command-finder',label:zh?'查找命令…':'Find a command…',accelerator:'Ctrl+Shift+P',click:()=>sendNativeCommand('editor:commandFinder')},
      {label:zh?'下一个标签页':'Next tab',accelerator:'Ctrl+Tab',click:()=>sendNativeCommand('editor:tabNext')},{label:zh?'上一个标签页':'Previous tab',accelerator:'Ctrl+Shift+Tab',click:()=>sendNativeCommand('editor:tabPrevious')},
      {id:'history-panel',label:zh?'历史记录…':'History…',enabled:!!session.current,click:()=>sendNativeCommand('editor:historyPanel')},
      { id: 'project-details', label: zh ? '项目详情与兼容性' : 'Project details and compatibility', click: () => sendNativeCommand('editor:details') }
    ] }
  ]);
  if(!rendererReady){const disable=menu=>{for(const item of menu.items){if(item.submenu)disable(item.submenu);else if(item.role!=='quit')item.enabled=false;}};disable(menu);}
  Menu.setApplicationMenu(menu);
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
async function clearRecovery(target=session) {
  clearTimeout(target.recoveryTimer);
  if (target.current) try { await recovery.clear(target.current.data.manifest.documentID); } catch { /* Keep the snapshot if cleanup fails; this must not block quitting. */ }
}
async function canLeave(target=session) {
  if (target.pending) return false;
  if (!target.isDirty()) return true;
  target.pending = true;
  let choice;
  try { choice = await dialog.showMessageBox(win, { type: 'warning', message: language === 'en' ? 'Save changes before leaving this project?' : '离开项目前保存修改？', buttons: language === 'en' ? ['Cancel', 'Discard', 'Save'] : ['取消', '放弃修改', '保存'], defaultId: 2, cancelId: 0 }); }
  finally { target.pending = false; }
  if (choice.response === 0) return false;
  if (choice.response === 1) { target.discardRecoveryOnReplacement(); return true; }
  const result = await target.save(target.current.id, target.revision, c => chooseSave(c, false));
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
language = await getLanguage(app.getPath('userData'));await recentProjects.load();
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
      return new Response(new Uint8Array(resource.proxyBytes ?? resource.bytes), { headers: { ...headers, 'Content-Type': resource.mime } });
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
  width: 1250, height: 820, minWidth: 850, minHeight: 580, backgroundColor: nativeTheme.shouldUseDarkColors?'#252527':'#f5f5f7',
  icon: path.join(RENDERER, 'icon.png'),
  webPreferences: { preload: path.join(ROOT, 'apps/desktop/preload/index.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true, webSecurity: true, spellcheck: false }
});
win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
win.webContents.on('will-navigate', (event, url) => { if (url !== HOME) event.preventDefault(); });
win.webContents.on('will-attach-webview', event => event.preventDefault());
win.webContents.on('render-process-gone',()=>{imageImportJob?.run.cancel();void stopBatch().catch(()=>{});});
win.on('focus',()=>{if(rendererReady&&!workspace.busy)win.webContents.send('editor:externalCheck');});
win.on('close', event => {
  if (closing) return;
  event.preventDefault(); if (closePending) return; closePending = true;
  const waitForIdle = async () => {imageImportJob?.run.cancel();await stopBatch();while(workspace.busy)await new Promise(resolve=>setTimeout(resolve,100));for(const target of workspace.sessions)if(!(await canLeave(target)))return false;return true;};
  waitForIdle().then(async ok => { if (ok) { for(const target of workspace.sessions)await clearRecovery(target);await viewPreferences.queue.catch(()=>{});await recentProjects.queue.catch(()=>{});closing = true; win.close(); } }).catch(() => {}).finally(() => closePending = false);
});
win.on('closed', () => {for(const target of workspace.sessions)target.close(); win = null; });
app.on('window-all-closed', () => app.quit());
handler('viewer:viewSettings',async value=>{try{const settings=value===undefined?await viewPreferences.read():await viewPreferences.write(value);nativeTheme.themeSource=settings.appearance;win?.setBackgroundColor(nativeTheme.shouldUseDarkColors?'#252527':'#f5f5f7');return {settings};}catch(error){return {error:error.code??'write'};}});
handler('viewer:ready',()=>{rendererReady=true;nativeMenu();if(pendingNativeCommand){const channel=pendingNativeCommand;pendingNativeCommand=undefined;sendNativeCommand(channel);}return {};});
handler('viewer:settings', () => ({ language, version: app.getVersion(), edition: edition.id }));
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
handler('viewer:dropFiles',(records,payload)=>importImageRecords(records,payload));
handler('viewer:cancelImport',jobID=>{if(imageImportJob?.run.id===jobID)imageImportJob.run.cancel();return {};});
handler('viewer:reload', async id => { if (!(await canLeave())) return { canceled: true }; return projectRequest(() => session.reload(id)); });
handler('viewer:close',async()=>{if(!session.current)return{closed:true,workspace:workspace.state()};if(!(await canLeave()))return{closed:false};await clearRecovery();const result=workspace.close(workspace.activeID,true);session=workspace.active;nativeMenu();return{...result,workspace:workspace.state()};});
handler('editor:new', async (w, h, options = {}) => {
  try { canvasCreation(w, h, options); } catch (error) { return { error: error.code ?? 'invalid' }; }
  if (!(await canLeave())) return { canceled: true };
  return projectRequest(() => Promise.resolve(session.create(w, h, options.resolution, { ...options, backgroundName: language === 'en' ? 'Background' : '背景' })));
});
// A new-canvas view receives dimensions only: no image bytes, text, storage or network.
handler('editor:canvasClipboardSize', async () => {
  try {
    const items = await clipboard.read();
    for (const item of items.slice(0,16)) {
      if (!item.types.includes('image/png')) continue;
      const blob = await item.getType('image/png');
      const size = pngDimensions(Buffer.from(await blob.slice(0,33).arrayBuffer()),false,true);
      canvasCreation(size.width,size.height);
      return { width:size.width,height:size.height };
    }
    return null;
  }
  catch { return null; }
});
handler('editor:workspace',async(action,payload={})=>{
  if(action==='list')return {workspace:workspace.state()};
  if(action==='recent')return {recent:recentProjects.view()};
  if(['rememberRecent','clearRecent'].includes(action)){try{if(action==='rememberRecent')await recentProjects.setEnabled(payload.enabled);else await recentProjects.clear();return {recent:recentProjects.view()};}catch(error){return {error:error.code??'write'};}}
  if(!['create','open','recentOpen','switch','close','external','ignoreExternal','copy','grayscale'].includes(action))return {error:'invalid'};
  try{return await projectRequest(async()=>{
    let result;
    if(action==='create'){result=workspace.create(payload.width,payload.height,{resolution:payload.resolution,background:payload.background,backgroundName:language==='en'?'Background':'背景'});workspace.active.scheduleRecovery();}
    else if(action==='open'||action==='recentOpen'){
      workspace.guard();let location;
      if(action==='recentOpen')location=recentProjects.resolve(payload.id);
      else{const previous=session;previous.pending=true;nativeMenu();let choice;
        try{choice=await dialog.showOpenDialog(win,{title:language==='en'?'Open project in a new tab':'在新标签页打开项目',properties:['openDirectory']});}finally{previous.pending=false;}
        if(choice.canceled)return {canceled:true};location=choice.filePaths[0];
      }
      result=await workspace.open(location);
    }else if(action==='switch')result=workspace.switch(payload.tabID);
    else if(action==='close'){
      workspace.guard();const entry=workspace.entries.find(entry=>entry.id===payload.tabID);if(!entry?.session.current)return {error:'stale'};
      if(!(await canLeave(entry.session)))return {canceled:true};await clearRecovery(entry.session);result=workspace.close(payload.tabID,true);
    }else if(action==='external')return workspace.external(payload.id,payload.revision);
    else if(action==='ignoreExternal'){
      if(!session.current||session.current.id!==payload.id||session.revision!==payload.revision)return {error:'stale'};workspace.ignoreExternal(payload.signature);return {};
    }else{
      workspace.guard();if(!session.current||session.current.id!==payload.id||session.revision!==payload.revision)return {error:'stale'};
      const owner=session,current=owner.current,revision=owner.revision;let data;
      if(action==='copy'){
        const manifest=structuredClone(current.data.manifest);manifest.documentID=randomUUID().toUpperCase();data=projectData(manifest,new Map(current.data.resources),current.data.name.replace(/\.comp$/i,'')+' - Copy.comp');data.locks={};
      }else{
        owner.pending=true;nativeMenu();try{const resource=codecs.validatePNG(payload.png);if(resource.width!==current.data.manifest.width||resource.height!==current.data.manifest.height)throw new ProjectError('invalid');const png=await imageCodec('grayscaleImage',resource.bytes);if(owner.current!==current||owner.revision!==revision)throw new ProjectError('stale');data=editProject(newProject(resource.width,resource.height,current.data.manifest.resolution),{kind:'importPixels',name:language==='en'?'Grayscale copy':'灰度副本',png},codecs);data.name=current.data.name.replace(/\.comp$/i,'')+' - Gray.comp';}finally{owner.pending=false;}
      }
      result=workspace.add(data);workspace.active.scheduleRecovery();
    }
    session=workspace.active;nativeMenu();return {...result,workspace:workspace.state()};
  });}catch(error){session=workspace.active;return {error:error.code??'read'};}
});

function buildEdit(data,op) {
  return new Promise((resolve,reject)=>{
    const worker=new Worker(new URL('../../../packages/platform/edit-worker.mjs',import.meta.url),{workerData:{data:{manifest:data.manifest,resources:data.resources,sourceBytes:data.sourceBytes,name:data.name,preview:data.preview,analysis:data.analysis,selection:data.selection,locks:data.locks},op,typographyPath:path.join(ROOT,'out/typography/index.cjs'),codecPath:path.join(ROOT,'out/codecs/index.cjs')}});
    const timer=setTimeout(()=>{worker.terminate();reject(new ProjectError('limit'));},30000);
    worker.once('message',r=>{clearTimeout(timer);worker.terminate();if(r.error)reject(new ProjectError(r.error));else resolve(r.data);});worker.once('error',()=>{clearTimeout(timer);reject(new ProjectError('invalid'));});
  });
}
function imageCodec(operation, bytes, resolution, signal) {
  return new Promise((resolve, reject) => {
    if(signal?.aborted){reject(new ProjectError('canceled'));return;}
    const worker = new Worker(new URL('../../../packages/platform/image-codec-worker.mjs', import.meta.url), {
      workerData: { operation, bytes, resolution, codecPath: path.join(ROOT, 'out/codecs/index.cjs') },
      resourceLimits: { maxOldGenerationSizeMb: 256, maxYoungGenerationSizeMb: 32 }
    });
    let settled = false;
    const finish = (error, result) => {
      if (settled) return; settled = true; clearTimeout(timer);signal?.removeEventListener('abort',abort);worker.terminate();
      if (error) reject(new ProjectError(error)); else resolve(result);
    };
    const timer = setTimeout(() => finish('limit'), 30000);
    const abort=()=>finish('canceled');signal?.addEventListener('abort',abort,{once:true});
    worker.once('message', value => finish(value.error, value.result));
    worker.once('error', () => finish('asset'));
    worker.once('exit', () => { if (!settled) finish('asset'); });
  });
}
async function importImageRecords(records,payload={}){
  if(!payload||typeof payload!=='object'||Array.isArray(payload))return {error:'invalid'};
  if(workspace.busy||imageImportJob)return {error:'busy'};
  const owner=session,current=owner.current,revision=owner.revision,generation=owner.generation;
  if(current?current.id!==payload.id||revision!==payload.revision:payload.id!=null||payload.revision!=null)return {error:'stale'};
  let run,timer;
  try{
    run=new ImageImportRun(records,{targetID:payload.targetID,point:payload.point});imageImportJob={run,owner};owner.pending=true;nativeMenu();timer=setTimeout(()=>run.cancel(),180000);
    const candidate=await run.build(current?.data,codecs,(bytes,signal)=>imageCodec('decodeSourceImage',bytes,undefined,signal),progress=>win?.webContents.send('viewer:importProgress',progress));
    if(owner!==session||owner.current!==current||owner.revision!==revision||owner.generation!==generation)throw new ProjectError('stale');run.check();
    const result=current?owner.commit(current.data,candidate,{kind:'importPixels'}):owner.install(candidate);
    owner.scheduleRecovery();return {...result,workspace:workspace.state()};
  }catch(error){return error.code==='canceled'?{canceled:true}:{error:error.code??'asset'};}
  finally{clearTimeout(timer);if(imageImportJob?.run===run)imageImportJob=undefined;owner.pending=false;nativeMenu();}
}
let installedFontNames;
handler('editor:textTools',async(action,payload)=>{
  if(!['fonts','render'].includes(action))return {error:'invalid'};
  if(action==='fonts'&&installedFontNames)return {fonts:installedFontNames};
  if(action==='render'&&(!session.current||session.current.id!==payload?.id||session.revision!==payload?.revision))return {error:'stale'};
  if(session.pending)return {error:'busy'};
  const current=session.current,revision=session.revision;
  try{const result=await new Promise((resolve,reject)=>{const worker=new Worker(new URL('../../../packages/platform/typography-worker.mjs',import.meta.url),{workerData:{action,payload,typographyPath:path.join(ROOT,'out/typography/index.cjs')},resourceLimits:{maxOldGenerationSizeMb:256,maxYoungGenerationSizeMb:32}});let settled=false;const finish=(error,result)=>{if(settled)return;settled=true;clearTimeout(timer);worker.terminate();error?reject(new ProjectError(error)):resolve(result);},timer=setTimeout(()=>finish('limit'),30000);worker.once('message',value=>finish(value.error,value.result));worker.once('error',error=>finish(error.code==='ERR_WORKER_OUT_OF_MEMORY'?'limit':'glyph'));worker.once('exit',()=>{if(!settled)finish('glyph');});});
    if(action==='render'&&(session.current!==current||session.revision!==revision))return {error:'stale'};if(action==='fonts')installedFontNames=result.fonts;return result;
  }catch(error){return {error:error.code??'glyph'};}
});
handler('editor:jumpHistory',(id,revision,index)=>projectRequest(async()=>{const result=session.jumpHistory(id,revision,index);nativeMenu();return result;}));
handler('editor:edit', (id,revision,op)=>{
  const heavy=o=>['distort','refineEdges','stroke','fill','gradient','bucket','filter','imageSize','applyMask','selectionMask','fillLayer','path','vectorMask','filterStack','textOutlines','styled'].includes(o?.kind)||o?.kind==='selection'||(o?.kind==='batch'&&Array.isArray(o.operations)&&o.operations.some(heavy));
  return projectRequest(async()=>{const result=heavy(op)?await session.editAsync(id,revision,op,buildEdit):session.edit(id,revision,op);nativeMenu();return result;});
});
const clipboardTokenType='electron application/osclipboard;format="org.compositorzh.clipboard-token"';
let copiedContent;
handler('editor:clipboard',async(id,revision,action,png,info={})=>{
  if(session.pending)return {error:'busy'};if(!session.current||session.current.id!==id||session.revision!==revision)return {error:'stale'};
  const owner=session.current;session.pending=true;nativeMenu();
  try {if(['copy','copyLayers'].includes(action)){
      if(owner.data.analysis.issues.length)return {error:'unsupported'};
      const token=randomUUID(),record={token},types={[clipboardTokenType]:new Blob([token])};
      if(action==='copyLayers'){if(owner.data.selection)return {error:'selection'};record.layers=captureLayers(owner.data,info.ids);}
      else{if(!Array.isArray(info.origin)||info.origin.length!==2||info.origin.some(value=>!Number.isFinite(value)||Math.abs(value)>300000))return {error:'invalid'};record.origin=[...info.origin];}
      if(png!==undefined){const resource=codecs.validatePNG(png);types['image/png']=new Blob([new Uint8Array(resource.bytes)],{type:'image/png'});}
      else if(!record.layers)return {error:'asset'};
      await clipboard.write([new ClipboardItem(types)]);copiedContent=record;return {copied:true};
    }
    if(action!=='paste')return {error:'invalid'};const items=await clipboard.read(),marker=items.find(item=>item.types.includes(clipboardTokenType));
    let token;try{if(marker){const blob=await marker.getType(clipboardTokenType);if(blob.size<=64)token=await blob.text();}}catch{/* An external writer may have replaced this format. */}
    if(copiedContent?.token!==token)copiedContent=undefined;
    if(session.current!==owner||session.revision!==revision)return {error:'stale'};
    if(copiedContent?.layers){session.pending=false;return session.pasteLayers(id,revision,copiedContent.layers,{targetID:info.targetID,suffix:language==='en'?' (copy)':'（副本）'});}
    const item=items.find(i=>i.types.includes('image/png')||i.types.includes('image/jpeg'));if(!item)return {error:'asset'};const type=item.types.includes('image/png')?'image/png':'image/jpeg',blob=await item.getType(type);if(blob.size>LIMITS.asset)return {error:'limit'};
    let bytes=Buffer.from(await blob.arrayBuffer());if(type==='image/jpeg')bytes=Buffer.from((await imageCodec('decodeSourceImage',bytes)).bytes);
    const resource=codecs.validatePNG(bytes),target=owner.data.manifest.layers.find(row=>row.id===info.targetID);
    if(info.targetID&&!target)return {error:'stale'};
    const origin=copiedContent?.origin??[Math.floor((owner.data.manifest.width-resource.width)/2),Math.floor((owner.data.manifest.height-resource.height)/2)],parentID=target?.isGroup?target.id:target?.parentID;
    if(session.current!==owner||session.revision!==revision)return {error:'stale'};session.pending=false;
    return session.edit(id,revision,{kind:'importPixels',name:language==='en'?'Pasted image':'粘贴图像',png:new Uint8Array(bytes),origin,parentID,aboveID:target?.id,dropsSelection:true});
  }catch(e){return {error:e.code??'invalid'};}finally{session.pending=false;nativeMenu();}
});
handler('editor:textClipboard',action=>{if(!['copy','cut','paste','selectAll','undo','redo'].includes(action))return;win.webContents[action]();});
handler('editor:history', (id, revision, dir) => { const result = session.history(id, revision, dir); nativeMenu(); return result; });
handler('editor:save', (id, revision, as) => projectRequest(() => session.save(id, revision, c => chooseSave(c, as === true))));
handler('editor:image', async (id, revision, targetID) => {
  if (session.pending) return { error: 'busy' };
  if (session.current ? session.current.id !== id || session.revision !== revision : id != null || revision != null) return { error: 'stale' };
  const owner = session.current, generation = session.generation;
  session.pending = true; nativeMenu();
  try {
    const choice = await dialog.showOpenDialog(win, { properties: ['openFile','multiSelections'], filters: [{ name: 'Image', extensions: ['png', 'jpg', 'jpeg', 'tif', 'tiff', 'webp', 'avif', 'gif', 'eps', 'epsf', 'epsi'] }] }); if (choice.canceled) return { canceled: true };
    if(choice.filePaths.length>1){session.pending=false;return await importImageRecords(choice.filePaths.map(location=>({location})),{id,revision,targetID});}
    const extension = path.extname(choice.filePaths[0]).toLowerCase();
    let imageResolution, importedResource;
    // Windows dialogs/TEMP may use an 8.3 parent name. Read through the
    // validated canonical directory, retaining safeRead's file identity checks.
    const imageDirectory = await safeDirectory(path.dirname(choice.filePaths[0]));
    let b = await safeRead(path.join(imageDirectory, path.basename(choice.filePaths[0])), ['.eps', '.epsf', '.epsi'].includes(extension) ? EPS_LIMITS.bytes : LIMITS.asset);
    if (['.eps', '.epsf', '.epsi'].includes(extension)) {
      const answer = await dialog.showMessageBox(win, { type: 'warning', buttons: language === 'en' ? ['Cancel', 'Import pixels'] : ['取消', '导入像素'], defaultId: 0, cancelId: 0,
        message: language === 'en' ? 'EPS opens as one raster layer. Text and paths will not remain editable. General EPS is rendered at 144 DPI; Ghostscript 10 must be installed.' : 'EPS 将导入为一个像素图层，文字和路径不再可编辑。普通 EPS 以 144 DPI 渲染，需安装 Ghostscript 10。' });
      if (answer.response !== 1) return { canceled: true };
      const own = await imageCodec('importRasterEPS', b);
      imageResolution = own?.resolution ?? 144;
      b = own ? Buffer.from(own.bytes) : Buffer.from((await imageCodec('importPNG', await renderEPS(b, app.getPath('temp')))).bytes);
    } else if (b.subarray(0, 3).toString('ascii') === 'GIF') {
      // Build every frame before replacing the document. Canceled/failed imports keep the old project.
      const imported = await imageCodec('importGIF', b, language);
      if (session.current !== owner || generation !== session.generation || owner && session.revision !== revision) return { error: 'stale' };
      session.pending = false;
      if (!(await canLeave())) return { canceled: true };
      if (session.current !== owner || generation !== session.generation || owner && session.revision !== revision) return { error: 'stale' };
      for (const r of imported.resources.values()) r.bytes = Buffer.from(r.bytes);
      imported.sourceBytes = Buffer.from(imported.sourceBytes);
      imported.name = path.basename(choice.filePaths[0]).replace(/\.gif$/i, '.comp');
      session.generation++;
      const result = session.install(imported); session.scheduleRecovery(); return result;
    } else {
      importedResource = await imageCodec('decodeSourceImage', b);
      importedResource.bytes = Buffer.from(importedResource.bytes);
      if (importedResource.proxyBytes) importedResource.proxyBytes = Buffer.from(importedResource.proxyBytes);
      imageResolution = importedResource.resolution;
      b = importedResource.proxyBytes ?? importedResource.bytes;
    }
    if (session.current !== owner || generation !== session.generation || owner && session.revision !== revision) return { error: 'stale' };
    session.pending = false;
    if (!owner) {
      const asset = codecs.validatePNG(new Uint8Array(b)), created = session.create(asset.width, asset.height, imageResolution);
      if (created.error) return created;
      id = session.current.id; revision = session.revision;
    }
    const op={kind:'importPixels',name:path.basename(choice.filePaths[0]).slice(0,256)},resource=importedResource??codecs.validatePNG(new Uint8Array(b));
    const result=await session.editAsync(id,revision,op,data=>insertImportedImage(data,resource,{name:op.name,targetID},codecs));
    if (!owner && result.error) session.close();
    return result;
  } catch (e) { return { error: e.code ?? 'asset' }; } finally { session.pending = false; nativeMenu(); }
});
handler('editor:importPSD', async () => {
  if (!(await canLeave())) return { canceled: true }; session.pending = true; const own = session.generation;
  try {
    const choice = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Photoshop', extensions: ['psd'] }] }); if (choice.canceled) return { canceled: true };
    const imageDirectory = await safeDirectory(path.dirname(choice.filePaths[0]));
    const b = await safeRead(path.join(imageDirectory, path.basename(choice.filePaths[0])), LIMITS.asset);
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
let outputProfile = null;
handler('editor:batchExport',async(action,payload={})=>{
  if(action==='start'){
    if(workspace.busy||!session.current||session.current.id!==payload.id||session.revision!==payload.revision)return{error:'stale'};
    if(session.current.data.analysis.issues.length)return{error:'unsupported'};
    const owner=session,current=owner.current;owner.pending=true;nativeMenu();
    try{
      const choice=await dialog.showOpenDialog(win,{title:language==='en'?'Choose a batch export folder':'选择批量导出文件夹',properties:['openDirectory']});if(choice.canceled)return{canceled:true};
      const run=await BatchExportRun.create(choice.filePaths[0],current.data.manifest,current.data.name,payload.options,payload.selected,(png,options)=>imageCodec('encodeOutputImage',png,options),(completed,total)=>{if(batchJob)win?.webContents.send('editor:batchProgress',{jobID:batchJob.run.id,completed,total});});
      batchJob={run,owner,current,revision:owner.revision};touchBatch(batchJob);return{jobID:run.id,targets:run.targets,total:run.total};
    }catch(error){return{error:error.code??'write'};}finally{if(!batchJob)owner.pending=false;nativeMenu();}
  }
  const job=batchJob;if(!job||payload.jobID!==job.run.id)return{error:'stale'};
  if(action==='cancel'){await stopBatch(job);return{canceled:true};}
  if(!['append','finish'].includes(action))return{error:'invalid'};
  try{
    if(session!==job.owner||session.current!==job.current||session.revision!==job.revision)throw new ProjectError('stale');touchBatch(job);
    if(action==='append')return await job.run.append(payload.index,payload.png);
    const result=await job.run.finish();clearTimeout(job.timer);batchJob=undefined;job.owner.pending=false;nativeMenu();return result;
  }catch(error){await stopBatch(job);return error.code==='canceled'?{canceled:true}:{error:error.code??'write'};}
});
handler('editor:outputTools', async (action, payload) => {
  if (!session.current || session.pending || payload?.id !== session.current.id || payload?.revision !== session.revision) return { error: 'stale' };
  const owner = session.current, revision = session.revision;
  session.pending = true; nativeMenu();
  try {
    if (action === 'profileInfo') return { profile: outputProfile?.name ?? 'built-in-cmyk' };
    if (action === 'profile') {
      if (payload.reset === true) { outputProfile = null; return { profile: 'built-in-cmyk' }; }
      const selected = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'CMYK ICC profile', extensions: ['icc', 'icm'] }] });
      if (selected.canceled || !selected.filePaths?.[0]) return { canceled: true };
      const file = selected.filePaths[0], directory = await safeDirectory(path.dirname(file));
      const bytes = validateCMYKProfile(await safeRead(path.join(directory, path.basename(file)), 4 * 1024 ** 2));
      if (owner !== session.current || revision !== session.revision) return { error: 'stale' };
      outputProfile = { bytes, name: path.basename(file) }; return { profile: outputProfile.name };
    }
    if (action !== 'proof') return { error: 'invalid' };
    const png = codecs.validatePNG(payload.png);
    if (png.width !== owner.data.manifest.width || png.height !== owner.data.manifest.height) return { error: 'invalid' };
    const proof = await imageCodec('printProof', png.bytes, outputProfile?.bytes);
    return owner === session.current && revision === session.revision ? { png: proof } : { error: 'stale' };
  } catch (error) { return { error: error.code ?? 'asset' }; }
  finally { session.pending = false; nativeMenu(); }
});
handler('editor:export', async (id, revision, type, payload) => {
  if (!session.current || session.current.id !== id || session.revision !== revision || session.pending) return { error: 'stale' };
  if (!['psd', 'gif', 'eps', ...OUTPUT_FORMATS].includes(type) || session.current.data.analysis.issues.length) return { error: 'unsupported' };
  const owner = session.current;
  session.pending = true; nativeMenu();
  try {
    if (type === 'gif' || type === 'eps') {
      const answer = await dialog.showMessageBox(win, { type: 'warning', buttons: language === 'en' ? ['Cancel', 'Export'] : ['取消', '导出'], defaultId: 1, cancelId: 0,
        message: type === 'gif' ? (language === 'en' ? 'Export all animation frames with their timing and repeats. Each frame uses up to 256 colors and binary transparency.' : '导出全部动画帧，保留帧时长和循环次数。每帧最多 256 色，保留二值透明度。') : (language === 'en' ? 'Export a flattened RGB raster EPS. Transparent areas are filled with white. Text, paths and layers will not remain editable.' : '导出扁平 RGB 像素 EPS，透明区域填为白色，不保留可编辑文字、路径和图层。') });
      if (answer.response !== 1) return { canceled: true };
    }
    const extension = ({ jpeg: 'jpg', tiff: 'tif', cmyktiff: 'tif' })[type] ?? type;
    const choice = await dialog.showSaveDialog(win, { filters: [{ name: type.toUpperCase(), extensions: [extension] }], defaultPath: `Export.${extension}` }); if (choice.canceled || !choice.filePath) return { canceled: true };
    if (session.current.id !== id || session.revision !== revision) return { error: 'stale' };
    let bytes;
    if (type === 'gif') {
      const m = session.current.data.manifest, frames = m.animation?.frames ?? [{ durationMS: 100 }];
      if (!Array.isArray(payload.frames) || payload.frames.length !== frames.length || m.width * m.height * frames.length > 64_000_000) throw new ProjectError('gifLimit');
      let encoded = 0;
      const validated = payload.frames.map((f, i) => {
        if (!(f.png instanceof Uint8Array) || f.png.byteLength > LIMITS.asset) throw new ProjectError('gifLimit');
        const png = pngDimensions(Buffer.from(f.png.buffer, f.png.byteOffset, f.png.byteLength));
        if (png.width !== m.width || png.height !== m.height) throw new ProjectError('gifInvalid');
        encoded += f.png.byteLength; if (encoded > 192 * 1024 ** 2) throw new ProjectError('gifLimit');
        return { png: f.png, durationMS: frames[i].durationMS };
      });
      bytes = Buffer.from(await imageCodec('exportGIF', { frames: validated, loopCount: m.animation?.loopCount ?? -1, keepTransparency: true }));
    } else if (OUTPUT_FORMATS.includes(type)) {
      const png = codecs.validatePNG(payload.composite), options = payload.options ?? {};
      if (png.width !== owner.data.manifest.width || png.height !== owner.data.manifest.height) throw new ProjectError('invalid');
      bytes = Buffer.from(await imageCodec('encodeOutputImage', png.bytes, { format: type, quality: options.quality, size: options.size,
        lossless: options.lossless, resolution: options.resolution ?? owner.data.manifest.resolution ?? 72,
        ...(type === 'cmyktiff' && outputProfile ? { profile: outputProfile.bytes } : {}) }));
    }
    else if (type === 'psd') bytes = codecs.exportPSD(session.current.data, payload);
    else bytes = Buffer.from(await imageCodec('exportEPS', payload.composite, session.current.data.manifest.resolution ?? 72));
    if (session.current !== owner || session.revision !== revision) return { error: 'stale' };
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
  dialog.showErrorBox(edition.name, '无法启动应用。请完整解压安装包后重试。 / Unable to start. Extract the complete application package and try again.');
  app.quit();
});
