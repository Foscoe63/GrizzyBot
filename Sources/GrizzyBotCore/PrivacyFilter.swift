import Foundation

// MARK: - Privacy Filter Types (ported from GrizzyClaw)

public enum PIIType: String, Codable, Sendable, CaseIterable {
    case email = "email"
    case phone = "phone"
    case creditCard = "credit_card"
    case ssn = "ssn"
    case ipAddress = "ip_address"
    case address = "address"
    case apiKey = "api_key"
    case bearerToken = "bearer_token"
    case password = "password"
    case dob = "date_of_birth"

    public var displayName: String {
        switch self {
        case .email: return "Email"
        case .phone: return "Phone"
        case .creditCard: return "Credit Card"
        case .ssn: return "SSN"
        case .ipAddress: return "IP Address"
        case .address: return "Address"
        case .apiKey: return "API Key"
        case .bearerToken: return "Bearer Token"
        case .password: return "Password"
        case .dob: return "Date of Birth"
        }
    }

    public var severity: PrivacySeverity {
        switch self {
        case .apiKey, .bearerToken, .password, .creditCard, .ssn:
            return .critical
        case .email, .phone, .dob:
            return .high
        case .ipAddress, .address:
            return .medium
        }
    }
}

public enum PrivacySeverity: String, Codable, Sendable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
}

public struct PIIDetection: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let type: PIIType
    public let originalText: String
    public let redactedText: String
    public let confidence: Double
    public let range: Range<String.Index>?
    public let detectedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, type, originalText, redactedText, confidence, detectedAt
    }

    public init(
        id: UUID = UUID(),
        type: PIIType,
        originalText: String,
        redactedText: String,
        confidence: Double,
        range: Range<String.Index>? = nil,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.originalText = originalText
        self.redactedText = redactedText
        self.confidence = confidence
        self.range = range
        self.detectedAt = detectedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(PIIType.self, forKey: .type)
        originalText = try c.decode(String.self, forKey: .originalText)
        redactedText = try c.decode(String.self, forKey: .redactedText)
        confidence = try c.decode(Double.self, forKey: .confidence)
        detectedAt = try c.decode(Date.self, forKey: .detectedAt)
        range = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(originalText, forKey: .originalText)
        try c.encode(redactedText, forKey: .redactedText)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(detectedAt, forKey: .detectedAt)
    }
}

public struct PrivacyFilterResult: Sendable {
    public let originalText: String
    public let redactedText: String
    public let detections: [PIIDetection]
    public let hasCriticalPII: Bool
    public let wasModified: Bool

    public init(
        originalText: String,
        redactedText: String,
        detections: [PIIDetection],
        hasCriticalPII: Bool = false,
        wasModified: Bool = false
    ) {
        self.originalText = originalText
        self.redactedText = redactedText
        self.detections = detections
        self.hasCriticalPII = hasCriticalPII
        self.wasModified = wasModified
    }
}

public struct PrivacyFilterSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var redactBeforeCloudSend: Bool
    public var failClosed: Bool
    public var minimumConfidence: Double
    public var enabledTypes: Set<PIIType>

    public static let `default` = PrivacyFilterSettings(
        enabled: true,
        redactBeforeCloudSend: true,
        failClosed: true,
        minimumConfidence: 0.80,
        enabledTypes: Set(PIIType.allCases)
    )

    public init(
        enabled: Bool = true,
        redactBeforeCloudSend: Bool = true,
        failClosed: Bool = true,
        minimumConfidence: Double = 0.80,
        enabledTypes: Set<PIIType>? = nil
    ) {
        self.enabled = enabled
        self.redactBeforeCloudSend = redactBeforeCloudSend
        self.failClosed = failClosed
        self.minimumConfidence = minimumConfidence
        self.enabledTypes = enabledTypes ?? Set(PIIType.allCases)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, redactBeforeCloudSend, failClosed, minimumConfidence, enabledTypes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        redactBeforeCloudSend = try c.decodeIfPresent(Bool.self, forKey: .redactBeforeCloudSend) ?? true
        failClosed = try c.decodeIfPresent(Bool.self, forKey: .failClosed) ?? true
        minimumConfidence = try c.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? 0.80
        if let raw = try c.decodeIfPresent([String].self, forKey: .enabledTypes) {
            enabledTypes = Set(raw.compactMap(PIIType.init(rawValue:)))
            if enabledTypes.isEmpty { enabledTypes = Set(PIIType.allCases) }
        } else {
            enabledTypes = Set(PIIType.allCases)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(redactBeforeCloudSend, forKey: .redactBeforeCloudSend)
        try c.encode(failClosed, forKey: .failClosed)
        try c.encode(minimumConfidence, forKey: .minimumConfidence)
        try c.encode(enabledTypes.map(\.rawValue).sorted(), forKey: .enabledTypes)
    }
}

