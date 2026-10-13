import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test.skip(process.platform !== 'linux', 'Linux desktop integration');
let temp, instance, page;
test.beforeEach(async () => { temp = await mkdtemp(path.join(os.tmpdir(), 'comp-linux-')); });
test.afterEach(async () => { await instance?.close(); await rm(temp, { recursive: true, force: true }); });
async function launch(args = []) {
  instance = await _electron.launch({ executablePath: smokeExecutable(), args: [...smokeArgs(), ...args], env: smokeEnv(temp) });
  page = await instance.firstWindow();
  await expect(page.locator('.welcome')).toBeVisible();
  await instance.evaluate(({ dialog }) => { dialog.showMessageBox = async () => ({ response: 1 }); });
}
test('Linux branding and desktop identity use an isolated settings directory', async () => {
  await launch();
  expect((await page.evaluate(() => window.viewer.settings())).edition).toBe('linux');
  expect(await instance.evaluate(({ app }) => app.getName())).toBe('Compositor Linux');
  expect(await instance.evaluate(({ app }) => app.getPath('userData'))).toBe(path.join(temp, 'user-data'));
  await expect(page.locator('.badge')).toContainText('Linux');
  await page.getByTestId('language').selectOption('en');
  await expect(page.locator('.badge')).toContainText('Linux editor prerelease');
  expect(await instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].getTitle())).toBe('Compositor · Linux');
});
test('basic_text never persists a recoverable API key', async () => {
  await launch(['--password-store=basic']);
  const settings = await page.evaluate(() => window.ai.save({ endpoint: 'https://example.com/v1', model: 'synthetic', key: 'linux-synthetic-key' }));
  expect(settings.encryption).toBe(false);
  expect(settings.hasKey).toBe(false);
  const stored = await readFile(path.join(temp, 'ai-settings/ai-settings.json'), 'utf8');
  expect(JSON.parse(stored).key).toBe('');
  expect(stored).not.toContain('linux-synthetic-key');
});
test('system Ghostscript imports general EPS through the editor', async () => {
  await launch();
  const file = path.join(temp, 'synthetic.eps');
  await writeFile(file, '%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 16 12\n%%EndComments\n0.2 0.6 0.4 setrgbcolor\n0 0 16 12 rectfill\nshowpage\n%%EOF\n');
  await instance.evaluate(({ dialog, Menu }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); Menu.getApplicationMenu().getMenuItemById('file-image').click(); }, file);
  await expect(page.getByTestId('rendered-canvas')).toBeVisible();
  await expect(page.locator('.layer-row')).toHaveCount(1);
  const sample = await page.getByTestId('rendered-canvas').evaluate(canvas => ({ width: canvas.width, height: canvas.height, alpha: canvas.getContext('2d').getImageData(8, 8, 1, 1).data[3] }));
  expect(sample).toEqual({ width: 32, height: 24, alpha: 255 });
  await expect(page.locator('[role=alert]')).toHaveCount(0);
});
