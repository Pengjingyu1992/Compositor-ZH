import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// The Layers panel's width, remembered across launches.
    @AppStorage("layersPanelWidth") private var layersPanelWidth = 280.0
    @AppStorage("navigator.visible") private var showsNavigator = false
    @Bindable var session: EditorSession
    var applicationDelegate: CompositorApplicationDelegate? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var canvasFrame: CGRect = .zero
    @State private var levelsPanel = FloatingPanelController(name: "levelsPanel")
    @State private var adjustmentPanel = FloatingPanelController(name: "adjustmentPanel")
    @State private var selectionAmountPanel = FloatingPanelController(name: "selectionAmountPanel")
    @State private var colorRangePanel = FloatingPanelController(name: "colorRangePanel")
    @State private var filterPanel = FloatingPanelController(name: "filterPanel")
    @State private var effectsPanel = FloatingPanelController(name: "effectsPanel")
    @State private var isDropTargeted = false
    @State private var showsToolHelp = false
    @State private var showsInspectorPopover = false
    @AppStorage("inspector.visible") private var showsInspector = true
    @AppStorage("interface.appearance") private var appearance = InterfaceAppearance.system.rawValue
    private var inspectorInline: Bool { showsInspector && windowWidth >= 1060 }
    /// The window's width, so the tab strip can use the toolbar's free space.
    @State private var windowWidth: CGFloat = 1180
    @State private var navigationControlsWidth: CGFloat = 96
    @State private var actionControlsWidth: CGFloat = 272
    private var actionToolbarWidth: CGFloat { inspectorInline ? layersPanelWidth - 8 : 272 }
    private var actionToolbarSpacing: CGFloat { applicationDelegate?.mcp.enabled == true ? 6 : 10 }
    private var availableTabWidth: CGFloat {
        // Native window buttons, toolbar margins, and gaps between the three groups.
        max(140, windowWidth - navigationControlsWidth - actionControlsWidth - 124)
    }
    /// A layer dragged from this canvas's own tab has nowhere to go, so the canvas doesn't light up for it.
    private var acceptsDrop: Bool {
        guard let workspace = applicationDelegate?.workspace else { return true }
        return workspace.canReceiveDrag(into: workspace.current.id)
    }
    // Extracted from `body`: as one expression the type checker times out (Xcode 26.1).
    @ViewBuilder private var rawToolHeaders: some View {
        Group {
            if session.tool == .move {
                TransformInspector(session: session).id(session.activeLayerID)
            }
            if session.tool.isBrushTool {
                BrushControls(session: session)
            }
            if session.tool.isSelectionTool {
                LassoControls(session: session)
            }
            if session.tool == .gradient {
                GradientControls(session: session)
            }
            if session.tool == .bucket {
                PaintBucketControls(session: session)
            }
            if session.tool == .type {
                TypeControls(session: session)
            }
            if session.tool == .shape {
                ShapeControls(session: session)
            }
            if session.tool == .pen {
                PathControls(session: session)
            }
            if session.tool == .eyedropper {
                HStack(spacing: 8) {
                    Text("Eyedropper").font(ToolHeaderStyle.titleFont)
                    Toggle("Sample Ring", isOn: $session.showsSampleRing).toggleStyle(.checkbox)
                    Spacer()
                }.padding(.horizontal, 10).toolHeaderBar()
            }
            if session.tool == .hand || session.tool == .zoom {
                NavigationToolHeader(session: session)
            }
            if session.tool == .crop {
                CropControls(session: session)
            }
            // No tool (A) keeps the header, so the canvas doesn't jump.
            if session.tool == .idle {
                HStack(spacing: 8) {
                    Text("Select a tool").font(ToolHeaderStyle.titleFont)
                    Spacer()
                }.padding(.horizontal, 10).toolHeaderBar()
            }
        }
    }

    private var toolHeaders: some View {
        rawToolHeaders.frame(height: ToolHeaderStyle.height)
    }

    @ViewBuilder private var editorStack: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !session.canvasOnly {
                    toolRail
                    Divider()
                }
                VStack(spacing: 0) {
                    if !session.canvasOnly {
                        if session.document == nil {
                            HStack { Text("Create a canvas or import an image.").foregroundStyle(.secondary); Spacer() }
                                .padding(.horizontal, 14).toolHeaderBar().background(EditorTheme.optionsBackground, ignoresSafeAreaEdges: [])
                        } else {
                            toolHeaders.background(EditorTheme.optionsBackground, ignoresSafeAreaEdges: [])
                        }
                        Divider()
                    }
                    if session.showsRulers, session.document != nil, !session.canvasOnly {
                        HStack(spacing: 0) {
                            CanvasRulerCorner()
                            CanvasRulerView(session: session, axis: .horizontal)
                                .frame(height: CanvasRuler.thickness)
                        }
                    }
                    HStack(spacing: 0) {
                        if session.showsRulers, session.document != nil, !session.canvasOnly {
                            CanvasRulerView(session: session, axis: .vertical)
                                .frame(width: CanvasRuler.thickness)
                        }
                        ZStack {
                            EditorCanvas(session: session)
                                .overlay(alignment: .topLeading) { PrintProofBadge(session: session) }
                            if session.document == nil { welcome }
                            if let layer = session.maskAloneLayer {
                                // At the foot of the canvas, clear of the transform box's rotation handle.
                                MaskAloneBadge(session: session, layer: layer).fixedSize()
                                    .padding(.bottom, 14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            if showsNavigator, !session.canvasOnly, session.viewport.zoom >= NavigatorMinimap.zoomShown {
                                NavigatorMinimap(session: session)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { canvasFrame = $0 }
                    }
                }
                if !session.canvasOnly, inspectorInline {
                    PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                    LayersPanel(session: session, width: layersPanelWidth)
                }
            }
            if !session.canvasOnly {
                Divider()
                AnimationTimeline(session: session)
                // Keeps its own height however short the window gets; the tools scroll instead.
                statusBar.fixedSize(horizontal: false, vertical: true)
                    .modifier(WidthReader(width: $windowWidth))
            }
        }
        .overlay(alignment: .top) {
            if !session.canvasOnly {
                Divider().allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    // Split again for 1.1: the chain outgrew the type checker once more.
    @ViewBuilder private var editorChrome: some View {
        editorStack
        .background(EditorTheme.workspaceBackground, ignoresSafeAreaEdges: [])
        .background {
            if let applicationDelegate, applicationDelegate.projects.workspace == nil {
                ProjectWindowBridge(controller: applicationDelegate.projects).frame(width: 0, height: 0)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .coordinateSpace(name: "editor")
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], isTargeted: $isDropTargeted) { providers, location in
            guard session.levels == nil, !session.isProjectBusy, !session.showsNewDocument, !session.showsImporter, session.renamingLayerID == nil else { return false }
            let point: CGPoint?
            if let document = session.document, canvasFrame.contains(location) {
                point = session.viewport.documentPoint(
                    from: CGPoint(x: location.x - canvasFrame.minX, y: location.y - canvasFrame.minY),
                    documentSize: document.size)
            } else { point = nil }
            if let workspace = applicationDelegate?.workspace {
                let destination = workspace.current.id
                guard workspace.canSwitch, workspace.canReceiveDrag(into: destination) else { return false }
                Task { await workspace.receiveProviders(providers, into: destination, at: point) }
            } else {
                Task { await ImageFileDrop.importProviders(providers, into: session, at: point) }
            }
            return true
        }
        .overlay {
            if isDropTargeted, acceptsDrop {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, canvasFrame.width - 6), height: max(0, canvasFrame.height - 6))
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { layersPanelWidth = min(320, max(260, layersPanelWidth)); applicationDelegate?.showEditor = { openWindow(id: "editor") } }
        .preferredColorScheme(InterfaceAppearance(rawValue: appearance)?.scheme)
        // Canvas Only (F): the canvas runs up under where the title bar was, so no gray strip is left across the top.
        // The toolbar itself is hidden and shown by the window (see `toggleCanvasOnly`), which lays its buttons out
        // again properly; hidden here instead, it came back with the tabs over the window buttons.
        .ignoresSafeArea(.container, edges: session.canvasOnly ? .top : [])
        .navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? L10n.text("Untitled"))
        .toolbar { navigationToolbar; actionToolbar }
        .toolbarBackground(EditorTheme.optionsBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }

    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Button { requestNewCanvas() } label: { Label("New canvas", systemImage: "plus") }
                    .help(L10n.format("New canvas (%@)", ShortcutSettings.shared.keyLabel("n", 1, menu: true))).accessibilityIdentifier("newCanvasToolbar")
                    .disabled(session.isImporting || session.showsBusy || session.levels != nil)
                    .accessibilityLabel("New canvas")
                    .modifier(NewProjectDropTarget(workspace: applicationDelegate?.workspace))
                Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!session.canUndo).help("Undo").accessibilityLabel("Undo")
                Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!session.canRedo).help("Redo").accessibilityLabel("Redo")
            }
            .labelStyle(.iconOnly).controlSize(.small)
            .accessibilityElement(children: .contain)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { navigationControlsWidth = $0 }
        }
        if let workspace = applicationDelegate?.workspace {
            ToolbarItem(placement: .navigation) {
                ProjectTabStrip(workspace: workspace)
                    .frame(width: ProjectTabStrip.preferredWidth(workspace, available: availableTabWidth), height: 34, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarSpacer(.flexible, placement: .navigation)
    }

    @ToolbarContentBuilder private var actionToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: actionToolbarSpacing) {
                Button { session.fit() } label: {
                    Text("Fit").frame(minWidth: 30, maxWidth: .infinity, minHeight: 24)
                }.help(L10n.format("Fit canvas in window (%@)", ShortcutSettings.shared.keyLabel("0", 1, menu: true)))
                    .accessibilityIdentifier("fitCanvas").accessibilityLabel("Fit").disabled(session.document == nil)
                Button { session.zoom(to: 1) } label: {
                    Text(Double(session.viewport.zoom).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().frame(minWidth: 44, maxWidth: .infinity, minHeight: 24)
                }.help(L10n.format("Actual pixels (%@)", ShortcutSettings.shared.keyLabel("1", 1, menu: true)))
                    .accessibilityIdentifier("actualPixels")
                    .accessibilityLabel(Double(session.viewport.zoom).formatted(.percent.precision(.fractionLength(0))))
                    .disabled(session.document == nil)
                Button {
                    if windowWidth < 1060 { showsInspectorPopover.toggle() } else { showsInspector.toggle() }
                } label: { Label("Inspector", systemImage: "sidebar.right").frame(minWidth: 24, maxWidth: .infinity, minHeight: 24) }
                    .help("Inspector").accessibilityLabel("Inspector").accessibilityIdentifier("inspectorToggle")
                    .popover(isPresented: $showsInspectorPopover) { LayersPanel(session: session, width: 280).frame(height: 440) }
                MCPStatusView(service: applicationDelegate?.mcp)
                Button { Task { await applicationDelegate?.projects.exportAs() } } label: { Label("Export", systemImage: "square.and.arrow.up").frame(minWidth: 24, maxWidth: .infinity, minHeight: 24) }
                    .disabled(session.document == nil || !session.canStartProjectOperation).help("Export").accessibilityLabel("Export")
                Button { session.zoomKeyboard(by: 1) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass").frame(minWidth: 24, maxWidth: .infinity, minHeight: 24)
                }.accessibilityLabel(L10n.text("Zoom In"))
                    .help(L10n.format("Zoom in (%@)", ShortcutSettings.shared.keyLabel("=", 1, menu: true))).disabled(session.document == nil)
                Button { session.zoomKeyboard(by: -1) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass").frame(minWidth: 24, maxWidth: .infinity, minHeight: 24)
                }.accessibilityLabel(L10n.text("Zoom Out"))
                    .help(L10n.format("Zoom out (%@)", ShortcutSettings.shared.keyLabel("-", 1, menu: true))).disabled(session.document == nil)
            }
            .labelStyle(.iconOnly).controlSize(.small).buttonStyle(.plain)
            .padding(.horizontal, 6).frame(width: actionToolbarWidth, height: 28)
            .glassEffect(.regular, in: Capsule())
            .accessibilityElement(children: .contain)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionControlsWidth = $0 }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var editorPanels: some View {
        editorChrome
        .sheet(isPresented: $session.showsAutomation) { AutomationSheet(session: session) }
        .sheet(isPresented: Binding(get: { session.filterStackEdit != nil }, set: { if !$0 { session.cancelFilterStack() } }), onDismiss: { session.openQueuedLiquify() }) {
            if let edit = session.filterStackEdit { FilterStackSheet(session: session, edit: edit) }
        }
        .sheet(item: Binding(get: { session.batchExportDraft }, set: { if $0 == nil { session.cancelBatchExport() } })) { draft in BatchExportSheet(session: session, draft: draft) }
        .sheet(isPresented: Binding(get: { session.edgeRefinement != nil }, set: { if !$0 { session.cancelEdgeRefinement() } })) {
            if let edit = session.edgeRefinement { EdgeRefinementSheet(session: session, edit: edit) }
        }
        .sheet(item: Binding(get: { session.fillLayerDraft }, set: { if $0 == nil { session.cancelFillLayer() } })) { draft in FillLayerSheet(session: session, draft: draft) }
        .sheet(isPresented: Binding(get: { session.liquify != nil }, set: { if !$0 { session.cancelLiquify() } })) {
            if let edit = session.liquify { LiquifySheet(session: session, edit: edit) }
        }
        .onChange(of: session.levels == nil) { _, closed in
            if closed { levelsPanel.close() }
            else {
                levelsPanel.onClose = { session.cancelLevels() }
                levelsPanel.show(title: L10n.text("Levels"), content: LevelsSheet(session: session))
            }
        }
        .onChange(of: session.colorRange == nil) { _, closed in
            if closed { colorRangePanel.close() }
            else {
                colorRangePanel.onClose = { session.cancelColorRange() }
                colorRangePanel.show(title: "Color Range", content: ColorRangeSheet(session: session))
            }
        }
        .onChange(of: session.hueSaturation == nil) { _, closed in
            if closed { adjustmentPanel.close() }
            else {
                adjustmentPanel.onClose = { session.cancelHueSaturation() }
                adjustmentPanel.show(title: L10n.text("Hue/Saturation"), content: HueSaturationSheet(session: session))
            }
        }
        .onChange(of: session.effectsEditing) { _, selection in
            if let selection {
                effectsPanel.onClose = { session.finishEffectsEditing(commit: false) }
                effectsPanel.show(title: L10n.text(selection.kind.rawValue), content: EffectsSheet(session: session, kind: selection.kind))
            } else { effectsPanel.close() }
        }
        .onChange(of: session.document?.layers) { _, layers in
            if let editing = session.effectsEditing,
               layers?.first(where: { $0.id == editing.layerID })?.effects?.contains(editing.kind) != true {
                if let picker = session.colorPicker, case .effect = picker.target { session.closeColorPicker(commit: false) }
                session.effectsEditing = nil
                session.effectsEditingOriginal = nil
            }
        }
        .onChange(of: session.selectionAmountOperation) { _, operation in
            if let operation {
                selectionAmountPanel.onClose = { session.selectionAmountOperation = nil }
                selectionAmountPanel.show(title: L10n.format("%@ Selection", L10n.text(operation.rawValue)),
                    content: SelectionAmountSheet(session: session, operation: operation))
            } else { selectionAmountPanel.close() }
        }
        // Last Filter applies without the panel.
        .onChange(of: session.filterEdit == nil || session.filterEdit?.repeating == true) { _, closed in
            if closed || session.filterEdit?.repeating == true { filterPanel.close() }
            else {
                filterPanel.onClose = { session.cancelFilter() }
                let placement: FloatingPanelPlacement = session.filterEdit?.kind == .cameraRaw ? .dockedToMainWindowRight : .automatic
                filterPanel.show(title: L10n.text(session.filterEdit?.kind.rawValue ?? "Filter"), content: FilterSheet(session: session),
                                 placement: placement)
            }
        }
        .onChange(of: session.document == nil) { _, empty in
            if !empty { session.canvasFocusRequest += 1 }
        }
    }

    private var editorImport: some View {
        editorPanels
        .modifier(PrintSetupPresentation(session: session))
        .fileImporter(isPresented: $session.showsImporter,
                      allowedContentTypes: UTType.importableImages, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await session.importImages(urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.importError = error.localizedDescription }
            }
        }
    }

    var body: some View {
        editorImport
        .background(ImportErrorAlert(message: $session.importError))
        .alert("Couldn’t paint", isPresented: Binding<Bool>(get: { session.brushError != nil },
            set: { if !$0 { session.brushError = nil } })) {
                Button("OK") { session.brushError = nil }
            } message: { Text(session.brushError ?? "") }
        .alert("Couldn’t arrange layers", isPresented: Binding<Bool>(get: { session.arrangeError != nil },
            set: { if !$0 { session.arrangeError = nil } })) {
                Button("OK") { session.arrangeError = nil }
            } message: { Text(session.arrangeError ?? "") }
        .alert("Couldn’t crop", isPresented: Binding<Bool>(get: { session.cropError != nil },
            set: { if !$0 { session.cropError = nil } })) {
                Button("OK") { session.cropError = nil }
            } message: { Text(session.cropError ?? "") }
    }
    private func requestNewCanvas() {
        if let applicationDelegate { Task { await applicationDelegate.projects.newCanvas() } }
        else { session.clearProject() }
    }
    private var toolRail: some View {
        // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
        VStack(spacing: 0) {
        IndicatorlessScrollView(scrollTarget: NavigationTool.allCases.filter { $0 != .idle && $0 != .hand && $0 != .zoom }.firstIndex(of: session.tool)) {
        VStack(spacing: 4) {
            ForEach(NavigationTool.allCases.filter { $0 != .idle && $0 != .hand && $0 != .zoom }, id: \.self) { tool in
                toolButton(tool)
            }
        }.padding(.vertical, 10).frame(width: EditorTheme.Metrics.toolRailWidth)
        }
        VStack(spacing: 6) {
            Divider().padding(.horizontal, 12)
            toolButton(.hand)
            toolButton(.zoom)
            ColorPaletteControls(session: session).padding(.top, 6).padding(.bottom, 12)
        }
        }.frame(width: EditorTheme.Metrics.toolRailWidth)
    }
    private func toolButton(_ tool: NavigationTool) -> some View {
                Button { session.selectTool(tool) } label: {
                    Group {
                        if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                        else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                        else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                        else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                        // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                        else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
                    }
                    .frame(width: EditorTheme.Metrics.toolButtonSize, height: EditorTheme.Metrics.toolButtonSize)
                        .background(session.tool == tool ? EditorTheme.selectedToolFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(session.tool == tool ? EditorTheme.selectedToolBorder : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(tool.label).accessibilityLabel(tool.label)
                .foregroundStyle(session.tool == tool ? Color.white : Color.primary)
                .accessibilityIdentifier("tool-" + String(describing: tool))
                .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }
    private var welcome: some View {
        NewCanvasSheet(session: session,
            onCreate: { session.createNewProject(width: $0, height: $1, resolution: $2, background: $3) },
            onOpen: { Task { await applicationDelegate?.projects.open() } })
    }
    private var statusBar: some View {
        HStack(spacing: 16) {
            if let document = session.document {
                Text("\(document.width) × \(document.height) px").accessibilityIdentifier("canvasDimensions")
                Text("sRGB · 8-bit RGBA").fixedSize()
                Text("\(Int(document.resolution)) DPI").fixedSize()
            } else { Text("Ready when you are") }
            if session.history.droppedLatestUndo {
                Text("Undo unavailable: this edit exceeded the history memory budget.")
                    .foregroundStyle(.orange).accessibilityIdentifier("historyBudgetWarning")
            }
            if session.recovery != nil, session.document != nil { RecoveryProtectionView(session: session) }
            Spacer()
            if session.showsBusy {
                ProgressView().controlSize(.mini)
                Text("Working…")
            } else if session.isImporting {
                ProgressView().controlSize(.mini)
                Text(L10n.text(session.importCancelRequested ? "Canceling import…" : "Importing images…"))
                Button("Cancel Import") { session.cancelImport() }
                    .buttonStyle(.plain).disabled(session.importCancelRequested)
                    .help("Keep completed imports; cancel the unfinished file and queued images.")
            } else if session.document != nil {
                Text(L10n.text(session.isModified ? "Unsaved Changes" : "Saved"))
                    .accessibilityIdentifier("saveStatus")
                Button { showsToolHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).help("Tool Help").accessibilityLabel("Tool Help")
                    .accessibilityIdentifier("toolHelp")
                    .popover(isPresented: $showsToolHelp) {
                        Text(toolHelp).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .padding(16).frame(width: 320)
                    }
            }
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 26)
        .accessibilityElement(children: .contain)
    }

    private var shortToolHelp: String { toolHelp.components(separatedBy: " · ").first ?? toolHelp }

    private var toolHelp: String {
        let keys = ShortcutSettings.shared
        let pan = L10n.format("Hold %@ to pan", keys.keyLabel(" "))
        let cancel = L10n.format("%@ cancel", keys.keyLabel("\u{1b}"))
        let apply = L10n.format("%@ apply", keys.keyLabel("\r"))
        let brush = L10n.format("%@ / %@ size · %@ / %@ hardness", keys.keyLabel("["), keys.keyLabel("]"), keys.keyLabel("[", 8), keys.keyLabel("]", 8))
        let selection = L10n.format("Shift add · Option subtract · Drag inside to move · %@ clears · %@ deselect", keys.keyLabel("\u{7f}"), keys.keyLabel("d", 1, menu: true))
        let mode = L10n.format("%@ for the next mode", keys.keyLabel("\t"))
        let parts: [String]
        switch session.tool {
        case .marquee:
            parts = [L10n.text(session.marqueeKind == .ellipse ? "Drag an ellipse · Shift again mid-drag for a circle" : "Drag a rectangle · Shift again mid-drag for a square"), selection]
        case .wand:
            parts = [L10n.text(session.wandMode == .object ? "Click an object to select its outline" : "Click to select similar colors"), mode, selection]
        case .lasso:
            parts = session.lassoKind == .freehand
                ? [L10n.text("Drag to select"), selection, L10n.format("%@ / %@ fill", keys.keyLabel("\u{7f}", 2, menu: true), keys.keyLabel("\u{7f}", 1, menu: true))]
                : [L10n.format("Click corners · Click start, double-click or %@ to close · %@ removes corner", keys.keyLabel("\r"), keys.keyLabel("\u{7f}")), cancel]
        case .brush:
            parts = [L10n.text(session.brushMode == .erase ? "Drag to erase" : "Drag to paint"), brush, keys.opacityHelp, cancel, pan]
        case .blur:
            parts = [L10n.text(session.blurMode == .blur ? "Drag to soften" : session.blurMode == .smudge ? "Drag to smudge" : "Drag to push pixels"), brush, keys.opacityHelp, pan]
        case .cloneStamp:
            parts = [L10n.text("Option-click to set the source · Drag to clone"), brush, keys.opacityHelp, pan]
        case .spotHealing:
            parts = [L10n.text("Drag over blemishes to heal"), brush, cancel, pan]
        case .type:
            parts = [L10n.format("Drag a text box · Click text to edit · Drag box handles to resize · %@ finish", keys.keyLabel("\r", 1)), cancel]
        case .shape:
            parts = [L10n.format("Drag to draw a shape on a new layer · Shift %@ · Option from center · %@ or %@ for the next shape", L10n.text(session.shapeKind == .line ? "45°" : session.shapeKind == .rectangle ? "square" : "circle"), keys.keyLabel("u", 8), keys.keyLabel("\t")), cancel, pan]
        case .pen:
            parts = [L10n.text("Click to add anchors · Drag for curves · Click the first anchor to close · Option breaks handles · Return applies · Delete removes an anchor"), cancel, pan]
        case .bucket:
            parts = [L10n.format("Click to fill similar colors · Option uses background color · %@ selects Paint Bucket", keys.keyLabel("k"))]
        case .gradient:
            parts = [L10n.text("Drag to draw · Drag ends to adjust · Shift 45°"), keys.opacityHelp, apply, cancel]
        case .crop: parts = [L10n.text("Drag to crop"), apply, cancel, pan]
        case .move: parts = [L10n.text("Drag to move · Handles to resize · Circle to rotate"), keys.opacityHelp, pan]
        case .hand: parts = [L10n.text("Drag to pan · Pinch to zoom")]
        case .eyedropper: parts = [L10n.text("Click or drag to sample the foreground color"), pan]
        case .idle: parts = [L10n.text("No tool selected · Press a tool's key to pick one"), pan]
        case .zoom: parts = [L10n.text("Click to zoom in · Option-click to zoom out · Drag right or left to zoom smoothly"), pan]
        }
        return parts.joined(separator: " · ")
    }
}

/// A panel's divider that resizes the panel to its right: drag left to widen, right to narrow, within `range`.
private struct PanelResizeEdge: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider().overlay {
            Color.clear.frame(width: 8).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(range.upperBound, max(range.lowerBound, (start - value.translation.width).rounded()))
                    }
                    .onEnded { _ in startWidth = nil })
                .help("Drag to resize the panel")
        }
    }
}

