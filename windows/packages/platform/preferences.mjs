import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import path from 'node:path';

export async function getLanguage(directory) {
  try {
    const settings = JSON.parse(await readFile(path.join(directory, 'preferences.json'), 'utf8'));
    return settings.language === 'en' ? 'en' : 'zh-Hans';
  } catch { return 'zh-Hans'; }
}
export async function setLanguage(directory, language) {
  if (!['en', 'zh-Hans'].includes(language)) throw new Error('Invalid language');
  await mkdir(directory, { recursive: true });
  const temporary = path.join(directory, 'preferences.tmp');
  await writeFile(temporary, JSON.stringify({ language }), 'utf8');
  await rename(temporary, path.join(directory, 'preferences.json'));
}
