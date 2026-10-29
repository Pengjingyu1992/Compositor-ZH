import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixture } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

const output = process.env.COMPOSITOR_UI_REVIEW_OUTPUT ?? fileURLToPath(new URL('../../test-results/', import.meta.url));
let app, page, temp, source, original;
test.beforeEach(async () => {
  await mkdir(output, { recursive: true });
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-ui-refinement-'));
  source = path.join(temp, 'Coast study.comp');
  await fixture(source);
  original = await readFile(path.join(source, 'manifest.json'));
  app = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(temp) });
  page = await app.firstWindow();
  await app.evaluate(({ BrowserWindow, dialog }, source) => {
    BrowserWindow.getAllWindows()[0].setContentSize(1280, 800);
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [source] });
  }, source);
  await expect(page.getByTestId('open-project')).toBeEnabled();
  await page.getByTestId('language').selectOption('en');
});
test.afterEach(async () => {
  await app?.close();
  expect(await readFile(path.join(source, 'manifest.json'))).toEqual(original);
  await rm(temp, { recursive: true, force: true });
});
async function capture(name) {
  await page.screenshot({ animations: 'disabled', path: path.join(output, `refinement-${name}-preview.png`) });
}

test('workspace settings keep labels and controls readable in both languages and appearances', async () => {
  for (const [language, appearance, width, height] of [['en', 'light', 1280, 800], ['zh-Hans', 'dark', 880, 540]]) {
    await app.evaluate(({ BrowserWindow }, size) => BrowserWindow.getAllWindows()[0].setContentSize(...size), [width, height]);
    await page.getByTestId('language').selectOption(language);
    await page.getByTestId('interface-settings').click();
    await page.getByTestId('interface-appearance').selectOption(appearance);
    await page.getByTestId('apply-view-settings').click();
    await page.getByTestId('interface-settings').click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await capture(`settings-${language}-${appearance}`);
    const fields = await dialog.locator('label').evaluateAll(labels => labels.map(label => {
      const field = label.querySelector('input,select'), box = field.getBoundingClientRect();
      const text = [...label.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
      const range = document.createRange(); range.selectNodeContents(text);
      const title = range.getBoundingClientRect();
      return { name: text.textContent.trim(), width: box.width, gap: box.left - title.right, inside: box.right <= label.getBoundingClientRect().right + 1 };
    }));
    for (const field of fields) {
      expect.soft(field.width, `${language}: ${field.name} control width`).toBeGreaterThanOrEqual(130);
      expect.soft(field.gap, `${language}: ${field.name} label gap`).toBeGreaterThanOrEqual(7);
      expect.soft(field.inside, `${language}: ${field.name} fits its row`).toBe(true);
    }
    await expect(page.getByTestId('apply-view-settings')).toBeInViewport({ ratio: 1 });
    await page.keyboard.press('Escape');
    await expect(dialog).toHaveCount(0);
  }
});

test('compact inspector avoids an extra outer scrollbar, swatches show keyboard focus, and dragging uses the interface theme', async () => {
  await page.getByTestId('open-project').click();
  await expect(page.getByTestId('save-project')).toBeEnabled();
  await page.locator('.layer-select').filter({ hasText: 'Coral / 珊瑚' }).click();
  await page.getByRole('button', { name: 'Move', exact: true }).click();
  const pixels = () => page.getByTestId('rendered-canvas').evaluate(canvas => [...canvas.getContext('2d').getImageData(0, 0, 1, 1).data]);
  const before = await pixels();
  await page.getByTestId('interface-settings').click();
  await page.getByTestId('interface-appearance').selectOption('dark');
  await page.getByTestId('apply-view-settings').click();
  await capture('inspector-dark');
  const tabs = page.locator('.inspector-tabs');
  await tabs.getByRole('tab', { name: 'Properties', exact: true }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(tabs.getByRole('tab', { name: 'Adjustments', exact: true })).toHaveAttribute('aria-selected', 'true');
  await page.keyboard.press('ArrowLeft');
  await expect(tabs.getByRole('tab', { name: 'Properties', exact: true })).toHaveAttribute('aria-selected', 'true');
  await page.locator('.arrange-grid').scrollIntoViewIfNeeded();
  await capture('arrange-dark');
  const swatch = page.locator('.color-swatch').first();
  await swatch.locator('input').focus();
  await capture('swatch-focus-dark');
  expect.soft(await swatch.evaluate(el => getComputedStyle(el).outlineStyle)).toBe('solid');
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(880, 540));
  await page.getByTestId('language').selectOption('zh-Hans');
  await capture('compact-dark');
  expect.soft(await page.locator('aside').evaluate(el => el.scrollHeight <= el.clientHeight)).toBe(true);
  await expect(page.locator('.layer-row.selected .layer-select')).toBeInViewport({ ratio: 1 });
  await page.getByTestId('merge-layers').scrollIntoViewIfNeeded();
  await expect(page.getByTestId('merge-layers')).toBeInViewport({ ratio: 1 });
  await expect(page.getByTestId('add-pixels')).toBeInViewport({ ratio: 1 });
  await capture('compact-properties-footer-dark');
  expect(await pixels()).toEqual(before);
  await expect(page.getByTestId('undo')).toBeDisabled();
  await page.locator('.shell').evaluate(el => {
    const dataTransfer = new DataTransfer(); dataTransfer.items.add(new File(['synthetic'], 'example.comp'));
    el.dispatchEvent(new DragEvent('dragenter', { bubbles: true, dataTransfer }));
  });
  await expect(page.locator('.drop-target')).toBeVisible();
  await capture('file-drag-dark');
  expect.soft(await page.locator('.drop-target').evaluate(el => getComputedStyle(el).color)).toBe(await page.locator('body').evaluate(el => getComputedStyle(el).color));
  await page.locator('.shell').dispatchEvent('dragleave');
  await expect(page.locator('.drop-target')).toHaveCount(0);
});

test('a short workspace with the assistant open keeps inspector actions reachable by mouse scrolling', async () => {
  await page.getByTestId('open-project').click();
  await expect(page.getByTestId('save-project')).toBeEnabled();
  await page.locator('.layer-select').filter({ hasText: 'Coral / 珊瑚' }).click();
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(880, 540));
  await page.getByTestId('ai-fold').click();
  await expect(page.getByTestId('ai-prompt')).toBeVisible();
  await capture('short-assistant-before-scroll');
  const sidebar = page.locator('aside');
  await page.locator('.layer-list').hover();
  await page.mouse.wheel(0, 3000);
  await expect(page.getByTestId('merge-layers')).toBeInViewport({ ratio: 1 });
  await capture('short-assistant-after-scroll');
  await page.mouse.wheel(0, -3000);
  await expect(page.getByTestId('add-pixels')).toBeInViewport({ ratio: 1 });
  await page.getByTestId('ai-fold').click();
  await expect(page.getByTestId('ai-prompt')).toHaveCount(0);
  await expect.poll(() => sidebar.evaluate(el => el.scrollHeight <= el.clientHeight)).toBe(true);
  await expect(page.getByTestId('undo')).toBeDisabled();
});
