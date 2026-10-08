import AppKit
import SwiftUI

struct LiquifySheet: View {
    @Bindable var session: EditorSession
    @Bindable var edit: LiquifyWorkspace
    private var windowSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: min(1160, available.width - 80), height: min(780, available.height - 100))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Advanced Liquify").font(.title2.bold())
                Text(edit.layer.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    edit.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo Liquify Stroke").accessibilityLabel("Undo Liquify Stroke").disabled(!edit.canUndo)
                Button {
                    edit.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("Redo Liquify Stroke").accessibilityLabel("Redo Liquify Stroke").disabled(!edit.canRedo)
                Toggle("Before", isOn: $edit.showsOriginal).toggleStyle(.button)
            }.padding(14)
            Divider()
            HStack(spacing: 0) {
                LiquifyCanvas(edit: edit).clipped()
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Liquify Tools").font(.headline)
                        Text("Basic Liquify pushes on the main canvas. Advanced Liquify adds reconstruct, freeze, and deformation tools.")
                            .font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(LiquifyTool.allCases, id: \.self) { tool in
                                Button {
                                    edit.tool = tool
                                } label: {
                                    Text(L10n.text(tool.rawValue)).frame(maxWidth: .infinity, minHeight: 26)
                                        .background(edit.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }.buttonStyle(.bordered).accessibilityIdentifier("liquifyTool-\(tool.code)")
                            }
                        }
                        Divider()
                        parameter(L10n.text("Brush Size"), value: $edit.diameter, range: 2...3000)
                        parameter(L10n.text("Hardness"), value: $edit.hardness, range: 0...1, percent: true)
                        parameter(L10n.text("Strength"), value: $edit.strength, range: 0.01...1, percent: true)
                        parameter(L10n.text("Rate"), value: $edit.rate, range: 0.1...3, fractional: true)
                        Toggle("Reverse Twirl", isOn: $edit.reversesDirection).disabled(edit.tool != .twirl)
                        Toggle("Use Pen Pressure", isOn: $edit.usesPressure)
                        Toggle("Pin Edges", isOn: $edit.fixedEdges)
                        Divider()
                        Toggle("Show Frozen Areas", isOn: $edit.showsFrozen)
                        Toggle("Show Warp Mesh", isOn: $edit.showsMesh)
                        Toggle("Show Other Layers as Reference", isOn: $edit.showsBackdrop)
                        Button("Thaw All") { edit.reset(onlyFreeze: true) }
                        Button("Restore All Warps") { edit.reset() }
                        if edit.mustUseCopy {
                            Text("Text and shapes are applied as a new raster copy.").font(.caption).foregroundStyle(
                                .secondary)
                        }
                        if edit.historyWasTrimmed {
                            Text("Older Liquify strokes were removed to stay within the history budget.").font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("Edit in the layer’s original orientation. Its document rotation and scale are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.format("%@ / %@ size · %@ / %@ hardness", ShortcutSettings.shared.keyLabel("["), ShortcutSettings.shared.keyLabel("]"), ShortcutSettings.shared.keyLabel("[", 8), ShortcutSettings.shared.keyLabel("]", 8)))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(ShortcutSettings.shared.opacityHelp).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.format("Hold %@ to pan", ShortcutSettings.shared.keyLabel(" ")))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Scroll to pan; Command-scroll to zoom. Right-drag resizes; Shift-right-drag changes hardness.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).disabled(edit.isApplying)
                }.frame(width: 270)
            }
            Divider()
            HStack {
                Button("Fit") {
                    edit.zoom = 1
                    edit.pan = .zero
                }
                Button("−") { edit.zoom = max(0.1, edit.zoom / 1.25) }
                Text("\(Int(edit.zoom*100))%").monospacedDigit().frame(width: 50)
                Button("+") { edit.zoom = min(20, edit.zoom * 1.25) }
                Toggle("Create Liquify Copy", isOn: $edit.createsCopy).disabled(edit.mustUseCopy || edit.isApplying)
                Spacer()
                if edit.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Applying Liquify…")
                }
                Button("Cancel") { session.cancelLiquify() }.configuredNativeShortcut(.escape)
                Button("Apply") { Task { await session.applyLiquify() } }.buttonStyle(.borderedProminent)
                    .configuredNativeShortcut(.return).disabled(edit.isApplying || edit.isStroking)
            }.padding(12)
            if let error = edit.error {
                Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(Color(white: 0.12)).preferredColorScheme(.dark)
        .interactiveDismissDisabled(edit.isApplying)
        .onDisappear { if session.liquify === edit { session.cancelLiquify() } }
    }
    private func parameter(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false,
        fractional: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(
                    percent
                        ? "\(Int(value.wrappedValue*100))%"
                        : String(format: fractional ? "%.1f" : "%.0f", value.wrappedValue)
                ).monospacedDigit()
            }.font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}

