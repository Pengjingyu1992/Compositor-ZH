import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
export function smokeExecutable() {
  return process.env.COMPOSITOR_SMOKE_EXECUTABLE || (process.platform === 'linux'
    ? path.join(root, '../linux/release/linux-unpacked/compositor-linux')
    : path.join(root, 'release/win-unpacked/Compositor.exe'));
}
export function smokeArgs() {
  return ['--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    ...(process.platform === 'linux' && process.env.COMPOSITOR_SMOKE_PASSWORD_STORE === 'gnome-libsecret' ? ['--password-store=gnome-libsecret'] : []),
    ...(process.env.COMPOSITOR_SMOKE_NO_SANDBOX === '1' ? ['--no-sandbox'] : [])];
}
export function smokeEnv(directory) {
  const env = { ...process.env, APPDATA: directory, XDG_CONFIG_HOME: path.join(directory, 'config'),
    XDG_CACHE_HOME: path.join(directory, 'cache'), COMPOSITOR_USER_DATA_DIRECTORY: path.join(directory, 'user-data'),
    COMPOSITOR_AI_DIRECTORY: path.join(directory, 'ai-settings') };
  delete env.ELECTRON_RUN_AS_NODE;
  delete env.NODE_OPTIONS;
  return env;
}
