import { spawn } from 'node:child_process';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ProjectError, safeRead } from '../comp-bridge/project.mjs';
import { EPS_LIMITS, postScriptSection, epsBounds } from '../comp-bridge/eps-raster.mjs';

export async function ghostscriptCandidates(env = process.env, platform = process.platform) {
  const candidates = [];
  const override = env.COMPOSITOR_GHOSTSCRIPT;
  if (override && path.isAbsolute(override)) candidates.push(override);
  if (platform === 'linux') return [...new Set([...candidates, '/usr/bin/gs', '/usr/local/bin/gs'])];
  // Do not search the current working directory or an untrusted PATH entry.
  for (const root of [env.ProgramFiles, env['ProgramFiles(x86)']].filter(Boolean)) {
    const directory = path.join(root, 'gs');
    let versions = []; try { versions = await readdir(directory, { withFileTypes: true }); } catch { /* Not installed here. */ }
    for (const version of versions.filter(v => v.isDirectory() && /^gs\d+(?:\.\d+){1,2}$/.test(v.name)).sort((a, b) => b.name.localeCompare(a.name, 'en', { numeric: true }))) {
      candidates.push(path.join(directory, version.name, 'bin/gswin64c.exe'));
    }
  }
  return candidates;
}
async function interpreter() {
  const candidates = await ghostscriptCandidates();
  for (const executable of candidates) {
    try {
      const version = await run(executable, ['--version'], undefined, 3000, true);
      if (Number(version.trim().split('.')[0]) >= 10) return executable;
    } catch { /* Try another installed version. */ }
  }
  throw new ProjectError('epsInterpreter');
}
function run(executable, args, directory, timeout, capture = false) {
  return new Promise((resolve, reject) => {
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.toUpperCase().startsWith('GS_')));
    if (directory) Object.assign(env, { TEMP: directory, TMP: directory });
    const child = spawn(executable, args, { shell: false, windowsHide: true, cwd: directory, env, stdio: ['ignore', capture ? 'pipe' : 'ignore', 'ignore'] });
    let output = '', expired = false;
    const timer = setTimeout(() => { expired = true; child.kill('SIGKILL'); }, timeout);
    child.stdout?.on('data', chunk => { if (output.length + chunk.length > 4096) { expired = true; child.kill('SIGKILL'); } else output += chunk; });
    child.once('error', () => { clearTimeout(timer); reject(new ProjectError('epsInterpreter')); });
    child.once('close', code => { clearTimeout(timer); if (expired) reject(new ProjectError('epsTimeout')); else if (code) reject(new ProjectError('epsRender')); else resolve(output); });
  });
}
export async function renderEPS(input, temporaryRoot = os.tmpdir()) {
  const section = postScriptSection(input), bounds = epsBounds(section), executable = await interpreter();
  const directory = await mkdtemp(path.join(temporaryRoot, 'compositor-eps-'));
  try {
    const source = path.join(directory, 'source.eps'), output = path.join(directory, 'render.png');
    await writeFile(source, section, { flag: 'wx', mode: 0o600 });
    await run(executable, ['-dSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET', '-dFIXEDMEDIA', '-sDEVICE=pngalpha',
      '-r144', `-g${bounds.width}x${bounds.height}`, '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
      '-dNumRenderingThreads=1', '-dMaxBitmap=67108864', '-dBufferSpace=8388608',
      `--permit-file-read=${source}`, `--permit-file-write=${output}`, `-sOutputFile=${output}`,
      '-c', `${(-bounds.x).toFixed(6)} ${(-bounds.y).toFixed(6)} translate`, '-f', source], directory, 30000);
    return await safeRead(output, EPS_LIMITS.bytes);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
