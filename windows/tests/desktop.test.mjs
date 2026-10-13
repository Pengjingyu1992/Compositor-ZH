import { test } from 'node:test';
import assert from 'node:assert/strict';
import { desktopEdition, canPersistApiKey } from '../packages/platform/desktop.mjs';
import { ghostscriptCandidates } from '../packages/platform/eps-import.mjs';
import { localizedMessages } from '../packages/locales/index.ts';

test('Linux identity and bilingual labels do not change the Windows edition', () => {
  assert.equal(desktopEdition('linux').directory, 'Compositor-Linux');
  assert.equal(desktopEdition('win32').directory, 'Compositor-Windows');
  assert.equal(desktopEdition('win32').appId, 'org.compositorzh.windows');
  for (const language of ['en', 'zh-Hans']) {
    const linux = localizedMessages(language, 'linux');
    const windows = localizedMessages(language, 'windows');
    for (const key of ['subtitle', 'welcome', 'readonly']) {
      assert.ok(linux[key].includes('Linux'));
      assert.ok(windows[key].includes('Windows'));
    }
    assert.ok(!linux.errors.epsInterpreter.includes('Windows'));
    assert.ok(windows.errors.epsInterpreter.includes('Windows'));
    assert.equal(linux.editor.saved, windows.editor.saved);
  }
});

test('Linux keys require an available real keyring, never basic_text or an unknown backend', () => {
  const storage = backend => ({ isEncryptionAvailable: () => true, getSelectedStorageBackend: () => backend });
  for (const backend of ['basic_text', 'unknown', '', undefined]) assert.equal(canPersistApiKey(storage(backend), 'linux'), false);
  for (const backend of ['gnome_libsecret', 'kwallet5', 'kwallet6']) assert.equal(canPersistApiKey(storage(backend), 'linux'), true);
  assert.equal(canPersistApiKey({ isEncryptionAvailable: () => false }, 'linux'), false);
  assert.equal(canPersistApiKey({ isEncryptionAvailable: () => true }, 'win32'), true);
});

test('Linux Ghostscript discovery uses fixed system locations and only absolute overrides', async () => {
  assert.deepEqual(await ghostscriptCandidates({ PATH: '.', COMPOSITOR_GHOSTSCRIPT: 'gs' }, 'linux'), ['/usr/bin/gs', '/usr/local/bin/gs']);
  assert.deepEqual(await ghostscriptCandidates({ COMPOSITOR_GHOSTSCRIPT: '/opt/gs/bin/gs' }, 'linux'), ['/opt/gs/bin/gs', '/usr/bin/gs', '/usr/local/bin/gs']);
  assert.deepEqual(await ghostscriptCandidates({}, 'win32'), []);
});
