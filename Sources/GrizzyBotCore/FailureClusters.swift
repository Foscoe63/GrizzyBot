import CryptoKit
import Foundation

/// Groups the same failure seen many times into one entry, without keeping what the failure said. Only a normalized
/// signature and a short title are stored; raw tool output, paths and values never are.
public enum FailureSignature {
    private static let rules: [(pattern: String, token: String)] = [
        (#"https?://[^\s"')\]]+"#, "<url>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<uuid>"),
        (#"\b0x[0-9a-fA-F]+\b"#, "<hex>"),
        (#"\b[0-9a-fA-F]{12,}\b"#, "<hex>"),
        (#"(?:~|/)[^\s"':,;)\]]*/[^\s"':,;)\]]*"#, "<path>"),
        (#""[^"\n]{1,80}""#, "<quoted>"),
        (#"'[^'\n]{1,80}'"#, "<quoted>"),
        (#"\b\d+(?:\.\d+)*\b"#, "<n>"),
    ]

    /// The failure's text with everything that varies run to run replaced by a placeholder.
    public static func normalize(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        line = line.trimmingCharacters(in: .whitespaces)
        for rule in rules {
            line = line.replacingOccurrences(of: rule.pattern, with: rule.token, options: .regularExpression)
        }
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(line.lowercased().prefix(160))
    }

    /// A shell failure is grouped by its exit code and the kind of error, not by what it was running.
    public static func shell(exitCode: Int, output: String) -> String {
        let lowered = output.lowercased()
        let kind: String
        if lowered.contains("command not found") { kind = "command not found" }
        else if lowered.contains("permission denied") { kind = "permission denied" }
        else if lowered.contains("no such file") { kind = "no such file" }
        else if lowered.contains("timed out") || lowered.contains("timeout") { kind = "timeout" }
        else if lowered.contains("operation not permitted") || lowered.contains("sandbox") { kind = "not permitted" }
        else { kind = "other" }
        return "shell exit \(exitCode): \(kind)"
    }

    public static func tool(_ name: String, error: String) -> String {
        "\(name): \(normalize(error))"
    }

    /// A tool result that is a failure rather than an answer.
    public static func looksLikeFailure(_ output: String) -> Bool {
        let head = output.prefix(200).lowercased()
        return ["error", "failed", "couldn't", "could not", "cannot", "not found", "denied", "timed out"].contains { head.hasPrefix($0) }
    }

    /// A stable short id for one signature.
    public static func id(_ signature: String) -> String {
        SHA256.hash(data: Data(signature.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

public struct FailureCluster: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var signature: String
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var botIds: [String]
    /// Prompt versions the failure was seen under (short fingerprints, newest last).
    public var fingerprints: [String]
}

public struct FailureClusterBook: Codable, Sendable, Equatable {
    public var clusters: [String: FailureCluster] = [:]
    public static let maxClusters = 200

    public mutating func record(signature: String, botId: String, fingerprint: String?, now: Date = .now) {
        let key = FailureSignature.id(signature)
        var cluster = clusters[key] ?? FailureCluster(id: key, signature: signature, count: 0, firstSeen: now, lastSeen: now, botIds: [], fingerprints: [])
        cluster.count += 1
        cluster.lastSeen = now
        if !cluster.botIds.contains(botId) { cluster.botIds.append(botId) }
        if let fingerprint, cluster.fingerprints.last != fingerprint { cluster.fingerprints = Array((cluster.fingerprints + [fingerprint]).suffix(5)) }
        clusters[key] = cluster
        if clusters.count > Self.maxClusters, let oldest = clusters.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            clusters[oldest.id] = nil
        }
    }

    /// Most frequent first.
    public func top(_ limit: Int = 10) -> [FailureCluster] {
        clusters.values.sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }.prefix(limit).map { $0 }
    }
}

/// Which version of a bot's instructions and tools a run used, so outcomes can be compared across edits.
public enum PromptFingerprint {
    public static func compute(systemPrompt: String, toolNames: [String]) -> String {
        let material = systemPrompt + "\u{0}" + toolNames.sorted().joined(separator: ",")
        return SHA256.hash(data: Data(material.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppStore {
    private var failureClustersURL: URL { globalRoot.appendingPathComponent("failure-clusters.json") }

    public func loadFailureClusters() -> FailureClusterBook {
        (try? JSONDecoder().decode(FailureClusterBook.self, from: Data(contentsOf: failureClustersURL))) ?? FailureClusterBook()
    }

    func recordFailure(signature: String, botId: String, runId: String?) {
        var book = loadFailureClusters()
        let fingerprint = runId.flatMap { id in threads.values.compactMap(\.run).first { $0.id == id }?.promptFingerprint }
        book.record(signature: signature, botId: botId, fingerprint: fingerprint)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: failureClustersURL, options: .atomic) }
    }

    func recordToolOutcome(tool: String, output: String, botId: String, runId: String?) {
        guard FailureSignature.looksLikeFailure(output) else { return }
        recordFailure(signature: FailureSignature.tool(tool, error: output), botId: botId, runId: runId)
    }

    func setRunFingerprint(botId: String, runId: String, fingerprint: String) {
        let key = threadKey(for: botId)
        guard threads[key]?.run?.id == runId else { return }
        threads[key]?.run?.promptFingerprint = fingerprint
    }
}
