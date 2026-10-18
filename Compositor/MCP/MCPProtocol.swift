import Foundation

/// Wire encoding stays separate from document edits and transport selection.
@MainActor enum MCPProtocol {
    static let maximumMessageBytes = 32 * 1024 * 1024
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]

    static func legacyInitialization(_ parameters: [String: Any]) -> [String: Any] {
        let wanted = parameters["protocolVersion"] as? String ?? ""
        // Preserve the original helper identity during this compatibility refactor.
        return ["protocolVersion": legacyVersions.contains(wanted) ? wanted : legacyVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Compositor", "version": "1.4.5"]]
    }

    static func legacyToolResult(_ value: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                "isError": ["failed", "rejected"].contains(value["status"] as? String ?? "")]
    }

    static func legacyToolError(_ error: Error) -> [String: Any] {
        ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
    }
}