extension View {
    /// Bordered buttons and pop-up menus drawn as capsules throughout the app. Borderless and plain buttons (the tool
    /// rail, the Layers panel footer) have no border to shape, so they're unaffected.
    func roundedControls() -> some View { buttonBorderShape(.capsule) }
}

extension View {
    /// Return or Escape in a property field gives up its focus and hands it back to the canvas, so a tool's key
    /// works straight away instead of typing into the field.
    func releasesFocusOnCommit(_ session: EditorSession) -> some View {
        onSubmit { session.canvasFocusRequest += 1 }
            .onExitCommand { session.canvasFocusRequest += 1 }
    }
}

/// What a field's key monitor reads. The monitor outlives the view value that installed it, so reading the value
/// and applying the step go through here, refreshed on every redraw.
@MainActor final class ArrowStepper {
    var editing = false
    var value: () -> Double = { 0 }
    var change: (Double) -> Void = { _ in }
    private var monitor: Any?

    /// Takes Up and Down while the field holds focus: one step, or ten with Shift.
    func listen(step: Double) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while a field really is being edited: a field left behind (its tool bar swapped out, say) must not
            // keep taking Up and Down from the canvas, where they nudge the layer.
            guard let self, self.editing, event.keyCode == 126 || event.keyCode == 125,
                  NSApp.keyWindow?.firstResponder is NSTextView else { return event }
            let amount = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
            self.change(self.value() + (event.keyCode == 126 ? amount : -amount))
            return nil
        }
    }
    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editing = false
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Up and Down nudge the value in a focused property field, Shift by ten times as much — a text field takes the
/// arrow keys for its insertion point, so they are caught while it holds focus.
private struct ArrowStepping: ViewModifier {
    let step: Double
    let value: () -> Double
    let change: (Double) -> Void
    @FocusState private var focused: Bool
    @State private var stepper = ArrowStepper()
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, editing in
                stepper.editing = editing
                editing ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
            .onAppear { refresh() }
            .onChange(of: value()) { _, _ in refresh() }
    }
    private func refresh() {
        stepper.value = value
        stepper.change = change
    }
}

extension View {
    /// Up and Down step this field's value; each field's own binding keeps it in range.
    func arrowSteps(_ step: Double = 1, value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        modifier(ArrowStepping(step: step, value: value, change: change))
    }
    /// The same, for a field that already owns its focus: it says when it is being edited.
    func arrowSteps(_ step: Double = 1, editing: Bool, stepper: ArrowStepper,
                    value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        onAppear { stepper.value = value; stepper.change = change }
            .onChange(of: value()) { _, _ in stepper.value = value; stepper.change = change }
            .onChange(of: editing) { _, active in
                stepper.editing = active
                stepper.value = value
                stepper.change = change
                active ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
    }
}

/// Reports the width it is laid out at. Kept out of the editor's body, whose type-checking is already near its limit.
private struct WidthReader: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
