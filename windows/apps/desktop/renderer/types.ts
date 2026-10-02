export type Language = 'zh-Hans' | 'en';
export interface Placement {
  origin: [number, number]; size: [number, number]; rotation: number;
  flipX?: boolean; flipY?: boolean; sampling: string;
}
export interface LayerRow {
  id: string; name: string; isVisible: boolean; isGroup?: boolean;
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
      onOpen(callback: () => void): () => void;
      onFit(callback: () => void): () => void;
      onActual(callback: () => void): () => void;
    };
  }
}
