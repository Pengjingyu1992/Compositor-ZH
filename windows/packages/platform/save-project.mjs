import { mkdir, open, rename, lstat, rm, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { readProject, safeDirectory, ProjectError, resourceDigests } from '../comp-bridge/project.mjs';

export function fingerprint(data) {
  return createHash('sha256').update(data.sourceBytes).update(JSON.stringify(Object.entries(resourceDigests(data)).sort(([a], [b]) => a.localeCompare(b)))).digest('hex');
}
const exists = async p => { try { return await lstat(p); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } };
async function durableFile(location, bytes) {
  const f = await open(location, 'wx');
  try { await f.writeFile(bytes); await f.sync(); } finally { await f.close(); }
}
async function retryRename(a, b) {
  for (let i = 0; ; i++) {
    try { await rename(a, b); return; }
    catch (e) {
      if (!['EPERM', 'EBUSY', 'EACCES'].includes(e.code) || i === 5) throw new ProjectError('occupied');
      await new Promise(resolve => setTimeout(resolve, 80 * 2 ** i));
    }
  }
}
async function syncDirectory(p) {
  // Windows may refuse directory fsync. File data and journal are still flushed;
  // do not describe the two directory renames as a single atomic transaction.
  try { const h = await open(p, 'r'); try { await h.sync(); } finally { await h.close(); } } catch (e) { if (!['EPERM', 'EACCES', 'EISDIR', 'EINVAL'].includes(e.code)) throw e; }
}
async function staged(data, stage) {
  await mkdir(stage);
  for (const [name, r] of data.resources) {
    const parts = name.split('/');
    if (parts.some(v => !v || v === '.' || v === '..' || /[\\:]/.test(v)) || name === 'manifest.json') throw new ProjectError('path');
    const location = path.join(stage, ...parts);
    await mkdir(path.dirname(location), { recursive: true });
    await durableFile(location, r.bytes);
  }
  await durableFile(path.join(stage, 'manifest.json'), data.sourceBytes);
  await syncDirectory(stage);
  const verified = await readProject(stage);
  if (fingerprint(data) !== fingerprint(verified)) throw new ProjectError('changed');
}
export async function saveProject(data, destination, expected = null, registry, hooks = {}) {
  if (typeof destination !== 'string' || path.extname(destination).toLowerCase() !== '.comp') throw new ProjectError('path');
  const parent = await safeDirectory(path.dirname(path.resolve(destination)));
  destination = path.join(parent, path.basename(destination));
  const st = await exists(destination);
  if (st && (!st.isDirectory() || st.isSymbolicLink())) throw new ProjectError('path');
  if (st && (!expected || fingerprint(await readProject(destination)) !== expected)) throw new ProjectError('changed');
  if (!st && expected) throw new ProjectError('changed');
  const token = randomUUID(), prefix = `.compositor-${token}`;
  const stage = path.join(parent, `${prefix}.stage.comp`), backup = path.join(parent, `${prefix}.backup.comp`), journal = path.join(parent, `${prefix}.save.json`);
  let registered = false, committed = false;
  try {
    await staged(data, stage);
    await hooks.afterStage?.();
    if (st && fingerprint(await readProject(destination)) !== expected) throw new ProjectError('changed');
    if (!st && await exists(destination)) throw new ProjectError('changed');
    const record = { schema: 1, token, destination, stage, backup, original: expected, next: fingerprint(data) };
    if (registry) {
      await mkdir(registry, { recursive: true }); await safeDirectory(registry);
      await durableFile(path.join(registry, `${token}.json`), Buffer.from(JSON.stringify({ journal })));
      registered = true;
    }
    await durableFile(journal, Buffer.from(JSON.stringify(record)));
    await syncDirectory(parent);
    await hooks.afterJournal?.();
    if (st) {
      if (fingerprint(await readProject(destination)) !== expected) throw new ProjectError('changed');
      await retryRename(destination, backup);
      if (fingerprint(await readProject(backup)) !== expected) throw new ProjectError('changed');
    }
    await hooks.afterBackup?.();
    // No overwriting an unrelated directory that appeared after our check.
    if (await exists(destination)) throw new ProjectError('changed');
    await retryRename(stage, destination); committed = true;
    await syncDirectory(parent);
    await hooks.afterCommit?.();
    await rm(journal); if (registered) await rm(path.join(registry, `${token}.json`));
    return { destination, backup: st ? backup : null, fingerprint: record.next };
  } catch (e) {
    if (!committed && await exists(backup) && !(await exists(destination))) {
      try { await retryRename(backup, destination); } catch { /* Keep durable journal and backup for startup recovery. */ }
    }
    // A durable journal owns its stage. Leave it for recovery if any rename ran.
    if (!(await exists(journal))) { await rm(stage, { recursive: true, force: true }); if (registered) await rm(path.join(registry, `${token}.json`), { force: true }); }
    throw e instanceof ProjectError ? e : new ProjectError('write');
  }
}

export async function recoverSaves(registry) {
  await mkdir(registry, { recursive: true }); await safeDirectory(registry);
  const results = [];
  for (const entry of await readdir(registry)) {
    if (!/^[a-f0-9-]{36}\.json$/.test(entry)) continue;
    try {
      const pointer = JSON.parse(await readFile(path.join(registry, entry), 'utf8'));
      const st = await lstat(pointer.journal);
      if (st.isSymbolicLink() || !st.isFile() || st.size > 16384) throw new Error();
      const r = JSON.parse(await readFile(pointer.journal, 'utf8')), parent = await safeDirectory(path.dirname(pointer.journal));
      if (r.schema !== 1 || `${r.token}.json` !== entry || pointer.journal !== path.join(parent, `.compositor-${r.token}.save.json`) || r.stage !== path.join(parent, `.compositor-${r.token}.stage.comp`) || r.backup !== path.join(parent, `.compositor-${r.token}.backup.comp`) || path.dirname(r.destination) !== parent || path.extname(r.destination).toLowerCase() !== '.comp') throw new Error();
      const destination = await exists(r.destination), backup = await exists(r.backup);
      if (!destination && backup && fingerprint(await readProject(r.backup)) === r.original) { await retryRename(r.backup, r.destination); results.push('restored'); }
      else if (destination) {
        const current = fingerprint(await readProject(r.destination));
        if (current !== r.next && current !== r.original) throw new Error();
        results.push(current === r.next ? 'committed' : 'restored');
      } else if (r.original) throw new Error();
      else results.push('canceled');
      // Only generated stages owned by this validated journal can be removed.
      const stage = await exists(r.stage);
      if (stage) { if (stage.isSymbolicLink()) throw new Error(); await readProject(r.stage); await rm(r.stage, { recursive: true }); }
      await rm(pointer.journal); await rm(path.join(registry, entry));
    } catch (e) {
      if (e.code === 'ENOENT') await rm(path.join(registry, entry), { force: true });
      else results.push('manual');
    }
  }
  return results;
}

export class RecoveryStore {
  constructor(directory) { this.directory = directory; this.queue = Promise.resolve(); }
  write(data, revision) {
    this.queue = this.queue.catch(() => {}).then(async () => {
      await mkdir(this.directory, { recursive: true }); await safeDirectory(this.directory);
      const key = `${data.manifest.documentID.toLowerCase()}-${revision.toLowerCase()}`, dest = path.join(this.directory, `${key}.comp`);
      if (!(await exists(dest))) await saveProject(data, dest);
      await durableFile(path.join(this.directory, `${key}.json`), Buffer.from(JSON.stringify({ schema: 1, formatVersion: data.manifest.version, revision, documentID: data.manifest.documentID, name: data.name, created: Date.now() }))).catch(e => { if (e.code !== 'EEXIST') throw e; });
      const items = await this.list();
      for (const old of items.filter(i => i.documentID === data.manifest.documentID).slice(2)) await this.remove(old.key);
    });
    return this.queue;
  }
  async list() {
    await mkdir(this.directory, { recursive: true }); await safeDirectory(this.directory);
    const items = [];
    for (const name of await readdir(this.directory)) if (/^[a-f0-9-]{73}\.json$/.test(name)) {
      try {
        const p = path.join(this.directory, name), s = await lstat(p);
        if (!s.isFile() || s.isSymbolicLink() || s.size > 16384) continue;
        const value = JSON.parse(await readFile(p, 'utf8'));
        if (value.schema === 1 && value.formatVersion >= 1 && value.formatVersion <= 11 && typeof value.name === 'string') items.push({ ...value, key: name.slice(0, -5) });
      } catch { /* Incomplete recovery metadata is not offered as a valid snapshot. */ }
    }
    return items.sort((a, b) => b.created - a.created);
  }
  async restore(key) {
    if (!/^[a-f0-9-]{73}$/.test(key)) throw new ProjectError('path');
    if (!(await this.list()).some(i => i.key === key)) throw new ProjectError('missing');
    return readProject(path.join(this.directory, `${key}.comp`));
  }
  async remove(key) {
    if (!/^[a-f0-9-]{73}$/.test(key)) throw new ProjectError('path');
    await rm(path.join(this.directory, `${key}.comp`), { recursive: true, force: true }); await rm(path.join(this.directory, `${key}.json`), { force: true });
  }
  async clear(documentID) { await this.queue.catch(() => {}); for (const i of await this.list()) if (i.documentID === documentID) await this.remove(i.key); }
}
