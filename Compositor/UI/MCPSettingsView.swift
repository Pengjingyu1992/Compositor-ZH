import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ApplicationSettingsView: View {
    let settings: LanguageSettings
    let service: MCPLiveService
    @AppStorage("settings.page") private var page = "appearance"
    @AppStorage("interface.appearance") private var appearance = InterfaceAppearance.system.rawValue
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                Label("General", systemImage: "gearshape").tag("general")
                Label("Appearance", systemImage: "paintpalette").tag("appearance")
                Label("Language", systemImage: "character.bubble").tag("language")
                Label("Connections", systemImage: "point.3.connected.trianglepath.dotted").tag("connections")
                Label("Advanced", systemImage: "slider.horizontal.3").tag("advanced")
            }.listStyle(.sidebar).frame(width: 170)
            Divider()
            Group {
                if page == "connections" { MCPSettingsView(service: service) }
                else if page == "language" { LanguageSettingsView(settings: settings) }
                else if page == "advanced" {
                    VStack(alignment: .leading, spacing: 18) { Text("Advanced").font(.title2.weight(.semibold)); GhostscriptSettings(); Spacer() }.padding(24)
                } else if page == "general" {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("General").font(.title2.weight(.semibold))
                        Text(verbatim: "Compositor / 叠绘").font(.headline)
                        Text(verbatim: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")").foregroundStyle(.secondary)
                        Button("Recovery Copies…") { Task { await service.workspace.current.controller.reviewRecoveryCopies() } }
                        Text("Recovery protection is separate from saving your project.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(24)
                } else {
                    Form {
                        Text("Appearance").font(.title2.weight(.semibold))
                        Picker("Interface Appearance", selection: $appearance) {
                            Text("System").tag(InterfaceAppearance.system.rawValue)
                            Text("Light").tag(InterfaceAppearance.light.rawValue)
                            Text("Dark").tag(InterfaceAppearance.dark.rawValue)
                        }.pickerStyle(.segmented)
                        Text("Document colors are independent of the interface appearance.").font(.caption).foregroundStyle(.secondary)
                    }.formStyle(.grouped).padding(16)
                }
            }.frame(width: 540, height: 600)
        }.preferredColorScheme(InterfaceAppearance(rawValue: appearance)?.scheme)
            .onChange(of: appearance) { ApplicationAppearance.apply(appearance) }
    }
}

struct MCPSettingsView: View {
    @Bindable var service: MCPLiveService
    @State private var clientName = ""
    @State private var showsActivity = false
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connections").font(.title2.weight(.semibold))
                Text("Allow local AI clients to read and edit documents you authorize.").font(.callout).foregroundStyle(.secondary)
                Toggle("Allow AI clients to connect", isOn: Binding(get: { service.enabled }, set: service.setEnabled))
                    .accessibilityIdentifier("mcpEnabled")
                if service.enabled {
                    HStack {
                        Label(service.paused ? "Paused" : "Bridge Running", systemImage: service.paused ? "pause.circle" : "checkmark.circle")
                        Spacer()
                        Button(service.paused ? "Resume Connections" : "Pause All Connections") { service.setPaused(!service.paused) }
                    }.font(.callout)
                }
                Divider()
                Text("Clients").font(.headline)
                HStack {
                    TextField("Client name", text: $clientName).textFieldStyle(.roundedBorder)
                    Button("Add Client") {
                        do { _ = try service.addClient(name: clientName); clientName = "" }
                        catch { service.error = error.localizedDescription }
                    }.disabled(clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("mcpAddClient")
                }
                ForEach(service.clients) { client in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.format("Documents: %@", service.authorizedDocumentNames(for: client.id))).font(.caption).foregroundStyle(.secondary)
                            permission("Read documents and previews", client, \.read)
                            permission("Edit layers", client, \.edit)
                            permission("Open and save files", client, \.files)
                            permission("Delete and close", client, \.destructive)
                            Text("Delete, replace and close operations require confirmation for each request.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Authorize Current Document") { service.authorizeCurrentDocument(for: client.id) }
                                Button(client.paused ? "Resume" : "Pause") { var value = client; value.paused.toggle(); service.update(value) }
                            }
                            HStack {
                                Button("Copy Client Configuration") {
                                    do { let text = try service.configuration(for: client.id); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true }
                                    catch { service.error = error.localizedDescription }
                                }
                                Button("Revoke", role: .destructive) { service.revoke(client.id) }
                            }
                        }.padding(.top, 8)
                    } label: {
                        HStack {
                            Text(verbatim: client.name).fontWeight(.medium)
                            Spacer()
                            Text(client.paused ? "Paused" : service.connected.values.contains(client.id) ? "Connected" : "Disconnected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if copied { Text("Configuration copied. Paste it into your MCP client's configuration.").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("MCP Output Folder").font(.headline)
                Text(service.folder?.abbreviatingWithTildeInPath ?? L10n.text("No folder selected"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Choose Folder…") { Task { await service.chooseFolder() } }
                Text("Only new files are created. Saving a copy does not mark the original document as saved.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Activity…") { showsActivity = true }
                DisclosureGroup("Connection Details") {
                    Text("Local Unix socket · same-user authentication · no network listener · no shell execution")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                if let error = service.error { Text(verbatim: error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            }.padding(24)
        }.sheet(isPresented: $showsActivity) { MCPActivityView(service: service) }
    }
    private func permission(_ title: LocalizedStringKey, _ client: MCPClientGrant, _ key: WritableKeyPath<MCPClientGrant, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { service.clients.first { $0.id == client.id }?[keyPath: key] ?? false }, set: {
            guard var value = service.clients.first(where: { $0.id == client.id }) else { return }
            value[keyPath: key] = $0; service.update(value)
        }))
    }
}

struct MCPStatusView: View {
    @Environment(\.openSettings) private var openSettings
    var service: MCPLiveService?
    @State private var showsActivity = false
    var body: some View {
        if let service, service.enabled {
            Menu {
                Text(service.paused ? "Paused" : "Bridge Running")
                Button(service.paused ? "Resume Connections" : "Pause All Connections") { service.setPaused(!service.paused) }
                Button("Activity…") { showsActivity = true }
                Button("Connection Settings…") {
                    UserDefaults.standard.set("connections", forKey: "settings.page")
                    openSettings()
                }
            } label: {
                Label("MCP \(service.connectionCount)", systemImage: service.paused ? "pause.circle" : "point.3.connected.trianglepath.dotted")
            }.help("AI Connections").accessibilityIdentifier("mcpStatus")
                .sheet(isPresented: $showsActivity) { MCPActivityView(service: service) }
        }
    }
}

struct MCPActivityView: View {
    @Bindable var service: MCPLiveService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI Activity").font(.title2.weight(.semibold))
                Spacer()
                Button("Export Log…") { Task { await exportLog() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Records contain operation names and results, without document contents, paths or credentials. Only the latest available edit can be undone here.")
                .font(.caption).foregroundStyle(.secondary)
            List(service.activities) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.client + " · " + MCPLiveCatalog.displayName(item.tool))
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: MCPLiveCatalog.displayStatus(item.status)).font(.caption)
                    Button("Undo This Change") { service.undoActivity(item) }.disabled(!service.canUndo(item))
                }.padding(.vertical, 4)
            }
        }.padding(20).frame(width: 650, height: 480)
    }
    private func exportLog() async {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Compositor-MCP-Activity.json"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; try encoder.encode(service.activities).write(to: url, options: .atomic) }
        catch { service.error = error.localizedDescription }
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
