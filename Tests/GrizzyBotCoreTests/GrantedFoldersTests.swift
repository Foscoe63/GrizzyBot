import Foundation
import GrizzyBotCore
import Testing

@Suite("GrantedFolders")
struct GrantedFoldersTests {
    private let docs = GrantedFolder(name: "Docs", path: "/tmp/gb-granted/docs")

    @Test("contains the folder and its children, not siblings or lookalikes")
    func containment() {
        #expect(GrantedFolders.contains("/tmp/gb-granted/docs", in: [docs]))
        #expect(GrantedFolders.contains("/tmp/gb-granted/docs/a/b.md", in: [docs]))
        #expect(!GrantedFolders.contains("/tmp/gb-granted/docs-other/a.md", in: [docs]))
        #expect(!GrantedFolders.contains("/tmp/gb-granted/docs/../secret.md", in: [docs]))
        #expect(!GrantedFolders.contains("/tmp/gb-granted/docs/a.md", in: []))
    }

    @Test("secret paths stay blocked inside a granted folder")
    func secretsBlocked() {
        #expect(!GrantedFolders.contains("/tmp/gb-granted/docs/.env", in: [docs]))
        #expect(!GrantedFolders.contains("/tmp/gb-granted/docs/.ssh/id_rsa", in: [docs]))
        let ssh = GrantedFolder(name: "ssh", path: "~/.ssh")
        #expect(GrantedFolders.writeRoots([ssh]).isEmpty)
    }

    @Test("prompt note lists folders and is empty with none")
    func promptNote() {
        #expect(GrantedFolders.promptNote([]).isEmpty)
        let note = GrantedFolders.promptNote([docs])
        #expect(note.contains("Docs: /tmp/gb-granted/docs"))
    }

    @Test("bots without the field decode with no granted folders")
    func legacyBotDecodes() throws {
        let json = """
        {"id":"b1","name":"Old","color":"#fff","threadId":"t1"}
        """
        let bot = try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        #expect(bot.grantedFolderIds.isEmpty)
        var withFolder = bot
        withFolder.grantedFolderIds = ["f1"]
        let round = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(withFolder))
        #expect(round.grantedFolderIds == ["f1"])
    }
}
