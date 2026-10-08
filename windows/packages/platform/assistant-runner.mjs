import { checkOperation, canonicalOperation, MAX_OPERATIONS } from './ai-assistant.mjs';

// Only this request's successful commits may advance its revision. A document
// switch or any concurrent manual edit invalidates the remaining answer.
export async function runAssistant({ prompt, getProject, complete, prepare, execute, report, canceled = () => false }) {
  const project = getProject();
  if (!project) return;
  let owner = { id: project.id, revision: project.revision };
  const valid = () => !canceled() && getProject()?.id === owner.id && getProject()?.revision === owner.revision;
  const stale = () => report({ type: 'error', scope: 'editor', error: 'stale' });
  const layers = project.manifest.layers.map(l => ({
    id: l.id, name: l.name, isVisible: l.isVisible, opacity: l.opacity,
    blendMode: l.blendMode, isGroup: l.isGroup, parentID: l.parentID,
    adjustment: l.adjustment ? { kind: l.adjustment.kind } : undefined, maskFile: l.maskFile
  }));
  const answer = await complete(prompt, layers);
  if (!valid()) { stale(); return; }
  if (answer.error) { report({ type: 'error', scope: 'ai', ...answer }); return; }
  if (answer.reply) report({ type: 'reply', text: answer.reply });
  const operations = answer.operations ?? [];
  if (!operations.length) report({ type: 'empty' });
  for (const operation of operations.slice(0, MAX_OPERATIONS)) {
    if (!valid()) { stale(); return; }
    const current = getProject(), liveLayers = current.manifest.layers;
    const reason = checkOperation(operation, liveLayers);
    if (reason) { report({ type: 'skip', operation, reason }); continue; }
    let prepared = canonicalOperation(operation, liveLayers);
    try {
      if (prepared.kind === 'styled') prepared = await prepare(prepared, current);
    } catch (error) {
      if (!valid()) { stale(); return; }
      report({ type: 'rejected', operation, error: error?.message === 'limit' ? 'limit' : 'invalid' });
      continue;
    }
    if (!valid()) { stale(); return; }
    const result = await execute(prepared, { ...owner });
    if (result.error) {
      report({ type: 'rejected', operation, error: result.error });
      if (['stale', 'busy', 'unsupported'].includes(result.error)) return;
      continue;
    }
    if (!result.project || result.project.id !== owner.id) { stale(); return; }
    const changed = result.project.revision !== owner.revision;
    owner = { id: result.project.id, revision: result.project.revision };
    if (!valid()) { stale(); return; }
    report({ type: changed ? 'applied' : 'unchanged', operation });
  }
}
