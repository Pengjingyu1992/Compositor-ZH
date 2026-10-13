const editions = {
  linux: { id: 'linux', label: 'Linux', name: 'Compositor Linux', appId: 'org.compositorzh.linux', directory: 'Compositor-Linux' },
  windows: { id: 'windows', label: 'Windows', name: 'Compositor Windows', appId: 'org.compositorzh.windows', directory: 'Compositor-Windows' }
};

export function desktopEdition(platform = process.platform) {
  return editions[platform === 'linux' ? 'linux' : 'windows'];
}

// Chromium's basic_text backend uses a fixed password, not a desktop keyring.
export function canPersistApiKey(storage, platform = process.platform) {
  if (!storage.isEncryptionAvailable()) return false;
  if (platform !== 'linux') return true;
  const backend = storage.getSelectedStorageBackend?.();
  return typeof backend === 'string' && !['basic_text', 'unknown', ''].includes(backend);
}
