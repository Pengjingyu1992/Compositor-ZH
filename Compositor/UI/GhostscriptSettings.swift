import AppKit
import SwiftUI

nonisolated enum GhostscriptAccess {
    static let bookmarkKey = "epsGhostscriptFolder"
    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }
}

struct GhostscriptSettings: View {
    @State private var authorized = GhostscriptAccess.folder() != nil
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EPS Import").font(.title3.weight(.semibold))
            Text("General EPS requires a current Ghostscript 10 installation. Select its installation folder, including libraries and fonts, to allow read-only access.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Ghostscript Folder…", action: choose)
                if authorized {
                    Button("Forget Folder") {
                        UserDefaults.standard.removeObject(forKey: GhostscriptAccess.bookmarkKey)
                        authorized = false; error = nil
                    }
                }
            }
            if authorized { Text("Ghostscript folder authorized.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose Ghostscript Folder")
        panel.message = L10n.text("Choose the installation root containing bin/gs and its dependencies. For Homebrew, choose its prefix folder.")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard ["/opt/homebrew", "/usr/local"].contains(url.standardizedFileURL.path) else {
                self.error = L10n.text("Use a Ghostscript installation under /opt/homebrew or /usr/local for sandboxed EPS import.")
                return
            }
            guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/gs").path) else { throw EPSError.interpreter }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: GhostscriptAccess.bookmarkKey)
            authorized = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
