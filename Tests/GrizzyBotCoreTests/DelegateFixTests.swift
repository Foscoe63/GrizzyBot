import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Delegate reports and web_fetch JSON")
struct DelegateFixTests {
    private func githubItem(_ i: Int) -> [String: Any] {
        let owner: [String: Any] = [
            "login": "owner\(i)", "id": i, "node_id": "N\(i)", "avatar_url": "https://a/\(i)",
            "gravatar_id": "", "url": "https://api/\(i)", "html_url": "https://github.com/owner\(i)",
            "followers_url": "https://api/f", "site_admin": false,
        ]
        var item: [String: Any] = [
            "id": i, "node_id": "R\(i)", "name": "repo\(i)", "full_name": "owner\(i)/repo\(i)",
            "private": false, "owner": owner, "html_url": "https://github.com/owner\(i)/repo\(i)",
            "description": "Repo number \(i)", "stargazers_count": 100_000 - i, "forks_count": i,
            "language": "Swift", "license": ["key": "mit", "node_id": "L"], "homepage": NSNull(),
            "has_issues": true, "has_wiki": true, "score": 1.0,
        ]
        for key in ["forks", "keys", "teams", "hooks", "issue_events", "events", "assignees", "branches",
                    "tags", "blobs", "git_tags", "git_refs", "trees", "statuses", "languages", "stargazers",
                    "contributors", "subscribers", "subscription", "commits", "git_commits", "comments",
                    "issue_comment", "contents", "compare", "merges", "archive", "downloads", "issues",
                    "pulls", "milestones", "notifications", "labels", "releases", "deployments"] {
            item["\(key)_url"] = "https://api.github.com/repos/owner\(i)/repo\(i)/\(key){/arg}"
        }
        return item
    }

    @Test("a GitHub search response keeps every repo's stars, licence and language")
    func githubSearchSurvives() throws {
        let items = (1...30).map(githubItem)
        let data = try JSONSerialization.data(withJSONObject: ["total_count": 30, "items": items])
        #expect(data.count > 60_000)
        let text = try #require(WebSearch.compactJSON(data))
        #expect(text.count <= 12_400)
        #expect(!text.contains("truncated"))
        for i in [1, 15, 30] {
            #expect(text.contains("\"stargazers_count\":\(100_000 - i)"))
            #expect(text.contains("owner\(i)/repo\(i)"))
        }
        #expect(text.contains("\"license\""))
        #expect(!text.contains("avatar_url"))
        #expect(!text.contains("forks_url"))
        #expect(!text.contains("node_id"))
    }

    @Test("a response too big to fit is cut from the end and says so")
    func truncationKeepsHead() throws {
        let items = (1...200).map(githubItem)
        let data = try JSONSerialization.data(withJSONObject: ["items": items])
        let text = try #require(WebSearch.compactJSON(data))
        #expect(text.contains("repo1\""))
        #expect(text.contains("truncated"))
        #expect(!text.contains("repo200"))
    }

    @Test("plain url fields outside API records are kept; HTML is not treated as JSON")
    func nonRecordsUntouched() throws {
        let data = Data(#"{"items":[{"url":"https://x.test/a","title":"A"}]}"#.utf8)
        let text = try #require(WebSearch.compactJSON(data))
        #expect(text.contains("https://x.test/a"))
        #expect(WebSearch.compactJSON(Data("<html><body>hi</body></html>".utf8)) == nil)
        #expect(WebSearch.compactJSON(Data("not json".utf8), declaredJSON: true) == nil)
    }

    private let ramble = String(
        repeating: "Wait, that doesn't work. Hmm, let me try another way. Actually, I need to rethink this. ",
        count: 14
    )

    @Test("working-out is recognised; real reports are not")
    func scratchpadDetection() {
        #expect(DelegateReport.looksLikeScratchpad(ramble))
        #expect(DelegateReport.shortfall(reply: ramble) != nil)
        #expect(DelegateReport.shortfall(reply: "  \n") != nil)

        let report = "# Top repos\n\n## Summary\n\n| Repo | Stars |\n|---|---|\n| a | 1 |\n\n"
            + String(repeating: "Wait, the list is ranked by stars; let me know if you want forks too. ", count: 14)
        #expect(!DelegateReport.looksLikeScratchpad(report))
        #expect(DelegateReport.shortfall(reply: "Here are the three results you asked for.") == nil)
    }

    @Test("the failure notice is short, names the peer, and says what to do")
    func noticeIsShort() {
        let notice = DelegateReport.failureNotice(peer: "Researcher", task: "Find repos", reason: "it ended without a result.", lastWords: ramble)
        #expect(notice.contains("Researcher did not finish"))
        #expect(notice.contains("narrower job"))
        #expect(notice.count < 600)
    }
}
