import SwiftUI

struct HistoryPanel: View {
    @Bindable var session: EditorSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.history.timeline) { item in
                        Button { session.jumpHistory(to: item.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.isCurrent ? "arrowtriangle.right.fill" : "clock")
                                    .frame(width: 14)
                                Text(L10n.text(item.name)).lineLimit(2)
                                Spacer(minLength: 0)
                                if item.isSaved { Image(systemName: "externaldrive").accessibilityLabel("Saved state") }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(item.isFuture ? .secondary : .primary)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(item.isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).id(item.id)
                        .disabled(!session.canUseHistory || session.gradientEdit != nil || item.isCurrent)
                        .accessibilityIdentifier("historyState-\(item.id)")
                    }
                }.padding(8)
            }
            .onChange(of: session.history.currentRevision, initial: true) { _, revision in
                proxy.scrollTo(revision, anchor: .center)
            }
        }
        Divider()
        if session.history.droppedLatestUndo {
            Text("Undo unavailable: this edit exceeded the history memory budget.")
                .font(.caption).foregroundStyle(.orange).padding(12)
        }
        Text("History is limited by memory. New edits replace redo states.")
            .font(.caption).foregroundStyle(.secondary).padding(12)
    }
}
