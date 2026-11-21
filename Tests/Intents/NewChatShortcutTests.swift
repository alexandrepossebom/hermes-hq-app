// [shortcut-new-chat] The New Chat shortcut's stored projects and its `new-chat` link (owner 2026-11-20).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct NewChatShortcutTests {
    private let account = "http://127.0.0.1:9920\nfixture"

    @Test func storesTheNewChatSheetsProjectsWithoutHomeOrFolderlessOnes() {
        let entries = [
            SessionProjectEntry(key: SessionProjects.homeKey, label: "Home"),
            SessionProjectEntry(key: "/Users/me/Projects/hq", label: "Hermes  HQ"),
            SessionProjectEntry(key: "id:app/42", label: "No Folder"),
            SessionProjectEntry(key: "/Users/me/Projects/hq", label: "Twice"),
            SessionProjectEntry(key: "~/scratch", label: "Scratch", isFolder: true),
        ]
        let records = ProjectShortcutCatalog.records(entries, account: account)
        #expect(records == [ProjectShortcutRecord(key: "/Users/me/Projects/hq", name: "Hermes HQ", account: account),
                            ProjectShortcutRecord(key: "~/scratch", name: "Scratch", account: account)])
        let box = IntentsDefaults()
        #expect(ProjectShortcutCatalog.store(records, box.defaults))
        #expect(!ProjectShortcutCatalog.store(records, box.defaults), "the same projects are not written twice")
        #expect(ProjectShortcutCatalog.projects(box.defaults) == records)
        ProjectShortcutCatalog.clear(box.defaults)
        #expect(ProjectShortcutCatalog.projects(box.defaults).isEmpty)
    }

    @Test func resolvesAProjectByFolderThenByName() {
        let records = [ProjectShortcutRecord(key: "/srv/app", name: "App", account: account),
                       ProjectShortcutRecord(key: "/srv/web", name: "Website", account: account)]
        #expect(ProjectShortcutCatalog.resolve("/srv/web/", in: records)?.key == "/srv/web")
        #expect(ProjectShortcutCatalog.resolve("  website ", in: records)?.key == "/srv/web")
        #expect(ProjectShortcutCatalog.resolve("/srv/other", in: records) == nil)
        #expect(ProjectShortcutCatalog.resolve("", in: records) == nil)
    }

    @Test func parsesAndWritesTheNewChatLink() throws {
        let scheme = AppIdentity.current.urlScheme
        let url = try #require(URL(string: "\(scheme)://new-chat?bot=app&project=%2FUsers%2Fme%2FProjects%2Fhq"))
        #expect(NewChatLink.parse(DeepLink.parse(url, scheme: scheme)) == NewChatLink(bot: "app", project: "/Users/me/Projects/hq"))
        let bare = try #require(URL(string: "\(scheme)://new-chat?bot=Hermes"))
        #expect(NewChatLink.parse(DeepLink.parse(bare, scheme: scheme)) == NewChatLink(bot: "Hermes", project: nil))
        let blankProject = try #require(URL(string: "\(scheme)://new-chat?bot=app&project="))
        #expect(NewChatLink.parse(DeepLink.parse(blankProject, scheme: scheme))?.project == nil)
        // No bot, or another kind of link: not one.
        #expect(NewChatLink.parse(DeepLink.parse(try #require(URL(string: "\(scheme)://new-chat?project=x")), scheme: scheme)) == nil)
        #expect(NewChatLink.parse(DeepLink.parse(try #require(URL(string: "\(scheme)://job/abc?bot=app")), scheme: scheme)) == nil)
        // What it writes, it reads back (a folder with spaces too).
        let link = NewChatLink(bot: "app", project: "/Users/me/My Projects/hq")
        let written = try #require(link.url(scheme: scheme))
        #expect(NewChatLink.parse(DeepLink.parse(written, scheme: scheme)) == link)
    }
}
