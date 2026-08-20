import Foundation

public struct ComponentField: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var value: String

    public init(id: String = Ids.new(), label: String, value: String = "") {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct ComponentPayload: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var fields: [ComponentField]
    public var items: [String]

    public init(
        id: String,
        title: String,
        fields: [ComponentField] = [],
        items: [String] = []
    ) {
        self.id = id
        self.title = title
        self.fields = fields
        self.items = items
    }
}

public enum AgentComponentCatalog {
    public static let allIds = ["form", "gallery", "activity", "refusals"]

    public static func isPublished(_ id: String, extras: [SandboxComponent] = []) -> Bool {
        allIds.contains(id) || extras.contains { $0.id == id && $0.published }
    }
}

/// Authored card: draft in the playground, published for `present_component`.
public struct SandboxComponent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var kind: String
    public var sourceJSON: String
    public var published: Bool
    /// `activity` / `refusals` — needs a `component-data:` grant when grants exist.
    public var dataFunctions: [String]

    public init(
        id: String = Ids.new(),
        title: String,
        kind: String = "form",
        sourceJSON: String = "{}",
        published: Bool = false,
        dataFunctions: [String] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.sourceJSON = sourceJSON
        self.published = published
        self.dataFunctions = dataFunctions
    }

    public var payload: ComponentPayload {
        if let data = sourceJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ComponentPayload.self, from: data) {
            return decoded
        }
        return ComponentPayload(id: id, title: title)
    }
}
