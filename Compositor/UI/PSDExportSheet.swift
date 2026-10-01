import AppKit
import SwiftUI

struct PSDExportSheet: View {
    let snapshot: ProjectSnapshot
    let complete: (PSDExportMode?) -> Void
    @State private var mode: PSDExportMode
    init(snapshot: ProjectSnapshot, complete: @escaping (PSDExportMode?) -> Void) {
        self.snapshot = snapshot; self.complete = complete
        _mode = State(initialValue: PSDWriter.requiresFlattening(snapshot) ? .flattened : .layered)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export PSD").font(.title2.bold())
            Picker("Export Mode", selection: $mode) {
                Text("Layered PSD").tag(PSDExportMode.layered).disabled(PSDWriter.requiresFlattening(snapshot))
                Text("Flattened PSD").tag(PSDExportMode.flattened)
            }.pickerStyle(.radioGroup)
            Text(mode == .layered
                 ? L10n.text("Pixel layers, folders, opacity, blend modes, and layer masks remain separate. Transforms are rendered into pixels.")
                 : L10n.text("The visible canvas is exported as one pixel layer. The original project remains editable."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(PSDWriter.conversionNotes(snapshot), id: \.self) { note in
                Text(L10n.text(note)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { complete(nil) }.keyboardShortcut(.cancelAction)
                Button("Continue") { complete(mode) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560)
    }
}

extension ProjectController {
    func exportPSD() async {
        guard let window, session.document != nil, session.canStartProjectOperation,
              workspace?.isManaging != true else { return }
        session.cancelCrop(); session.commitTransform()
        guard let snapshot = session.projectSnapshot() else { return }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let mode: PSDExportMode? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]; sheet.title = L10n.text("Export PSD")
            sheet.contentViewController = NSHostingController(rootView: PSDExportSheet(snapshot: snapshot) { mode in
                window.endSheet(sheet); sheet.orderOut(nil); sheet.contentViewController = nil
                continuation.resume(returning: mode)
            })
            window.beginSheet(sheet)
        }
        guard let mode else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.photoshopImage]; panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.title = L10n.text("Export PSD")
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".psd"
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await PSDExporter.shared.export(snapshot, mode: mode, to: url) }
        catch {
            let alert = NSAlert(); alert.messageText = L10n.text("Couldn’t export PSD")
            alert.informativeText = L10n.text(error.localizedDescription); alert.addButton(withTitle: L10n.text("OK"))
            await alert.beginSheetModal(for: window)
        }
    }
}
