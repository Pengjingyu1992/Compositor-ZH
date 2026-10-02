import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { fixture } from '../fixtures.mjs';
const root = fileURLToPath(new URL('../../', import.meta.url));
let temp, project, before;
test.beforeEach(async () => {
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-smoke-')); project = path.join(temp, 'sample.comp');
  await fixture(project); before = await readFile(path.join(project, 'manifest.json'));
});
test.afterEach(async () => { await rm(temp, { recursive: true, force: true }); });
async function launch() {
  const instance = await _electron.launch({ args: [root, '--use-angle=swiftshader', '--enable-unsafe-swiftshader'], env: { ...process.env, APPDATA: temp, COMPOSITOR_CI_PROJECT: project } });
  return { instance, page: await instance.firstWindow() };
}
test('opens, renders sRGB normal + mask, changes language, restarts, and never edits', async () => {
  let { instance, page } = await launch();
  try {
    await expect(page.getByTestId('rendered-canvas')).toBeVisible();
    await expect(page.locator('.layer-row')).toHaveCount(2);
    const sample = await page.getByTestId('rendered-canvas').evaluate(c => Array.from(c.getContext('2d').getImageData(32, 24, 1, 1).data));
    // Mint at 0.5 opacity with a 128/255 grayscale mask above opaque coral.
    const expected = [210, 175, 153, 255]; expected.forEach((n, i) => expect(Math.abs(sample[i] - n)).toBeLessThanOrEqual(3));
    await page.locator('select').selectOption('en'); await expect(page.locator('.badge')).toContainText('Read-only');
    await page.keyboard.press('Control+s'); await page.keyboard.press('Control+z');
    expect(await page.evaluate(() => typeof window.viewer.save)).toBe('undefined');
    expect(await page.evaluate(() => typeof window.require)).toBe('undefined');
    expect(await readFile(path.join(project, 'manifest.json'))).toEqual(before);
    await instance.close();
    ({ instance, page } = await launch());
    await expect(page.locator('select')).toHaveValue('en');
    await expect(page.locator('.badge')).toContainText('Read-only');
  } finally { await instance.close(); }
});
test('unsupported composition without QuickLook never shows a partial render', async () => {
  await fixture(project, m => { m.layers[1].blendMode = 'Multiply'; return m; });
  const { instance, page } = await launch();
  try {
    await expect(page.locator('.no-preview')).toBeVisible();
    await expect(page.getByTestId('rendered-canvas')).toHaveCount(0);
    await expect(page.locator('.layer-row')).toHaveCount(2);
  } finally { await instance.close(); }
});
test('packaged executable starts with the isolated read-only interface', async () => {
  const instance = await _electron.launch({ executablePath: path.join(root, 'release/win-unpacked/Compositor.exe'), args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'], env: { ...process.env, APPDATA: temp } });
  try {
    const page = await instance.firstWindow();
    await expect(page.locator('.welcome')).toBeVisible();
    await expect(page.locator('.brand img')).toBeVisible();
    expect(await page.evaluate(() => typeof window.viewer.save)).toBe('undefined');
    expect(await page.evaluate(() => typeof window.require)).toBe('undefined');
  } finally { await instance.close(); }
});
