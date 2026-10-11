import CryptoKit
import Foundation

/// One unit of work in a trace: a run, or a tool call inside it. Carries timings and counts only —
/// never prompts, tool arguments, or file contents.
public struct TraceSpan: Sendable, Equatable {
    public var traceId: String
    public var spanId: String
    public var parentSpanId: String?
    public var name: String
    public var start: Date
    public var end: Date
    public var ok: Bool
    public var attributes: [String: String]
    public var counts: [String: Int]

    public init(traceId: String, spanId: String, parentSpanId: String? = nil, name: String, start: Date, end: Date, ok: Bool = true, attributes: [String: String] = [:], counts: [String: Int] = [:]) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.name = name
        self.start = start
        self.end = end
        self.ok = ok
        self.attributes = attributes
        self.counts = counts
    }
}

public enum Tracing {
    /// A stable 32-hex trace id for a run, and 16-hex span ids derived from it.
    public static func traceId(forRun runId: String) -> String {
        hex(SHA256.hash(data: Data("trace:\(runId)".utf8)), count: 16)
    }

    public static func runSpanId(forRun runId: String) -> String {
        hex(SHA256.hash(data: Data("run:\(runId)".utf8)), count: 8)
    }

    public static func newSpanId() -> String {
        hex(SHA256.hash(data: Data(UUID().uuidString.utf8)), count: 8)
    }

    private static func hex(_ digest: SHA256.Digest, count: Int) -> String {
        digest.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private static func nanos(_ date: Date) -> String {
        String(UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
    }

    /// The OTLP/HTTP JSON body for a batch of spans.
    public static func otlpPayload(_ spans: [TraceSpan]) -> Data {
        let encoded: [[String: Any]] = spans.map { span in
            var attrs: [[String: Any]] = span.attributes.sorted { $0.key < $1.key }.map {
                ["key": $0.key, "value": ["stringValue": $0.value]]
            }
            attrs += span.counts.sorted { $0.key < $1.key }.map {
                ["key": $0.key, "value": ["intValue": String($0.value)]]
            }
            var out: [String: Any] = [
                "traceId": span.traceId,
                "spanId": span.spanId,
                "name": span.name,
                "kind": 1,
                "startTimeUnixNano": nanos(span.start),
                "endTimeUnixNano": nanos(span.end),
                "attributes": attrs,
                "status": ["code": span.ok ? 1 : 2],
            ]
            if let parent = span.parentSpanId { out["parentSpanId"] = parent }
            return out
        }
        let body: [String: Any] = [
            "resourceSpans": [[
                "resource": ["attributes": [["key": "service.name", "value": ["stringValue": "grizzybot"]]]],
                "scopeSpans": [["scope": ["name": "grizzybot"], "spans": encoded]],
            ]]
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `http://localhost:4318` → `http://localhost:4318/v1/traces`; a full traces URL is left alone.
    public static func tracesURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var url = URL(string: trimmed), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        if !url.path.hasSuffix("/v1/traces") {
            url = url.appendingPathComponent("v1").appendingPathComponent("traces")
        }
        return url
    }
}

/// Buffers spans and ships them in small batches. Failures are dropped: tracing must never slow or
/// break a run.
public actor TraceExporter {
    private var pending: [TraceSpan] = []
    private var endpoint: URL?
    private var flushTask: Task<Void, Never>?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func configure(endpoint: String) {
        self.endpoint = Tracing.tracesURL(from: endpoint)
        if self.endpoint == nil { pending.removeAll() }
    }

    public var isEnabled: Bool { endpoint != nil }

    public func record(_ span: TraceSpan) {
        guard endpoint != nil else { return }
        pending.append(span)
        if pending.count >= 40 {
            Task { await self.flush() }
        } else if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.flush()
            }
        }
    }

    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard let endpoint, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Tracing.otlpPayload(batch)
        _ = try? await session.data(for: request)
    }
}
