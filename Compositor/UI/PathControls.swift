import SwiftUI

struct PathControls: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Button("New Path") { session.pathEditing = nil; session.beginPathEditing(new: true) }
            Button("Edit Path") { session.beginPathEditing() }.disabled(session.pathEditing != nil || session.activeLayer?.liveShape?.style.vector == nil)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    if session.pathEditing != nil {
                        if session.pathEditing?.mask != true {
                            Button("Use Foreground Color") {
                                session.pathEditing?.color = session.foregroundColor
                                session.pathEditing?.style.strokeColor = session.foregroundColor
                            }
                            Toggle("Fill", isOn: Binding(get: { session.pathEditing?.style.fillEnabled ?? true },
                                set: { session.pathEditing?.style.fillEnabled = $0 }))
                            Toggle("Stroke", isOn: Binding(get: { session.pathEditing?.style.strokeEnabled ?? false }, set: {
                                session.pathEditing?.style.strokeEnabled = $0
                                session.pathEditing?.style.strokeColor = session.foregroundColor
                            }))
                            TextField("Width", value: Binding<Double>(get: { Double(session.pathEditing?.style.strokeWidth ?? 2) }, set: {
                                if $0.isFinite { session.pathEditing?.style.strokeWidth = CGFloat(min(5000, max(0, $0))) }
                            }), format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Even-Odd", isOn: Binding(get: { session.pathEditing?.style.evenOdd ?? false },
                            set: { session.pathEditing?.style.evenOdd = $0 }))
                        Button("New Contour") {
                            session.pathEditing?.style.contours.append(VectorContour(anchors: []))
                            session.pathEditing?.contour = (session.pathEditing?.style.contours.count ?? 1) - 1
                            session.pathEditing?.anchor = nil
                            session.pathEditing?.adding = true
                        }.disabled((session.pathEditing?.style.contours.count ?? 0) >= 10_000)
                        Spacer(minLength: 0)
                        Button("Cancel") { session.pathEditing = nil }
                        Button("Apply") { session.finishPathEditing() }
                    } else { Spacer(minLength: 0) }
                }
            }.scrollIndicators(.hidden)
        }.toggleStyle(.checkbox).padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
    }
}

extension EditorSession {
    func drawPathControls(in context: CGContext) {
        guard tool == .pen, let document else { return }
        let e = pathEditing ?? activeLayer.flatMap { layer in
            layer.liveShape?.style.vector.map {
                PathEditing(documentID: document.id, revision: history.currentRevision, layerID: layer.id,
                            transform: layer.transform, style: $0, color: layer.liveShape!.style.color)
            }
        }
        guard let e else { return }
        let mapping = BrushRaster.pixelToDocument(e.transform, width: 1, height: 1)
        func view(_ p: CGPoint) -> CGPoint { viewport.viewPoint(from: p.applying(mapping), documentSize: document.size) }
        var viewStyle = e.style.mapped(view)
        viewStyle.strokeWidth = 1
        let path = viewStyle.path(size: CGSize(width: 1, height: 1))
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5)
        context.addPath(path); context.strokePath()
        for c in e.style.contours.indices {
            for a in e.style.contours[c].anchors.indices {
                let anchor = e.style.contours[c].anchors[a], p = view(anchor.point)
                if e.anchor == a && e.contour == c {
                    for handle in [anchor.incoming, anchor.outgoing].compactMap({ $0 }) {
                        let h = view(handle)
                        context.move(to: p); context.addLine(to: h); context.strokePath()
                        context.setFillColor(NSColor.white.cgColor)
                        context.fillEllipse(in: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6))
                        context.strokeEllipse(in: CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6))
                    }
                }
                context.setFillColor(e.anchor == a && e.contour == c ? NSColor.controlAccentColor.cgColor : NSColor.white.cgColor)
                let box = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                context.fill(box); context.stroke(box)
            }
        }
    }
}
