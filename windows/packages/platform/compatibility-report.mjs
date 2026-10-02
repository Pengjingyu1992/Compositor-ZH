const SOURCES = new Set(['engine', 'saved', 'none']);
const RUNTIME_ISSUES = new Set(['gpu', 'asset']);

// Whitelist aggregate values. Never serialize a manifest, path, name, ID, or
// unknown metadata into a report that the user may share outside the app.
export function compatibilityReport(project, appVersion, display) {
  if (!display || !SOURCES.has(display.source) || !Array.isArray(display.issues) || display.issues.length > 2 || display.issues.some(v => !RUNTIME_ISSUES.has(v))) throw new Error('Invalid display status');
  const { manifest, analysis, resources } = project;
  const issues = [...new Set([...analysis.issues, ...display.issues])];
  const source = display.source === 'engine' && issues.length ? 'none' : display.source === 'saved' && !project.preview ? 'none' : display.source;
  return {
    reportVersion: 1,
    application: { name: 'Compositor Windows', version: appVersion, readOnly: true },
    project: { formatVersion: manifest.version, width: manifest.width, height: manifest.height, colorSpace: manifest.colorSpace,
      layerCount: manifest.layers.length, groupCount: manifest.layers.filter(l => l.isGroup).length },
    resources: { count: resources.size, encodedBytes: project.sourceBytes.length + [...resources.values()].reduce((n, r) => n + r.bytes.length, 0), savedPreviewAvailable: project.preview },
    preview: { source, reasons: issues, estimatedWorkingBytes: analysis.estimatedBytes },
    potentialCoverage: { ...analysis.coverage },
    acceptance: { macOSGoldenImageVerified: false, realWindows10And11: 'pending' }
  };
}
