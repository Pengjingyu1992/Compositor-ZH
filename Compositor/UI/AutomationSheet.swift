import SwiftUI

struct AutomationSheet: View {
    @Bindable var session: EditorSession
    @State private var source = ""
    @State private var result = ""
    @State private var running = false
    private func example() {
        guard let document = session.document else { return }
        let request = PosterBatchRequest(documentID: document.id, expectedRevision: session.history.currentRevision, expectedLockRevision: session.lockRevision,
            commands: [PosterCommand(kind: .addFill, fill: LayerFillStyle(kind: .linear))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        source = (try? encoder.encode(request)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Commands").font(.title2)
            Text("Commands run as one undo step. A failed batch leaves the document unchanged.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Insert Fill Example") { example() }.disabled(running)
                Button("Copy Document State") {
                    if let data = try? JSONSerialization.data(withJSONObject: session.automationState(), options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(width: 680, height: 360).disabled(running)
            Text(result).font(.caption).textSelection(.enabled)
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { session.showsAutomation = false }.disabled(running).configuredNativeShortcut(.escape)
                Button("Run Batch") {
                    guard let data = source.data(using: .utf8), data.count <= 32 * 1024 * 1024 else { return }
                    do {
                        let request = try JSONDecoder().decode(PosterBatchRequest.self, from: data)
                        running = true
                        Task {
                            let outcome = await session.executePosterBatch(request)
                            result = L10n.text(outcome.status) + (outcome.message.map { ": " + $0 } ?? "")
                            running = false
                            if outcome.status == "changed" {
                                let next = PosterBatchRequest(documentID: request.documentID, expectedRevision: outcome.revision, expectedLockRevision: session.lockRevision, commands: request.commands)
                                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                source = (try? encoder.encode(next)).flatMap { String(data: $0, encoding: .utf8) } ?? source
                            }
                        }
                    } catch { result = L10n.text("The edit command or its parameters are invalid.") }
                }.disabled(running || session.document == nil)
            }
        }.padding(24).onAppear { example() }
    }
}
