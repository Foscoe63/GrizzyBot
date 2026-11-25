import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct AddressInputTests {
    @Test func addressesBecomeWebPages() {
        #expect(AddressInput.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(AddressInput.resolve("  https://example.com/a?b=1 ")?.absoluteString == "https://example.com/a?b=1")
        #expect(AddressInput.resolve("http://localhost:3000/x")?.absoluteString == "http://localhost:3000/x")
        #expect(AddressInput.resolve("localhost:3000")?.absoluteString == "https://localhost:3000")
        #expect(AddressInput.resolve("example.com:8080/path")?.absoluteString == "https://example.com:8080/path")
    }

    @Test func wordsBecomeASearch() {
        let url = AddressInput.resolve("best running shoes & more")?.absoluteString ?? ""
        #expect(url.hasPrefix(AddressInput.searchBase))
        #expect(url.contains("best%20running%20shoes%20%26%20more"))
        #expect(AddressInput.resolve("weather")?.absoluteString == AddressInput.searchBase + "weather")
    }

    @Test func nonWebSchemesAreRefused() {
        for bad in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "file://localhost/etc/passwd",
                    "mailto:a@b.com", "ftp://example.com", "about:blank", "", "   ", "a\nb"] {
            #expect(AddressInput.resolve(bad) == nil, "\(bad)")
        }
    }
}
