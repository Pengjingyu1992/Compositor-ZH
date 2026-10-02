import { randomUUID } from 'node:crypto';
import { readProject } from '../comp-bridge/project.mjs';

export class ProjectSession {
  constructor(reader = readProject) {
    this.reader = reader;
    this.current = null;
    this.pending = false;
    this.generation = 0;
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
      const id = randomUUID();
      const urls = Object.fromEntries([...data.resources.keys()].map((key, i) => [key, `compositor://app/project/${id}/${i}`]));
      this.current = { id, location, data, resources: [...data.resources.values()] };
      return { project: { id, name: data.name, manifest: data.manifest, analysis: data.analysis, urls, preview: data.preview } };
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
    this.generation++;
    this.current = null;
    return { closed: true };
  }
}
