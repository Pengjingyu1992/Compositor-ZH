import { app, BrowserWindow, Menu, dialog, ipcMain, protocol, clipboard, nativeImage } from 'electron';
import { readFile, lstat, open, rename, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getLanguage, setLanguage } from '../../../packages/platform/preferences.mjs';
import { ProjectSession } from '../../../packages/platform/project-session.mjs';
import { compatibilityReport } from '../../../packages/platform/compatibility-report.mjs';
import { RecoveryStore, recoverSaves, fingerprint } from '../../../packages/platform/save-project.mjs';
import { safeDirectory, safeRead, readProject, jpegDimensions, ProjectError, LIMITS } from '../../../packages/comp-bridge/project.mjs';

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
  win?.setTitle((zh ? '叠绘 · Windows' : 'Compositor · Windows') + (session.current && session.current.data !== session.saved ? ' *' : ''));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: zh ? '文件' : 'File', submenu: [
      { label: zh ? '新建画布…' : 'New canvas…', accelerator: 'Ctrl+N', click: () => win?.webContents.send('editor:new') },
      { label: zh ? '打开项目…' : 'Open project…', accelerator: 'Ctrl+O', click: () => win?.webContents.send('viewer:open') },
      { label: zh ? '导入图像…' : 'Import image…', click: () => win?.webContents.send('editor:image') },
      { label: zh ? '导入 PSD…' : 'Import PSD…', click: () => win?.webContents.send('editor:importPSD') },
      { label: zh ? '保存' : 'Save', accelerator: 'Ctrl+S', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('editor:save') },
      { label: zh ? '另存为…' : 'Save As…', accelerator: 'Ctrl+Shift+S', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('editor:saveAs') },
      { label: zh ? '导出 PNG…' : 'Export PNG…', click: () => win?.webContents.send('editor:png') },
      { label: zh ? '导出 PSD…' : 'Export PSD…', click: () => win?.webContents.send('editor:exportPSD') },
      { label: zh ? '恢复未保存项目…' : 'Recover unsaved project…', click: () => win?.webContents.send('editor:recover') },
      { label: zh ? '重新加载项目' : 'Reload project', accelerator: 'Ctrl+R', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('viewer:reload') },
      { label: zh ? '关闭项目' : 'Close project', accelerator: 'Ctrl+W', enabled: !!session.current || session.pending, click: () => win?.webContents.send('viewer:close') },
      { type: 'separator' }, { label: zh ? '退出' : 'Quit', role: 'quit' }
    ] },
    { label: zh ? '编辑' : 'Edit', submenu: [
      { label: zh ? '撤销' : 'Undo', accelerator: 'Ctrl+Z', enabled: !!session.undoStack.length && !session.pending, click: () => win?.webContents.send('editor:undo') },
      { label: zh ? '重做' : 'Redo', accelerator: 'Ctrl+Shift+Z', enabled: !!session.redoStack.length && !session.pending, click: () => win?.webContents.send('editor:redo') },
      { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }
    ] },
    { label: zh ? '显示' : 'View', submenu: [
      { label: zh ? '适合窗口' : 'Fit to window', accelerator: 'Ctrl+0', click: () => win?.webContents.send('viewer:fit') },
      { label: '100%', accelerator: 'Ctrl+1', click: () => win?.webContents.send('viewer:actual') },
      { label: zh ? '全屏' : 'Full screen', role: 'togglefullscreen' }
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
  if (!session.current || session.current.data === session.saved) return true;
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
handler('editor:edit', (id, revision, op) => { const result = session.edit(id, revision, op); nativeMenu(); return result; });
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
handler('viewer:report', (id, display) => {
  if (!session.current || session.current.id !== id || session.pending) return { error: 'stale' };
  clipboard.writeText(JSON.stringify(compatibilityReport(session.current.data, app.getVersion(), display), null, 2));
  return { copied: true };
});
nativeMenu();
await win.loadURL(HOME);
if (recoveredSaves.includes('manual')) await dialog.showMessageBox(win, { type: 'warning', message: language === 'en' ? 'An interrupted save needs manual attention. The original or its backup has been retained.' : '有一次中断的保存需要人工处理。原项目或完整备份已保留。' });
}).catch(() => {
  dialog.showErrorBox('Compositor Windows', '无法启动应用。请完整解压安装包后重试。 / Unable to start. Extract the complete application package and try again.');
  app.quit();
});
