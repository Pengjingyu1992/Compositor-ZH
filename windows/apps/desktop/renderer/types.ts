export type Language = 'zh-Hans' | 'en';
export interface Placement {
  origin: [number, number]; size: [number, number]; rotation: number;
  flipX?: boolean; flipY?: boolean; sampling: string;
}
export interface LayerRow {
  id: string; name: string; isVisible: boolean; isGroup?: boolean; parentID?: string;
  imageFile?: string; maskFile?: string; maskEnabled?: boolean;
  transform: Placement; opacity?: number; blendMode?: string;
  text?: Record<string, unknown>; shape?: Record<string, unknown>;
  adjustment?: Record<string, unknown>; depth: number;
  effectiveVisible: boolean; effectiveOpacity: number;
  category: 'simple' | 'pixels' | 'preview';
}
export interface ViewerProject {
  id: string; name: string; preview: boolean; urls: Record<string, string>;
  manifest: { width: number; height: number; version: number; layers: LayerRow[]; resolution?: number };
  analysis: { rows: LayerRow[]; issues: string[]; estimatedBytes: number;
    coverage: { simple: number; pixelFallback: number; previewOnly: number; total: number } };
}
export interface OpenResult { project?: ViewerProject; canceled?: boolean; error?: string }
declare global {
  interface Window {
    viewer: {
      settings(): Promise<{ language: Language; version: string }>;
      language(value: Language): Promise<{ language: Language }>;
      open(): Promise<OpenResult>;
      drop(file: File): Promise<OpenResult>;
      reload(id: string): Promise<OpenResult>;
      close(): Promise<{ closed: boolean }>;
      copyReport(id: string, display: { source: 'engine' | 'saved' | 'none'; issues: string[] }): Promise<{ copied?: boolean; error?: string }>;
      onOpen(callback: () => void): () => void;
      onReload(callback: () => void): () => void;
      onClose(callback: () => void): () => void;
      onFit(callback: () => void): () => void;
      onActual(callback: () => void): () => void;
    };
  }
}
