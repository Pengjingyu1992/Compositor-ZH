import Foundation

@MainActor protocol MCPDocumentHost {
    func executeMCPTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any]
}

/// Common admission validation; document and permission checks belong to the host.
@MainActor enum MCPToolRouter {
    static func call(_ name: String, arguments: [String: Any], host: any MCPDocumentHost) async throws -> [String: Any] {
        try validateCall(name, arguments: arguments)
        return try await host.executeMCPTool(name, arguments: arguments)
    }

    static func validateCall(_ name: String, arguments: [String: Any]) throws {
        guard let definition = MCPToolCatalog.definitions.first(where: { $0.0 == name }),
              definition.3.allSatisfy({ arguments[$0] != nil }),
              Set(arguments.keys).isSubset(of: Set(definition.2.keys)) else {
            throw RoutingError.invalidArguments
        }
    }

    private enum RoutingError: LocalizedError {
        case invalidArguments
        var errorDescription: String? { "Invalid tool arguments." }
    }
}
