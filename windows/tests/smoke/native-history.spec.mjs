import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fixture } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test.describe.configure({ timeout: process.platform === 'linux' ? 120000 : 60000 });
let instance, page, temp;
test.beforeEach(async () => {
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-native-history-'));
  const source = path.join(temp, 'source.comp'); await fixture(source);
  instance = await _electron.launch({ timeout: 30000, executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(temp) });
  page = await instance.firstWindow();
  await instance.evaluate(({ dialog }, source) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [source] });
    dialog.showMessageBox = async () => ({ response: 1 });
  }, source);
  await page.getByTestId('open-project').click();
  await expect(page.getByTestId('rendered-canvas')).toBeVisible();
  await page.locator('.layer-select').filter({ hasText: 'Mint / 薄荷' }).click();
  await expect(page.getByTestId('layer-opacity')).toBeEnabled();
});
test.afterEach(async () => { await instance?.close(); await rm(temp, { recursive: true, force: true }); });

async function nativeHistory(direction) {
  await instance.evaluate(({ Menu }, direction) => {
    const item = Menu.getApplicationMenu().getMenuItemById(`edit-${direction}`);
    if (!item?.enabled) throw new Error('Native text history must be available independently of project history');
    item.click();
  }, direction);
  // Drain the preceding renderer command and its main-process IPC before assertions.
  await page.evaluate(() => window.viewer.settings());
}
async function textDialog() {
  await instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.send('editor:text'));
  const field = page.getByTestId('text-content');
  await expect(field).toBeVisible(); await field.pressSequentially('Draft text');
  return field;
}

test('native undo and redo edit focused text when project history is empty', async () => {
  await expect(page.getByTestId('undo')).toBeDisabled();
  const field = await textDialog();
  await nativeHistory('undo'); await expect(field).toHaveValue('');
  await nativeHistory('redo'); await expect(field).toHaveValue('Draft text');
  await expect(page.getByTestId('undo')).toBeDisabled();
  await expect(page.getByTestId('redo')).toBeDisabled();
  await expect(page.locator('.layer-row')).toHaveCount(2);
});

test('native history preserves the project during composition and modal editing', async () => {
  await page.getByTestId('layer-opacity').fill('80');
  await page.getByTestId('layer-opacity').press('Tab');
  await expect(page.getByTestId('undo')).toBeEnabled();
  const field = await textDialog();
  await field.dispatchEvent('compositionstart', { data: '中' });
  await nativeHistory('undo'); await expect(field).toHaveValue('Draft text');
  await field.dispatchEvent('compositionend', { data: '中' });
  await nativeHistory('undo'); await expect(field).toHaveValue('');
  await nativeHistory('redo'); await expect(field).toHaveValue('Draft text');
  await page.getByTestId('update-preview').focus();
  await nativeHistory('undo');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('text-content')).toHaveCount(0);
  const destination = path.join(temp, 'preserved.comp');
  await instance.evaluate(({ dialog }, destination) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: destination }); }, destination);
  await instance.evaluate(({ Menu }) => {
    const item = Menu.getApplicationMenu().getMenuItemById('file-save-as');
    if (!item?.enabled) throw new Error('Save As is unavailable');
    item.click();
  });
  await expect(page.locator('.badge')).toContainText(/已保存|Saved/);
  await expect(page.getByTestId('save-project')).toBeEnabled();
  expect(JSON.parse(await readFile(path.join(destination, 'manifest.json'))).layers[1].opacity).toBe(.8);
  await page.getByTestId('save-project').focus();
  await nativeHistory('undo'); await expect(page.getByTestId('layer-opacity')).toHaveValue('50');
  await expect(page.getByTestId('redo')).toBeEnabled();
  await nativeHistory('redo'); await expect(page.getByTestId('layer-opacity')).toHaveValue('80');
  await expect(page.getByTestId('layer-opacity')).toBeEnabled();
});
