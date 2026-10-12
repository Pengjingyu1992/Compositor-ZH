import type { ViewerProject } from '../../apps/desktop/renderer/types';

function frameResolver(project: ViewerProject) {
  const groups = new Set(project.manifest.animation?.frames.map(f => f.groupID.toUpperCase()) ?? []);
  const byID = new Map(project.analysis.rows.map(l => [l.id.toUpperCase(), l]));
  return (id?: string): string | undefined => {
    let row = id ? byID.get(id.toUpperCase()) : undefined;
    for (let depth = 0; row && depth < 65; depth++, row = row.parentID ? byID.get(row.parentID.toUpperCase()) : undefined) {
      if (groups.has(row.id.toUpperCase())) return row.id;
    }
  };
}
export function frameForLayer(project: ViewerProject, id?: string): string | undefined { return frameResolver(project)(id); }
export function projectForFrame(project: ViewerProject, id?: string): ViewerProject {
  const track = project.manifest.animation;
  if (!track) return project;
  const current = (id ?? track.frames[0].groupID).toUpperCase(), resolve = frameResolver(project);
  return { ...project, manifest: {...project.manifest, animation:undefined}, analysis: { ...project.analysis, rows: project.analysis.rows.map(row => {
    const frame = resolve(row.id);
    return frame && frame.toUpperCase() !== current ? { ...row, effectiveVisible: false } : row;
  }) } };
}
