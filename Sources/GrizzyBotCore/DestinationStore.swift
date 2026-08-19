import Foundation

public struct DestinationRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    public var title: String
    public var body: String
    public var remoteId: String?
    public var createdAt: Date

    public init(
        id: String = Ids.new(),
        slug: String,
        title: String,
        body: String,
        remoteId: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.body = body
        self.remoteId = remoteId
        self.createdAt = createdAt
    }
}

/// Append-only destination log under Application Support, plus live plugin writes.
public struct DestinationStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.appendingPathComponent("destinations", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func append(_ record: DestinationRecord) throws {
        let url = root.appendingPathComponent("\(record.slug).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.decodeLine(record)
        line.append("\n")
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            }
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func list(slug: String, limit: Int = 50) -> [DestinationRecord] {
        let url = root.appendingPathComponent("\(slug).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").reversed().prefix(limit).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(DestinationRecord.self, from: data)
        }.reversed()
    }
}

private extension JSONEncoder {
    func decodeLine<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
