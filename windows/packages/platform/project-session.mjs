import { randomUUID } from 'node:crypto';
import { readProject } from '../comp-bridge/project.mjs';
import { editProject, newProject } from '../comp-bridge/edit.mjs';
import { fingerprint, saveProject } from './save-project.mjs';
import path from 'node:path';

export class ProjectSession {
  constructor(reader = readProject, options = {}) {
    this.reader = reader;
    this.current = null;
    this.pending = false;
    this.generation = 0;
    this.options = options;
    this.undoStack = []; this.redoStack = [];
    this.saved = null; this.revision = randomUUID();
  }

  view() {
    if (!this.current) return { canceled: true };
    const { id, data } = this.current;
    this.current.resources = [...data.resources.values()];
    const urls = Object.fromEntries([...data.resources.keys()].map((key, i) => [key, `compositor://app/project/${id}/${i}?revision=${this.revision}`]));
    return { project: { id, revision: this.revision, name: data.name, manifest: data.manifest, analysis: data.analysis, urls, preview: data.preview,
      dirty: data !== this.saved, canUndo: !!this.undoStack.length, canRedo: !!this.redoStack.length, hasLocation: !!this.current.location } };
  }

  install(data, location = null, saved = false) {
    clearTimeout(this.recoveryTimer); this.recoveryFailed = false;
    this.current = { id: randomUUID(), location, data, resources: [...data.resources.values()], fingerprint: location ? fingerprint(data) : null };
    this.revision = randomUUID(); this.saved = saved ? data : null;
    this.undoStack = []; this.redoStack = []; return this.view();
  }

  create(w, h) {
    if (this.pending) return { error: 'busy' };
    try { this.generation++; return this.install(newProject(w, h)); } catch (e) { return { error: e.code ?? 'invalid' }; }
  }

  edit(id, revision, op) {
    if (this.pending) return { error: 'busy' };
    if (!this.current || this.current.id !== id || revision !== this.revision) return { error: 'stale' };
    try {
      const before = this.current.data, after = editProject(before, op, this.options.codecs);
      if (before.sourceBytes.equals(after.sourceBytes) && fingerprint(before) === fingerprint(after)) return this.view();
      this.undoStack.push(before); this.redoStack = []; this.current.data = after; this.revision = randomUUID();
      // Count unique immutable buffers shared by snapshots, not logical copies.
      while (this.undoStack.length > 80 || this.historyBytes() > 256 * 1024 ** 2) { if (!this.undoStack.length) break; this.undoStack.shift(); }
      this.scheduleRecovery(); return this.view();
    } catch (e) { return { error: e.code ?? 'invalid' }; }
  }

  historyBytes() {
    const seen = new Set(); let size = 0;
    for (const data of [this.current?.data, ...this.undoStack, ...this.redoStack].filter(Boolean)) {
      size += data.sourceBytes.length;
      for (const r of data.resources.values()) if (!seen.has(r.bytes)) { seen.add(r.bytes); size += r.bytes.length; }
    }
    return size;
  }

  history(id, revision, direction) {
    if (this.pending) return { error: 'busy' };
    if (!this.current || this.current.id !== id || this.revision !== revision) return { error: 'stale' };
    if (!['undo', 'redo'].includes(direction)) return { error: 'invalid' };
    const source = direction === 'undo' ? this.undoStack : this.redoStack, dest = direction === 'undo' ? this.redoStack : this.undoStack;
    if (source.length) { dest.push(this.current.data); this.current.data = source.pop(); this.revision = randomUUID(); this.scheduleRecovery(); }
    return this.view();
  }

  scheduleRecovery() {
    clearTimeout(this.recoveryTimer);
    if (this.current && this.current.data !== this.saved && this.options.recovery) {
      const data = this.current.data, revision = this.revision;
      this.recoveryTimer = setTimeout(() => { this.options.recovery.write(data, revision).catch(() => { this.recoveryFailed = true; }); }, 800);
      this.recoveryTimer.unref?.();
    }
  }
  async flushRecovery() {
    clearTimeout(this.recoveryTimer);
    if (this.current && this.current.data !== this.saved && this.options.recovery) await this.options.recovery.write(this.current.data, this.revision);
  }

  async save(id, revision, choose) {
    if (this.pending) return { error: 'busy' };
    if (!this.current || this.current.id !== id || revision !== this.revision) return { error: 'stale' };
    this.pending = true;
    const own = this.generation, current = this.current, data = current.data;
    try {
      const selected = await choose(current);
      if (own !== this.generation || this.current !== current) return { canceled: true };
      if (!selected) return { canceled: true };
      const result = await saveProject(data, selected.location, selected.expected, this.options.journalDirectory);
      if (own !== this.generation || this.current !== current) return { canceled: true };
      current.location = result.destination; current.fingerprint = result.fingerprint;
      data.name = path.basename(result.destination);
      this.saved = data; clearTimeout(this.recoveryTimer);
      try { await this.options.recovery?.clear(data.manifest.documentID); } catch { this.recoveryFailed = true; }
      return { ...this.view(), backup: !!result.backup };
    } catch (e) { return { error: e.code ?? 'write' }; }
    finally { this.pending = false; }
  }

  async open(choose) {
    if (this.pending) return { error: 'busy' };
    this.pending = true;
    const own = ++this.generation;
    try {
      const location = await choose();
      if (own !== this.generation) return { canceled: true };
      if (!location) return { canceled: true };
      const data = await this.reader(location);
      if (own !== this.generation) return { canceled: true };
      return this.install(data, location, true);
    } catch (e) {
      return own !== this.generation ? { canceled: true } : { error: e.code ?? 'read' };
    } finally { this.pending = false; }
  }

  reload(id) {
    if (!this.current || this.current.id !== id) return Promise.resolve({ error: 'stale' });
    const location = this.current.location;
    return this.open(() => location);
  }

  close() {
    if (this.pending && this.current && this.current.data !== this.saved) return { closed: false, error: 'busy' };
    clearTimeout(this.recoveryTimer);
    this.generation++;
    this.current = null;
    return { closed: true };
  }
}