public enum PrivacyFilterBlockedError: LocalizedError, Sendable, Equatable {
    case criticalPII([PIIType])

    public var errorDescription: String? {
        switch self {
        case .criticalPII(let types):
            let labels = types.map(\.displayName).joined(separator: ", ")
            return "Send blocked: critical PII detected (\(labels)). Remove secrets from the message, or turn off fail-closed in Settings → Privacy."
        }
    }
}

public enum PrivacyFilter: Sendable {
    /// Applies outbound privacy policy for a user message about to leave the device.
    public static func applyForSend(
        _ text: String,
        settings: PrivacyFilterSettings = .default,
        logDirectory: URL? = nil,
        logContext: String = "outbound_send"
    ) throws -> String {
        guard settings.enabled, !text.isEmpty else { return text }

        let result = redact(text, settings: settings)
        if settings.failClosed, result.hasCriticalPII {
            let types = result.detections
                .filter { $0.type.severity == .critical }
                .map(\.type)
            PrivacyFilterLogger.log(result, directory: logDirectory, context: "\(logContext)_fail_closed")
            throw PrivacyFilterBlockedError.criticalPII(types.isEmpty ? [.apiKey] : types)
        }

        guard settings.redactBeforeCloudSend else { return text }
        if result.wasModified {
            PrivacyFilterLogger.log(result, directory: logDirectory, context: logContext)
        }
        return result.redactedText
    }

    public static func redact(
        _ text: String,
        settings: PrivacyFilterSettings = .default
    ) -> PrivacyFilterResult {
        guard settings.enabled, !text.isEmpty else {
            return PrivacyFilterResult(originalText: text, redactedText: text, detections: [], wasModified: false)
        }

        var detections: [PIIDetection] = []
        var redacted = text

        for type in PIIType.allCases where settings.enabledTypes.contains(type) {
            let matches = Self.findMatches(in: redacted, for: type)
                .filter { $0.confidence >= settings.minimumConfidence }
            detections.append(contentsOf: matches)
        }

        detections = Self.deduplicate(detections)

        var uniqueReplacements: [(original: String, redacted: String)] = []
        var seenOriginals: Set<String> = []
        for detection in detections {
            let key = "\(detection.type.rawValue):\(detection.originalText)"
            if seenOriginals.contains(key) { continue }
            seenOriginals.insert(key)
            uniqueReplacements.append((detection.originalText, detection.redactedText))
        }
        uniqueReplacements.sort { $0.original.count > $1.original.count }
        for pair in uniqueReplacements {
            redacted = redacted.replacingOccurrences(of: pair.original, with: pair.redacted)
        }

        let hasCritical = detections.contains { $0.type.severity == .critical }
        return PrivacyFilterResult(
            originalText: text,
            redactedText: redacted,
            detections: detections,
            hasCriticalPII: hasCritical,
            wasModified: !detections.isEmpty
        )
    }

    public static func containsPII(
        _ text: String,
        settings: PrivacyFilterSettings = .default
    ) -> Bool {
        !detections(in: text, settings: settings).isEmpty
    }

