import Foundation
import Testing
@testable import GrizzyBotCore

private func decodeRaw(_ raw: String) -> String {
    var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    return String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? ""
}

@Suite("Gmail send")
struct GmailDraftTests {
    @Test("A JSON body becomes a well-formed message")
    func jsonBody() throws {
        let draft = try GmailDraft.parse(
            title: "Status",
            body: #"{"to":"a@b.com","cc":"c@d.com","body":"All good."}"#
        )
        #expect(draft.to == ["a@b.com"])
        #expect(draft.cc == ["c@d.com"])
        #expect(draft.subject == "Status")

        let message = decodeRaw(draft.rawMessage())
        #expect(message.contains("To: a@b.com"))
        #expect(message.contains("Cc: c@d.com"))
        #expect(message.contains("Subject: Status"))
        #expect(message.contains("Content-Type: text/plain; charset=UTF-8"))
        // Headers and body separated by a blank line, CRLF throughout.
        #expect(message.contains("\r\n\r\nAll good."))
    }

    @Test("A header block with prose underneath works")
    func headerBlock() throws {
        let draft = try GmailDraft.parse(
            title: "",
            body: "to: a@b.com\nsubject: Hello\n\nFirst line.\nSecond line."
        )
        #expect(draft.to == ["a@b.com"])
        #expect(draft.subject == "Hello")
        #expect(draft.body == "First line.\nSecond line.")
    }

    @Test("Several recipients split on commas and semicolons")
    func multipleRecipients() throws {
        let draft = try GmailDraft.parse(title: "x", body: #"{"to":"a@b.com, c@d.com; e@f.com","body":"hi"}"#)
        #expect(draft.to == ["a@b.com", "c@d.com", "e@f.com"])
        #expect(decodeRaw(draft.rawMessage()).contains("To: a@b.com, c@d.com, e@f.com"))
    }

    @Test("HTML bodies are declared as HTML")
    func htmlBody() throws {
        let draft = try GmailDraft.parse(title: "x", body: #"{"to":"a@b.com","html":"<p>hi</p>"}"#)
        #expect(draft.isHTML)
        #expect(decodeRaw(draft.rawMessage()).contains("Content-Type: text/html"))
    }

    @Test("A non-ASCII subject is encoded rather than mangled")
    func unicodeSubject() throws {
        let draft = try GmailDraft.parse(title: "Café ☕", body: #"{"to":"a@b.com","body":"hi"}"#)
        let message = decodeRaw(draft.rawMessage())
        #expect(message.contains("Subject: =?UTF-8?B?"))
        #expect(!message.contains("Subject: Café"))
    }

    @Test("No recipient is refused rather than sent into the void")
    func missingRecipient() {
        #expect(throws: PluginError.self) {
            _ = try GmailDraft.parse(title: "Subject", body: "just some prose")
        }
    }

    @Test("A malformed address is refused")
    func badAddress() {
        #expect(throws: PluginError.self) {
            _ = try GmailDraft.parse(title: "x", body: #"{"to":"not-an-address","body":"hi"}"#)
        }
    }

    @Test("An empty body is refused")
    func emptyBody() {
        #expect(throws: PluginError.self) {
            _ = try GmailDraft.parse(title: "x", body: #"{"to":"a@b.com"}"#)
        }
    }

    @Test("The raw message is base64url with no padding")
    func base64URLShape() throws {
        let draft = try GmailDraft.parse(title: "x", body: #"{"to":"a@b.com","body":"hi"}"#)
        let raw = draft.rawMessage()
        #expect(!raw.contains("+"))
        #expect(!raw.contains("/"))
        #expect(!raw.contains("="))
    }
}

@Suite("Sheets references")
struct SheetsRefTests {
    private let id = "1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"

    @Test("A bare id gets a default range")
    func bareId() throws {
        let ref = try SheetsRef.parse(id)
        #expect(ref.spreadsheetId == id)
        #expect(ref.range == SheetsRef.defaultRange)
    }

    @Test("A full Sheets URL yields the id")
    func fromURL() throws {
        let ref = try SheetsRef.parse("https://docs.google.com/spreadsheets/d/\(id)/edit#gid=0")
        #expect(ref.spreadsheetId == id)
    }

    @Test("id!Range splits correctly")
    func bangRange() throws {
        let ref = try SheetsRef.parse("\(id)!Sheet1!A1:C10")
        #expect(ref.spreadsheetId == id)
        #expect(ref.range == "Sheet1!A1:C10")
    }

    @Test("JSON carries id and range")
    func jsonRef() throws {
        let ref = try SheetsRef.parse(#"{"spreadsheetId":"\#(id)","range":"Q3!A1:D20"}"#)
        #expect(ref.spreadsheetId == id)
        #expect(ref.range == "Q3!A1:D20")
    }

    @Test("Something that is not an id is refused with a usable message")
    func rejectsProse() {
        #expect(throws: PluginError.self) { _ = try SheetsRef.parse("my budget sheet") }
        #expect(throws: PluginError.self) { _ = try SheetsRef.parse("") }
    }

    @Test("Rows parse from JSON, TSV, and CSV")
    func rowParsing() {
        let json = SheetsRef.rows(from: #"{"values":[["a","b"],["c","d"]]}"#)
        #expect(json == [["a", "b"], ["c", "d"]])

        let tsv = SheetsRef.rows(from: "a\tb\nc\td")
        #expect(tsv == [["a", "b"], ["c", "d"]])

        let csv = SheetsRef.rows(from: "a, b\nc, d")
        #expect(csv == [["a", "b"], ["c", "d"]])
    }

    @Test("Numbers in JSON rows survive as text")
    func numericRows() {
        #expect(SheetsRef.rows(from: #"{"values":[["Jan",1200]]}"#) == [["Jan", "1200"]])
    }
}

@Suite("Drive uploads")
struct DriveUploadTests {
    @Test("The multipart body has both parts and closes its boundary")
    func multipartShape() throws {
        let data = DriveUpload.multipart(
            name: "notes.md", mimeType: "text/markdown", content: "# Hi", folderId: nil
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("--\(DriveUpload.boundary)"))
        #expect(text.contains("Content-Type: application/json; charset=UTF-8"))
        #expect(text.contains("\"name\":\"notes.md\"") || text.contains("\"name\": \"notes.md\""))
        #expect(text.contains("Content-Type: text/markdown; charset=UTF-8"))
        #expect(text.contains("# Hi"))
        #expect(text.hasSuffix("--\(DriveUpload.boundary)--\r\n"))
    }

    @Test("A parent folder lands in the metadata")
    func parentFolder() {
        let text = String(
            data: DriveUpload.multipart(name: "a.txt", mimeType: "text/plain", content: "x", folderId: "FOLDER1"),
            encoding: .utf8
        ) ?? ""
        #expect(text.contains("FOLDER1"))
        #expect(text.contains("parents"))
    }

    @Test("Mime types follow the file name")
    func mimeTypes() {
        #expect(DriveUpload.mimeType(for: "a.md") == "text/markdown")
        #expect(DriveUpload.mimeType(for: "a.csv") == "text/csv")
        #expect(DriveUpload.mimeType(for: "a.json") == "application/json")
        #expect(DriveUpload.mimeType(for: "a.unknown") == "text/plain")
    }
}
