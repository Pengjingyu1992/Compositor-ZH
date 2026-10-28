import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import sharp from 'sharp';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test('packaged image import preserves ICC 16-bit PNG and orientation through save', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'comp-v17-smoke-'));
  let instance;
  try {
    const image = path.join(directory, 'original.png'), saved = path.join(directory, 'saved.comp');
    const bytes = await sharp({ create: { width: 2, height: 3, channels: 4, background: { r: 180, g: 100, b: 60, alpha: .5 } } })
      .withMetadata({ orientation: 6, density: 300 }).withIccProfile('p3').toColourspace('rgb16').png().toBuffer();
    await writeFile(image, bytes);
    instance = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(directory) });
    const page = await instance.firstWindow();
    await instance.evaluate(({ dialog, Menu }, { image, saved }) => {
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [image] });
      dialog.showSaveDialog = async () => ({ canceled: false, filePath: saved });
      dialog.showMessageBox = async () => ({ response: 1 });
      Menu.getApplicationMenu().getMenuItemById('file-image').click();
    }, { image, saved });
    await expect(page.getByTestId('rendered-canvas')).toBeVisible();
    await expect(page.locator('[role=alert]')).toHaveCount(0);
    const dimensions = await page.getByTestId('rendered-canvas').evaluate(c => [c.width, c.height]);
    expect(dimensions).toEqual([3, 2]);
    await expect(page.getByTestId('save-project')).toBeEnabled();
    await page.getByTestId('save-project').click();
    await expect(page.locator('.badge')).toContainText(/已保存|Saved/);
    const manifest = JSON.parse(await readFile(path.join(saved, 'manifest.json')));
    expect(manifest.version).toBe(17); expect(manifest.resolution).toBe(300);
    expect(await readFile(path.join(saved, 'images', manifest.layers[0].imageFile))).toEqual(bytes);
  } finally { await instance?.close(); await rm(directory, { recursive: true, force: true }); }
});