    public static func detections(
        in text: String,
        settings: PrivacyFilterSettings = .default
    ) -> [PIIDetection] {
        guard settings.enabled, !text.isEmpty else { return [] }
        var all: [PIIDetection] = []
        for type in PIIType.allCases where settings.enabledTypes.contains(type) {
            all.append(contentsOf: Self.findMatches(in: text, for: type)
                .filter { $0.confidence >= settings.minimumConfidence })
        }
        return Self.deduplicate(all)
    }

    fileprivate static func findMatches(in text: String, for type: PIIType) -> [PIIDetection] {
        switch type {
        case .email:
            return findRegexMatches(in: text, pattern: emailPattern, type: .email, confidence: 0.96)
        case .phone:
            return findPhoneMatches(in: text)
        case .creditCard:
            return findRegexMatches(in: text, pattern: creditCardPattern, type: .creditCard, confidence: 0.92)
        case .ssn:
            return findRegexMatches(in: text, pattern: ssnPattern, type: .ssn, confidence: 0.95)
        case .ipAddress:
            return findRegexMatches(in: text, pattern: ipPattern, type: .ipAddress, confidence: 0.94)
        case .address:
            return findAddressMatches(in: text)
        case .apiKey:
            return findAPIKeyMatches(in: text)
        case .bearerToken:
            return findRegexMatches(in: text, pattern: bearerPattern, type: .bearerToken, confidence: 0.94)
        case .password:
            return findPasswordMatches(in: text)
        case .dob:
            return findDOBMatches(in: text)
        }
    }

