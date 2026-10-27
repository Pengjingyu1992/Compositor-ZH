import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import sharp from 'sharp';
import { fixture } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test('packaged export dialog writes all image formats and print proof leaves the project intact', async () => {
  test.setTimeout(120000);
  const directory = await mkdtemp(path.join(os.tmpdir(), 'comp-output-smoke-')), source = path.join(directory, 'source.comp');
  await fixture(source); const original = await readFile(path.join(source, 'manifest.json'));
  let instance;
  try {
    instance = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(directory) });
    const page = await instance.firstWindow();
    await instance.evaluate(({ dialog }, source) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [source] }); dialog.showMessageBox = async () => ({ response: 1 }); }, source);
    await page.getByTestId('open-project').click(); await expect(page.getByTestId('rendered-canvas')).toBeVisible();
    await expect(page.getByTestId('save-project')).toBeEnabled();
    await instance.evaluate(({ Menu }) => Menu.getApplicationMenu().getMenuItemById('file-export-as').click());
    const dialog = page.getByRole('dialog'); await expect(dialog).toBeVisible();
    await page.getByTestId('print-proof').click(); await expect(page.getByTestId('print-proof-image')).toBeVisible();
    for (const format of ['jpeg', 'webp', 'avif', 'tiff', 'pdf', 'cmyktiff']) {
      const output = path.join(directory, `output.${format}`);
      await page.getByTestId('output-format').selectOption(format);
      await page.getByTestId('output-size').fill('32');
      await instance.evaluate(({ dialog }, output) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: output }); }, output);
      await page.getByTestId('output-export').click();
      await expect(page.getByTestId('output-export')).toBeEnabled();
      await expect(dialog.locator('[role=alert]')).toHaveCount(0);
      const bytes = await readFile(output);
      if (format === 'pdf') expect(bytes.subarray(0, 8).toString()).toBe('%PDF-1.4');
      else { const metadata = await sharp(bytes).metadata(); expect([metadata.width, metadata.height]).toEqual([32, 24]); if (format === 'cmyktiff') { expect(metadata.space).toBe('cmyk'); expect(metadata.channels).toBe(4); } }
    }
    await page.keyboard.press('Escape'); await expect(dialog).toHaveCount(0);
    await expect(page.getByTestId('undo')).toBeDisabled();
    await expect(page.locator('.badge')).toContainText(/已保存|Saved/);
    expect(await readFile(path.join(source, 'manifest.json'))).toEqual(original);
  } finally { await instance?.close(); await rm(directory, { recursive: true, force: true }); }
});
