export type Language = 'zh-Hans' | 'en';
export interface NewCanvasDefinition { width: number; height: number; resolution: number; background: 'transparent' | 'white' | 'black' }
export interface Placement {
  origin: [number, number]; size: [number, number]; rotation: number;
  flipX?: boolean; flipY?: boolean; sampling: string;
}
export interface LayerRow {
  id: string; name: string; isVisible: boolean; isGroup?: boolean; parentID?: string;
  imageFile?: string; maskFile?: string; maskEnabled?: boolean;
  pixelSize?: [number,number]; maskPixelSize?: [number,number];
  maskSourceID?: string; maskLinked?: boolean; maskPlacement?: Placement;
  transform: Placement; opacity?: number; blendMode?: string;
  text?: Record<string, unknown>; shape?: Record<string, unknown>;
  editableFilters?: {sourceFile:string;nodeFiles:string[]};
  fill?: Record<string,any>; vectorMask?: Record<string,any>;
  adjustment?: Record<string, any>; effects?: Record<string, Record<string, any>>; depth: number;
  effectiveVisible: boolean; effectiveOpacity: number;
  category: 'simple' | 'pixels' | 'preview';
}
export interface AnimationTrack { frames: {groupID:string;durationMS:number}[]; loopCount:number }
export interface ViewerProject {
  id: string; name: string; preview: boolean; urls: Record<string, string>;
  selection?: {width:number;height:number;data:Uint8Array}|null;
  locks?: Record<string,Record<string,boolean>>;
  historyIndex?:number;historyEntries?:{index:number;kind:string;detail?:string}[];
  revision: string; dirty: boolean; canUndo: boolean; canRedo: boolean; hasLocation: boolean;
  manifest: { width: number; height: number; version: number; activeLayerID?: string; layers: LayerRow[]; animation?: AnimationTrack; resolution?: number; guides?:{id:string;axis:string;position:number}[] };
  analysis: { rows: LayerRow[]; issues: string[]; estimatedBytes: number;
    coverage: { simple: number; pixelFallback: number; previewOnly: number; total: number } };
}
export interface WorkspaceState{tabs:{id:string;projectID:string;name:string;dirty:boolean;active:boolean}[];activeID:string}
export interface RecentState{enabled:boolean;entries:{id:string;name:string;parent:string;time:number}[]}
export interface OpenResult {didSave?:boolean;recent?:RecentState;workspace?:WorkspaceState;changed?:boolean;signature?:string;missing?:boolean;closed?:boolean; copied?:boolean; project?: ViewerProject; canceled?: boolean; error?: string; backup?: boolean; exported?: boolean; warnings?: string[] }
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
      ready():Promise<Record<string,never>>;
      viewSettings(value?:Record<string,unknown>):Promise<{settings?:Record<string,any>;error?:string}>;
      settings(): Promise<{ language: Language; version: string; edition: 'linux' | 'windows' }>;
      language(value: Language): Promise<{ language: Language }>;
      open(): Promise<OpenResult>;
      drop(file: File): Promise<OpenResult>;
      dropFiles(files:File[],payload:{id?:string;revision?:string;targetID?:string;point?:number[]}):Promise<OpenResult>;
      cancelImport(jobID:string):Promise<Record<string,never>>;
      onImportProgress(callback:(value:{jobID:string;completed:number;total:number})=>void):()=>void;
      reload(id: string): Promise<OpenResult>;
      close(): Promise<OpenResult>;
      copyReport(id: string, display: { source: 'engine' | 'saved' | 'none'; issues: string[] }): Promise<{ copied?: boolean; error?: string }>;
      onOpen(callback: () => void): () => void;
      onReload(callback: () => void): () => void;
      onClose(callback: () => void): () => void;
      onFit(callback: () => void): () => void;
      onActual(callback: () => void): () => void;
    };
    editor: {
      workspace(action:string,payload?:Record<string,unknown>):Promise<OpenResult>;
      textTools(action:string,payload:Record<string,unknown>):Promise<{error?:string;png?:Uint8Array;fonts?:string[]}>;
      textClipboard(action:string):Promise<void>;
      clipboard(id:string,revision:string,action:string,png?:Uint8Array,info?:{targetID?:string;ids?:string[];origin?:number[]}):Promise<OpenResult>;
      create(w: number, h: number, options?: { resolution?: number; background?: NewCanvasDefinition['background'] }): Promise<OpenResult>;
      canvasClipboardSize(): Promise<{ width: number; height: number } | null>;
      edit(id: string, revision: string, op: Record<string, unknown>): Promise<OpenResult>;
      jumpHistory(id:string,revision:string,index:number):Promise<OpenResult>;
      history(id: string, revision: string, direction: string): Promise<OpenResult>;
      save(id: string, revision: string, as?: boolean): Promise<OpenResult>;
      importImage(id?: string, revision?: string,targetID?:string): Promise<OpenResult>;
      importPSD(): Promise<OpenResult>;
      batchExport(action:string,payload:Record<string,unknown>):Promise<{jobID?:string;targets?:{id:string|null;name:string}[];total?:number;completed?:number;exported?:boolean;folder?:string;canceled?:boolean;error?:string}>;
      onBatchProgress(callback:(value:{jobID:string;completed:number;total:number})=>void):()=>void;
      outputTools(action: string, payload: Record<string, unknown>): Promise<{error?:string;canceled?:boolean;profile?:string;png?:Uint8Array}>;
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