    fileprivate static func findRegexMatches(
        in text: String,
        pattern: String,
        type: PIIType,
        confidence: Double
    ) -> [PIIDetection] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let original = String(text[matchRange])
            let redacted = "[REDACTED \(type.rawValue.uppercased())]"
            return PIIDetection(
                type: type,
                originalText: original,
                redactedText: redacted,
                confidence: confidence,
                range: matchRange
            )
        }
    }

    fileprivate static func findPhoneMatches(in text: String) -> [PIIDetection] {
        [
            (phonePatternUS, 0.93),
            (phonePatternIntl, 0.88),
            (phonePatternShort, 0.82),
        ].flatMap { findRegexMatches(in: text, pattern: $0.0, type: .phone, confidence: $0.1) }
    }

    fileprivate static func findAddressMatches(in text: String) -> [PIIDetection] {
        [
            (addressPatternUS, 0.78),
            (addressPatternGeneric, 0.65),
        ].flatMap { findRegexMatches(in: text, pattern: $0.0, type: .address, confidence: $0.1) }
    }

    fileprivate static func findAPIKeyMatches(in text: String) -> [PIIDetection] {
        [
            (apiKeyPatternOpenAI, 0.96),
            (apiKeyPatternAnthropic, 0.95),
            (apiKeyPatternGeneric, 0.85),
            (apiKeyPatternHex, 0.80),
        ].flatMap { findRegexMatches(in: text, pattern: $0.0, type: .apiKey, confidence: $0.1) }
    }

    fileprivate static func findPasswordMatches(in text: String) -> [PIIDetection] {
        [
            (passwordPatternEnv, 0.88),
            (passwordPatternKey, 0.85),
            (passwordPatternInline, 0.76),
        ].flatMap { findRegexMatches(in: text, pattern: $0.0, type: .password, confidence: $0.1) }
    }

    fileprivate static func findDOBMatches(in text: String) -> [PIIDetection] {
        [
            (dobPatternISO, 0.82),
            (dobPatternUS, 0.80),
        ].flatMap { findRegexMatches(in: text, pattern: $0.0, type: .dob, confidence: $0.1) }
    }

    fileprivate static func deduplicate(_ detections: [PIIDetection]) -> [PIIDetection] {
        var seen: Set<String> = []
        return detections.filter { detection in
            let key = "\(detection.type.rawValue):\(detection.originalText.lowercased())"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static let emailPattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
    private static let phonePatternUS = "\\b(?:\\+?1[-. ]?)?\\(?\\d{3}\\)?[-. ]?\\d{3}[-. ]?\\d{4}\\b"
    private static let phonePatternIntl = "\\+\\d{1,3}[-.\\s]?\\(?\\d{1,4}\\)?[-.\\s]?\\d{1,4}[-.\\s]?\\d{1,9}"
    private static let phonePatternShort = "\\b\\d{3}[-. ]\\d{3}[-. ]\\d{4}\\b"
    private static let creditCardPattern = "\\b(?:\\d{4}[-\\s]?){3}\\d{4}\\b|\\b\\d{15,16}\\b"
    private static let ssnPattern = "\\b\\d{3}[-]\\d{2}[-]\\d{4}\\b"
    private static let ipPattern =
        "\\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b"
    private static let addressPatternUS =
        "\\b\\d{1,5}\\s+[A-Za-z0-9 ]+\\s+(?:Street|St|Avenue|Ave|Blvd|Boulevard|Road|Rd|Drive|Dr|Lane|Ln|Way|Court|Ct|Place|Pl)\\b,?\\s*(?:[A-Za-z ]+,\\s*)?[A-Z]{2}\\s+\\d{5}(?:-\\d{4})?\\b"
    private static let addressPatternGeneric =
        "\\b\\d+\\s+[A-Z][a-z]+(?:\\s+[A-Z][a-z]+)*\\s+(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Lane|Ln|Boulevard|Blvd)\\b"
    private static let bearerPattern = "(?i)\\b[bB]earer\\s+[A-Za-z0-9\\-._~+/]+=*\\b"
    private static let apiKeyPatternOpenAI = "(?i)\\bsk-[A-Za-z0-9]{20,}\\b"
    private static let apiKeyPatternAnthropic = "(?i)\\b(?:sk-ant|x-api-key)\\s*[:=]\\s*[A-Za-z0-9_-]{20,}\\b"
    private static let apiKeyPatternGeneric =
        "(?i)\\b(?:api[_-]?key|apikey|access[_-]?token)\\s*[:=]\\s*[A-Za-z0-9_\\-]{16,}\\b"
    private static let apiKeyPatternHex = "\\b[a-f0-9]{32,}\\b"
    private static let passwordPatternEnv = "(?i)(?:PASSWORD|PASS|SECRET|API_KEY|TOKEN)\\s*=\\s*[^\\s]+"
    private static let passwordPatternKey = "(?i)\"\\s*(?:password|passwd|pwd|secret)\\s*\"\\s*:\\s*\"[^\"]+\""
    private static let passwordPatternInline = "(?i)\\bpassword\\s*(?:is|:|=)\\s*[^\\s,;]+"
    private static let dobPatternISO = "\\b\\d{4}[-/]\\d{2}[-/]\\d{2}\\b"
    private static let dobPatternUS = "\\b\\d{2}[-/]\\d{2}[-/]\\d{4}\\b"
}

public enum PrivacyFilterLogger: Sendable {
    public static func log(
        _ result: PrivacyFilterResult,
        directory: URL?,
        context: String = "stream"
    ) {
        guard result.wasModified, !result.detections.isEmpty else { return }
        let dir = directory ?? AccountLayout.defaultGlobalRoot()
        let url = dir.appendingPathComponent("privacy_filter_log.jsonl")
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "context": context,
            "original_length": result.originalText.count,
            "redacted_length": result.redactedText.count,
            "detections_count": result.detections.count,
            "has_critical_pii": result.hasCriticalPII,
            "detections": result.detections.map { d in
                [
                    "type": d.type.rawValue,
                    "severity": d.type.severity.rawValue,
                    "confidence": d.confidence,
                    "redacted_text": d.redactedText,
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let line = json + "\n"
        try? append(line, to: url)
    }

    private static func append(_ string: String, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = string.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }
}