struct LiquifyCanvas: NSViewRepresentable {
    let edit: LiquifyWorkspace
    func makeNSView(context: Context) -> LiquifyCanvasView { LiquifyCanvasView(edit: edit) }
    func updateNSView(_ view: LiquifyCanvasView, context: Context) {
        // Read observable state here; native drawing alone does not register dependencies.
        _ = edit.preview
        _ = edit.frozenOverlay
        _ = edit.revision
        _ = edit.zoom
        _ = edit.pan
        _ = edit.showsFrozen
        _ = edit.showsOriginal
        _ = edit.showsMesh
        _ = edit.showsBackdrop
        _ = edit.diameter
        view.needsDisplay = true
    }
}

final class LiquifyCanvasView: NSView {
    let edit: LiquifyWorkspace
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var point: CGPoint?
    private var cursor: CGPoint?
    private var pressure: Double = 1
    private var lastTime = 0.0
    private var timer: Timer?
    private var space = false
    private var panning = false
    private var previous: CGPoint?
    private var keyMonitor: Any?
    private var panPhysicalKey: UInt16?
    private var brushTipDrag: (start: CGPoint, diameter: Double, hardness: Double, hardnessShown: Bool)?
    init(edit: LiquifyWorkspace) {
        self.edit = edit
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("liquifyCanvas")
        setAccessibilityLabel(L10n.text("Liquify Canvas"))
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard let window else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.windowNumber == window.windowNumber else { return event }
            if event.type == .keyUp { return self.handleKeyUp(event) ? nil : event }
            guard !(window.firstResponder is NSText) else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
        // Brush keys work immediately after opening, including when a button takes focus later.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(self)
        }
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        super.updateTrackingAreas()
    }
    private var factor: CGFloat {
        min(
            max(1, bounds.width - 40) / CGFloat(edit.pixels.width),
            max(1, bounds.height - 40) / CGFloat(edit.pixels.height)) * edit.zoom
    }
    private var imageRect: CGRect {
        let size = CGSize(width: CGFloat(edit.pixels.width) * factor, height: CGFloat(edit.pixels.height) * factor)
        return CGRect(
            x: bounds.midX - size.width / 2 + edit.pan.width, y: bounds.midY - size.height / 2 + edit.pan.height,
            width: size.width, height: size.height)
    }
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / factor, y: (p.y - imageRect.minY) / factor)
    }
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.normal)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        c.fill(bounds)
        let rect = imageRect
        c.saveGState()
        c.clip(to: rect)
        c.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        c.fill(rect)
        let tile: CGFloat = 12
        c.setFillColor(NSColor(white: 0.28, alpha: 1).cgColor)
        for y in 0...Int(bounds.height / tile) {
            for x in 0...Int(bounds.width / tile) where (x + y) % 2 == 0 {
                c.fill(CGRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile))
            }
        }
        if edit.showsBackdrop {
            c.saveGState()
            c.translateBy(x: rect.minX, y: rect.minY)
            c.scaleBy(x: factor, y: factor)
            c.concatenate(
                BrushRaster.pixelToDocument(edit.layer.transform, width: edit.pixels.width, height: edit.pixels.height)
                    .inverted())
            for layer in edit.referenceLayers {
                guard let image = layer.asset?.image else { continue }
                LayerRenderer.draw(
                    image, transform: layer.transform, center: layer.transform.center, opacity: layer.opacity * 0.5,
                    mask: layer.mask?.clipImage(
                        placement: layer.mask?.placement, over: layer.transform, width: image.width,
                        height: image.height), in: c)
            }
            c.restoreGState()
        }
        if let image = edit.showsOriginal ? edit.original : edit.preview { drawImage(image, in: rect, context: c) }
        if edit.showsFrozen, let image = edit.frozenOverlay { drawImage(image, in: rect, context: c) }
        if edit.showsMesh {
            c.setStrokeColor(NSColor.cyan.withAlphaComponent(0.5).cgColor)
            c.setLineWidth(0.7)
            let spacing = max(16, CGFloat(max(edit.pixels.width, edit.pixels.height)) / 24)
            func map(_ p: CGPoint) -> CGPoint {
                let q = edit.offset(at: p)
                return CGPoint(x: rect.minX + q.x * factor, y: rect.minY + q.y * factor)
            }
            for x in stride(from: CGFloat(0), through: CGFloat(edit.pixels.width), by: spacing) {
                c.beginPath()
                c.move(to: map(CGPoint(x: x, y: 0)))
                for y in stride(from: spacing, through: CGFloat(edit.pixels.height), by: spacing) {
                    c.addLine(to: map(CGPoint(x: x, y: y)))
                }
                c.strokePath()
            }
            for y in stride(from: CGFloat(0), through: CGFloat(edit.pixels.height), by: spacing) {
                c.beginPath()
                c.move(to: map(CGPoint(x: 0, y: y)))
                for x in stride(from: spacing, through: CGFloat(edit.pixels.width), by: spacing) {
                    c.addLine(to: map(CGPoint(x: x, y: y)))
                }
                c.strokePath()
            }
        }
        c.restoreGState()
        if let cursor {
            let d = edit.diameter * factor
            let r = CGRect(x: cursor.x - d / 2, y: cursor.y - d / 2, width: d, height: d)
            c.setLineWidth(1.5)
            c.setStrokeColor(NSColor.black.cgColor)
            c.strokeEllipse(in: r.insetBy(dx: -1, dy: -1))
            c.setLineWidth(1)
            c.setStrokeColor(NSColor.white.cgColor)
            c.strokeEllipse(in: r)
            if brushTipDrag?.hardnessShown == true {
                let inset = d * (1 - edit.hardness) / 2
                c.strokeEllipse(in: r.insetBy(dx: inset, dy: inset))
            }
        }
    }
    private func tick() {
        guard let point else { return }
        let now = ProcessInfo.processInfo.systemUptime
        edit.append(local(point), elapsed: now - lastTime, pressure: pressure)
        lastTime = now
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !edit.isApplying, !edit.isStroking, !space else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        brushTipDrag = (p, edit.diameter, edit.hardness, event.modifierFlags.contains(.shift))
        cursor = p
        needsDisplay = true
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let drag = brushTipDrag, !edit.isApplying, !edit.isStroking else { return }
        let dx = convert(event.locationInWindow, from: nil).x - drag.start.x
        brushTipDrag?.hardnessShown = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.shift) {
            edit.hardness = min(1, max(0, drag.hardness + Double(dx) / 200))
            edit.diameter = drag.diameter
        } else {
            edit.diameter = min(3000, max(2, (drag.diameter + 2 * Double(dx / max(0.0001, factor))).rounded()))
            edit.hardness = drag.hardness
        }
        cursor = drag.start
        needsDisplay = true
    }
    override func rightMouseUp(with event: NSEvent) {
        brushTipDrag = nil
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard !edit.isApplying else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        previous = p
        panning = space
        guard !panning, !edit.showsOriginal, imageRect.contains(p) else { return }
        point = p
        pressure = event.subtype == .tabletPoint ? Double(event.pressure) : 1
        lastTime = ProcessInfo.processInfo.systemUptime
        edit.beginStroke(local(p))
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if panning, let last = previous {
            edit.pan.width += p.x - last.x
            edit.pan.height += p.y - last.y
            previous = p
        } else if point != nil {
            point = p
            pressure = event.subtype == .tabletPoint ? Double(event.pressure) : 1
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if point != nil {
            point = convert(event.locationInWindow, from: nil)
            tick()
        }
        timer?.invalidate()
        timer = nil
        point = nil
        panning = false
        previous = nil
        edit.endStroke()
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            edit.zoom = min(20, max(0.1, edit.zoom * exp(event.scrollingDeltaY * 0.01)))
        } else {
            edit.pan.width += event.scrollingDeltaX
            edit.pan.height += event.scrollingDeltaY
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        edit.zoom = min(20, max(0.1, edit.zoom * (1 + event.magnification)))
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }
    @discardableResult func handleKeyDown(_ original: NSEvent, shortcuts: ShortcutSettings? = nil) -> Bool {
        let shortcuts = shortcuts ?? .shared
        let input = ShortcutChord(original)
        if input == shortcuts.menu("z", modifiers: .command) { edit.undo(); return true }
        if input == shortcuts.menu("z", modifiers: [.command, .shift]) { edit.redo(); return true }
        guard let event = shortcuts.canvasEvent(original) else { return true }
        let chord = ShortcutChord(event)
        guard chord.modifiers == 0 || chord.modifiers == 8 else { return false }
        if chord.key == " ", chord.modifiers == 0 {
            guard !edit.isApplying, !edit.isStroking else { return true }
            panPhysicalKey = original.keyCode
            space = true
            return true
        }
        if chord.key == "[" || chord.key == "]" {
            if chord.modifiers == 8 { edit.changeBrushHardness(increase: chord.key == "]") }
            else { edit.changeBrushSize(increase: chord.key == "]") }
            needsDisplay = true
            return true
        }
        if chord.modifiers == 0, let digit = Int(chord.key), (0...9).contains(digit) {
            edit.typeStrengthDigit(digit)
            return true
        }
        return false
    }
    override func keyUp(with event: NSEvent) {
        if !handleKeyUp(event) { super.keyUp(with: event) }
    }
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let physical = panPhysicalKey, event.keyCode == physical else { return false }
        space = false
        panPhysicalKey = nil
        return true
    }
    override func resignFirstResponder() -> Bool {
        space = false
        panPhysicalKey = nil
        return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            timer?.invalidate()
            timer = nil
            point = nil
            brushTipDrag = nil
            space = false
            panPhysicalKey = nil
            edit.endStroke()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
