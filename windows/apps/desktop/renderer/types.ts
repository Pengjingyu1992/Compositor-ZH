export type Language = 'zh-Hans' | 'en';
export interface Placement {
  origin: [number, number]; size: [number, number]; rotation: number;
  flipX?: boolean; flipY?: boolean; sampling: string;
}
export interface LayerRow {
  id: string; name: string; isVisible: boolean; isGroup?: boolean; parentID?: string;
  imageFile?: string; maskFile?: string; maskEnabled?: boolean;
  maskSourceID?: string; maskLinked?: boolean; maskPlacement?: Placement;
  transform: Placement; opacity?: number; blendMode?: string;
  text?: Record<string, unknown>; shape?: Record<string, unknown>;
  adjustment?: Record<string, any>; effects?: Record<string, Record<string, any>>; depth: number;
  effectiveVisible: boolean; effectiveOpacity: number;
  category: 'simple' | 'pixels' | 'preview';
}
export interface ViewerProject {
  id: string; name: string; preview: boolean; urls: Record<string, string>;
  selection?: {width:number;height:number;data:Uint8Array}|null;
  locks?: Record<string,Record<string,boolean>>;
  revision: string; dirty: boolean; canUndo: boolean; canRedo: boolean; hasLocation: boolean;
  manifest: { width: number; height: number; version: number; layers: LayerRow[]; resolution?: number; guides?:{id:string;axis:string;position:number}[] };
  analysis: { rows: LayerRow[]; issues: string[]; estimatedBytes: number;
    coverage: { simple: number; pixelFallback: number; previewOnly: number; total: number } };
}
export interface OpenResult { copied?:boolean; project?: ViewerProject; canceled?: boolean; error?: string; backup?: boolean; exported?: boolean; warnings?: string[] }
// The layer fields the assistant needs. Sending these instead of whole
// LayerRows keeps pixel data out of the IPC message.
export interface AssistantLayer {
  id: string; name: string; isVisible: boolean; opacity?: number; blendMode?: string;
  isGroup?: boolean; parentID?: string; adjustment?: { kind: string }; maskFile?: string;
}
export interface AiSettings { endpoint: string; model: string; hasKey: boolean; encryption: boolean }
export interface AiAnswer { reply?: string; operations?: Record<string, unknown>[]; error?: string; status?: number }
declare global {
  interface Window {
    viewer: {
      settings(): Promise<{ language: Language; version: string }>;
      language(value: Language): Promise<{ language: Language }>;
      open(): Promise<OpenResult>;
      drop(file: File): Promise<OpenResult>;
      reload(id: string): Promise<OpenResult>;
      close(): Promise<{ closed: boolean; error?: string }>;
      copyReport(id: string, display: { source: 'engine' | 'saved' | 'none'; issues: string[] }): Promise<{ copied?: boolean; error?: string }>;
      onOpen(callback: () => void): () => void;
      onReload(callback: () => void): () => void;
      onClose(callback: () => void): () => void;
      onFit(callback: () => void): () => void;
      onActual(callback: () => void): () => void;
    };
    editor: {
      textClipboard(action:string):Promise<void>;
      clipboard(id:string,revision:string,action:string,png?:Uint8Array):Promise<OpenResult>;
      create(w: number, h: number): Promise<OpenResult>;
      edit(id: string, revision: string, op: Record<string, unknown>): Promise<OpenResult>;
      history(id: string, revision: string, direction: string): Promise<OpenResult>;
      save(id: string, revision: string, as?: boolean): Promise<OpenResult>;
      importImage(id: string, revision: string): Promise<OpenResult>;
      importPSD(): Promise<OpenResult>;
      export(id: string, revision: string, type: string, payload: Record<string, unknown>): Promise<OpenResult>;
      recover(): Promise<OpenResult>;
      onCommand(name: string, callback: () => void): () => void;
    };
    ai: {
      settings(): Promise<AiSettings>;
      save(settings: { endpoint: string; model: string; key?: string | null }): Promise<AiSettings>;
      complete(prompt: string, layers: AssistantLayer[]): Promise<AiAnswer>;
      test(settings: { endpoint: string; model: string; key?: string }): Promise<AiAnswer & { endpoint?: string; model?: string }>;
    };
  }
}
