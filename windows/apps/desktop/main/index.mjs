import { app, BrowserWindow, Menu, dialog, ipcMain, protocol, clipboard } from 'electron';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getLanguage, setLanguage } from '../../../packages/platform/preferences.mjs';
import { ProjectSession } from '../../../packages/platform/project-session.mjs';
import { compatibilityReport } from '../../../packages/platform/compatibility-report.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const RENDERER = path.join(ROOT, 'out', 'renderer');
const HOME = 'compositor://app/index.html';
protocol.registerSchemesAsPrivileged([{ scheme: 'compositor', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);
app.setName('Compositor Windows');
app.setAppUserModelId('org.compositorzh.windows');
app.setPath('userData', path.join(app.getPath('appData'), 'Compositor-Windows'));
if (!app.requestSingleInstanceLock()) { app.quit(); process.exit(0); }
let win, language = 'zh-Hans';
const session = new ProjectSession();
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
  win?.setTitle(zh ? '叠绘 · Windows 只读预览' : 'Compositor · Windows read-only preview');
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: zh ? '文件' : 'File', submenu: [
      { label: zh ? '打开项目…' : 'Open project…', accelerator: 'Ctrl+O', click: () => win?.webContents.send('viewer:open') },
      { label: zh ? '重新加载项目' : 'Reload project', accelerator: 'Ctrl+R', enabled: !!session.current && !session.pending, click: () => win?.webContents.send('viewer:reload') },
      { label: zh ? '关闭项目' : 'Close project', accelerator: 'Ctrl+W', enabled: !!session.current || session.pending, click: () => win?.webContents.send('viewer:close') },
      { type: 'separator' }, { label: zh ? '退出' : 'Quit', role: 'quit' }
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
// Return from the ESM entry point before waiting for readiness. In particular,
// Playwright's loader delays ready until the bootstrap has finished importing.
app.whenReady().then(async () => {
language = await getLanguage(app.getPath('userData'));
protocol.handle('compositor', async request => {
  try {
    const url = new URL(request.url);
    if (request.method !== 'GET') return new Response(null, { status: 405 });
    if (url.host === 'app' && url.pathname.startsWith('/project/')) {
      const [id, index, ...extra] = url.pathname.slice('/project/'.length).split('/');
      if (!session.current || id !== session.current.id || !/^(0|[1-9][0-9]*)$/.test(index) || extra.length) return new Response(null, { status: 404 });
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
win.on('closed', () => { session.close(); win = null; });
app.on('window-all-closed', () => app.quit());
handler('viewer:settings', () => ({ language, version: app.getVersion() }));
handler('viewer:language', async value => {
  if (!['en', 'zh-Hans'].includes(value)) throw new Error('Invalid language');
  preferenceQueue = preferenceQueue.catch(() => {}).then(() => setLanguage(app.getPath('userData'), value));
  await preferenceQueue; language = value; nativeMenu();
  return { language };
});
handler('viewer:open', () => projectRequest(() => session.open(async () => {
    const result = await dialog.showOpenDialog(win, { title: language === 'en' ? 'Select a .comp project folder' : '选择 .comp 项目文件夹', properties: ['openDirectory'], buttonLabel: language === 'en' ? 'Open project' : '打开项目' });
    return result.canceled ? null : result.filePaths[0];
})));
handler('viewer:drop', location => {
  if (typeof location !== 'string' || !path.isAbsolute(location) || location.length > 32768 || path.extname(location).toLowerCase() !== '.comp') return { error: 'path' };
  return projectRequest(() => session.open(() => location));
});
handler('viewer:reload', id => projectRequest(() => session.reload(id)));
handler('viewer:close', () => { const result = session.close(); nativeMenu(); return result; });
handler('viewer:report', (id, display) => {
  if (!session.current || session.current.id !== id || session.pending) return { error: 'stale' };
  clipboard.writeText(JSON.stringify(compatibilityReport(session.current.data, app.getVersion(), display), null, 2));
  return { copied: true };
});
nativeMenu();
await win.loadURL(HOME);
}).catch(() => {
  dialog.showErrorBox('Compositor Windows', '无法启动应用。请完整解压安装包后重试。 / Unable to start. Extract the complete application package and try again.');
  app.quit();
});
