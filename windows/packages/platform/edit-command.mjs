// Callers supply the document/revision they started with. Selection expansion
// belongs to the UI caller, never to this explicit-target submission gate.
export function editRejection(op, owner, current, state, finishingStroke = false) {
  if (!owner || !current || owner.id !== current.id || owner.revision !== current.revision) return 'stale';
  if (state.busy || (state.painting && !finishingStroke)) return 'busy';
  if ((state.source !== 'engine' || state.issues.length) && !['rename', 'lock', 'selection'].includes(op.kind)) return 'unsupported';
  return '';
}
