import SwiftUI

struct BatchExportSheet: View {
    @Bindable var session: EditorSession
    let draft: BatchExportDraft
    @State private var options = BatchExportOptions()
    @State private var sizes = "0, 1080, 2048"
    private var resolved: BatchExportOptions {
        var value = options
        value.longSides = sizes.split(separator: ",", omittingEmptySubsequences: false).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if value.longSides.count != sizes.split(separator: ",", omittingEmptySubsequences: false).count { value.longSides = [] }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Export").font(.title2)
            Toggle("Export Selected Layers Individually", isOn: $options.individualLayers).disabled(draft.selected.isEmpty)
            Picker("Format", selection: $options.format) { ForEach(BatchExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Long Sides", text: $sizes)
            Text("Comma-separated pixel sizes. 0 keeps the original size; the aspect ratio is preserved.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Web") { sizes = "1080, 1600, 2048" }
                Button("Thumbnail") { sizes = "256, 512" }
                Button("Original") { sizes = "0" }
            }
            TextField("Filename Prefix", text: $options.prefix)
            if options.format == .jpeg { HStack { Text("Quality"); Slider(value: $options.quality, in: 0...1) } }
            Text("Files use prefix + layer/project name + width × height. Each export creates a new folder; existing files are preserved. JPEG uses a white background.").font(.caption).foregroundStyle(.secondary)
            if let path = session.batchExportResult {
                Text(L10n.format("Exported to %@", path)).font(.caption).textSelection(.enabled)
            }
            HStack {
                if session.batchExportRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { session.cancelBatchExport() }.disabled(session.batchExportRunning).configuredNativeShortcut(.escape)
                Button("Choose Folder and Export…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
                    panel.begin { response in
                        if response == .OK, let url = panel.url { Task { await session.exportBatch(resolved, folder: url) } }
                    }
                }.disabled(!resolved.isValid || session.batchExportRunning)
            }
        }.padding(24).frame(width: 520)
    }
}
