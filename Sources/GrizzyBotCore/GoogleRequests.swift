import Foundation

/// Request bodies for the Google plugins.
///
/// `plugin_call` hands every connector one `title` and one `body`, so anything
/// with more structure than that — a recipient, a sheet range, a file name —
/// has to be parsed out of the body. The parsing lives here, away from the
/// networking, so the awkward parts (address lists, A1 ranges, multipart
/// boundaries) can be tested without a Google account.
public enum GoogleRequests {
    /// Shared shape: JSON object, `key: value` lines, or plain prose.
    /// Prose becomes the body text, which is what a model produces when it is
    /// just writing an email.
    public static func fields(_ raw: String) -> (fields: [String: String], remainder: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([:], "") }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: String] = [:]
            for (key, value) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                switch value {
                case let text as String: out[normalized] = text
                case let number as NSNumber: out[normalized] = number.stringValue
                case let list as [Any]:
                    out[normalized] = list.compactMap { $0 as? String }.joined(separator: ", ")
                default: continue
                }
            }
            return (out, "")
        }

        // Header block: `key: value` lines, then a blank line, then the body.
        var out: [String: String] = [:]
        var lines = trimmed.components(separatedBy: "\n")
        var consumed = 0
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { consumed += 1; break }
            guard let separator = text.firstIndex(of: ":") else { break }
            let key = text[text.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { break }
            out[key] = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            consumed += 1
        }
        if out.isEmpty { return ([:], trimmed) }
        lines.removeFirst(min(consumed, lines.count))
        return (out, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Gmail

public struct GmailDraft: Sendable, Equatable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var isHTML: Bool

    public init(
        to: [String], cc: [String] = [], bcc: [String] = [],
        subject: String, body: String, isHTML: Bool = false
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
    }

    public static func parse(title: String, body rawBody: String) throws -> GmailDraft {
        let (fields, remainder) = GoogleRequests.fields(rawBody)

        func addresses(_ keys: String...) -> [String] {
            for key in keys {
                if let value = fields[key], !value.isEmpty {
                    return value
                        .components(separatedBy: CharacterSet(charactersIn: ",;"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            }
            return []
        }

        let to = addresses("to", "recipient", "recipients")
        guard !to.isEmpty else {
            throw PluginError.rejected(
                "No recipient — nothing was sent. Put one in the body, e.g. {\"to\":\"a@b.com\",\"body\":\"…\"} or a `to:` line."
            )
        }
        for address in to + addresses("cc") + addresses("bcc") where !address.contains("@") {
            throw PluginError.rejected("\(address) is not an email address — nothing was sent.")
        }

        let subject = [fields["subject"], title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let html = fields["html"]
        let text = [html, fields["body"], fields["text"], fields["message"], remainder.isEmpty ? nil : remainder]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        guard !text.isEmpty else {
            throw PluginError.rejected("The message has no body — nothing was sent.")
        }
        return GmailDraft(
            to: to,
            cc: addresses("cc"),
            bcc: addresses("bcc"),
            subject: subject,
            body: text,
            isHTML: html?.isEmpty == false
        )
    }

    /// RFC 2822, base64url encoded, which is what `users.messages.send` takes.
    /// Non-ASCII subjects are encoded-word wrapped so accents survive.
    public func rawMessage() -> String {
        var headers = ["To: \(to.joined(separator: ", "))"]
        if !cc.isEmpty { headers.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { headers.append("Bcc: \(bcc.joined(separator: ", "))") }
        headers.append("Subject: \(Self.encodedHeader(subject))")
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: text/\(isHTML ? "html" : "plain"); charset=UTF-8")
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Data(message.utf8).base64URLEncoded()
    }

    static func encodedHeader(_ raw: String) -> String {
        guard raw.contains(where: { !$0.isASCII }) else { return raw }
        return "=?UTF-8?B?\(Data(raw.utf8).base64EncodedString())?="
    }
}

// MARK: - Sheets

public struct SheetsRef: Sendable, Equatable {
    public var spreadsheetId: String
    /// A1 notation. Defaults to a wide first-sheet window when unspecified.
    public var range: String

    public init(spreadsheetId: String, range: String) {
        self.spreadsheetId = spreadsheetId
        self.range = range
    }

    public static let defaultRange = "A1:Z200"

    /// Accepts a bare id, a full Sheets URL, `id!A1:C10`, or JSON/`key: value`.
    public static func parse(_ raw: String) throws -> SheetsRef {
        let (fields, remainder) = GoogleRequests.fields(raw)
        let source = fields["spreadsheetid"] ?? fields["spreadsheet_id"] ?? fields["spreadsheet"]
            ?? fields["id"] ?? fields["url"] ?? (remainder.isEmpty ? raw : remainder)
        var id = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var range = fields["range"] ?? fields["a1"] ?? ""

        if let found = idFromURL(id) { id = found }
        if let bang = id.firstIndex(of: "!"), range.isEmpty {
            range = String(id[id.index(after: bang)...])
            id = String(id[id.startIndex..<bang])
        }
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(" "), id.count >= 10 else {
            throw PluginError.rejected(
                "Which spreadsheet? Pass its id or URL, optionally with a range — e.g. {\"spreadsheetId\":\"1AbC…\",\"range\":\"Sheet1!A1:C10\"}."
            )
        }
        return SheetsRef(spreadsheetId: id, range: range.isEmpty ? defaultRange : range)
    }

    static func idFromURL(_ raw: String) -> String? {
        guard raw.contains("docs.google.com") || raw.contains("/d/") else { return nil }
        let parts = raw.components(separatedBy: "/")
        guard let marker = parts.firstIndex(of: "d"), parts.count > marker + 1 else { return nil }
        return parts[marker + 1]
    }

    /// The rows a write should append. Accepts JSON `values`, TSV, or CSV.
    public static func rows(from raw: String) -> [[String]] {
        let (fields, remainder) = GoogleRequests.fields(raw)
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let values = object["values"] as? [[Any]] {
            return values.map { $0.map { cell in
                (cell as? String) ?? ((cell as? NSNumber)?.stringValue ?? "")
            } }
        }
        let text = fields["rows"] ?? fields["values"] ?? (remainder.isEmpty ? raw : remainder)
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let separator: Character = line.contains("\t") ? "\t" : ","
                return line.split(separator: separator, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }
}

// MARK: - Drive

public enum DriveUpload {
    public static let boundary = "grizzybot-upload-boundary"

    /// Multipart body for `uploadType=multipart`: metadata part, then content.
    public static func multipart(name: String, mimeType: String, content: String, folderId: String?) -> Data {
        var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
        if let folderId, !folderId.isEmpty { metadata["parents"] = [folderId] }
        let metadataJSON = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8)

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataJSON)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType); charset=UTF-8\r\n\r\n".utf8))
        body.append(Data(content.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Best-effort type from the file name, so an uploaded .md is not
    /// presented to Drive as an opaque blob.
    public static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "xml": return "text/xml"
        case "swift", "py", "rb", "go", "rs", "sh": return "text/plain"
        default: return "text/plain"
        }
    }
}

extension Data {
    /// base64url with padding stripped, as Gmail's `raw` field requires.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
