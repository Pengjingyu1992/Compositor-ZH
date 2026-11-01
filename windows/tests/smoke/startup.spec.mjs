import { test, expect, _electron } from '@playwright/test';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fixture } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test('a second launch shows the hidden editor and retains its unsaved document', async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'comp-startup-'));
  const source = path.join(temp, 'synthetic.comp');
  await fixture(source);
  const before = await readFile(path.join(source, 'manifest.json'));
  let instance;
  try {
    instance = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(temp) });
    const page = await instance.firstWindow(), errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await instance.evaluate(({ app, dialog }, source) => {
      globalThis.startupActivations = 0;
      app.on('second-instance', () => globalThis.startupActivations++);
      dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [source] });
      dialog.showMessageBox = async () => ({ response: 1 });
    }, source);
    await page.getByTestId('language').selectOption('en');
    await page.getByTestId('open-project').click();
    await expect(page.getByTestId('rendered-canvas')).toBeVisible();
    await page.locator('.layer-select').filter({ hasText: 'Mint / 薄荷' }).click();
    await page.getByTestId('layer-opacity').fill('80');
    await page.getByTestId('layer-opacity').press('Tab');
    await expect(page.getByTestId('undo')).toBeEnabled();
    const workspace = (await page.evaluate(() => window.editor.workspace('list'))).workspace;
    const pid = instance.process().pid;
    await instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].hide());
    expect(await instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible())).toBe(false);

    for (let count = 1; count <= 2; count++) {
      // Start the actual packaged application with the same data directory;
      // emitting a test event would not exercise the native single-instance lock.
      const child = spawn(smokeExecutable(), smokeArgs(), { env: smokeEnv(temp), stdio: 'ignore' });
      try {
        const result = await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('The second instance did not exit')), 15000);
          child.once('error', error => { clearTimeout(timer); reject(error); });
          child.once('exit', (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
        });
        expect(result).toEqual({ code: 0, signal: null });
      } finally { if (child.exitCode === null && child.signalCode === null) child.kill(); }
      await expect.poll(() => instance.evaluate(() => globalThis.startupActivations)).toBe(count);
      await expect.poll(() => instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible())).toBe(true);
      expect(await instance.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)).toBe(1);
      expect(instance.process().pid).toBe(pid);
      expect((await page.evaluate(() => window.editor.workspace('list'))).workspace.activeID).toBe(workspace.activeID);
      await expect(page.getByTestId('layer-opacity')).toHaveValue('80');
      await expect(page.getByTestId('undo')).toBeEnabled();
      await expect(page.locator('.badge')).toContainText('Unsaved');
    }
    await page.getByTestId('undo').click();
    await expect(page.getByTestId('layer-opacity')).toHaveValue('50');
    expect(await readFile(path.join(source, 'manifest.json'))).toEqual(before);
    expect(errors).toEqual([]);
  } finally {
    await instance?.close();
    await rm(temp, { recursive: true, force: true });
  }
});
