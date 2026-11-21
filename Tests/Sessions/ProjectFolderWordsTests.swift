import Foundation
import Testing
@testable import HermesHQNative

/// [new-project-folder] New Project › Choose Folder…: where the browser opens, what it lists, the name it offers.
@Suite struct ProjectFolderWordsTests {
    @Test func parent() {
        #expect(ProjectFolderWords.parent(of: "/Users/sam/Projects/site") == "/Users/sam/Projects")
        #expect(ProjectFolderWords.parent(of: "/Users/sam/Projects/") == "/Users/sam")
        #expect(ProjectFolderWords.parent(of: "/Users") == "/")
        #expect(ProjectFolderWords.parent(of: "/") == nil)
    }

    @Test func startsPreferWhatWasTypedThenProjectsThenHome() {
        #expect(ProjectFolderWords.starts(typed: "", home: "/Users/sam", defaultFolder: "/Users/sam/work")
                == ["/Users/sam/Projects", "/Users/sam", "/Users/sam/work", "/"])
        #expect(ProjectFolderWords.starts(typed: "~/code/app/", home: "/Users/sam", defaultFolder: nil)
                == ["/Users/sam/code/app", "/Users/sam/Projects", "/Users/sam", "/"])
        #expect(ProjectFolderWords.starts(typed: "/srv/site", home: nil, defaultFolder: nil) == ["/srv/site", "/"])
        // A "~" path with no known home, or a relative one, can't be listed: it is left out.
        #expect(ProjectFolderWords.starts(typed: "~/code", home: nil, defaultFolder: "/srv") == ["/srv", "/"])
        #expect(ProjectFolderWords.starts(typed: "code", home: nil, defaultFolder: nil) == ["/"])
    }

    @Test func foldersLeaveOutFilesAndHiddenFolders() {
        let entries = [WorkspaceEntry(name: "notes.txt", path: "/p/notes.txt", isDirectory: false),
                       WorkspaceEntry(name: "site10", path: "/p/site10", isDirectory: true),
                       WorkspaceEntry(name: ".git", path: "/p/.git", isDirectory: true),
                       WorkspaceEntry(name: "site2", path: "/p/site2", isDirectory: true)]
        #expect(ProjectFolderWords.folders(entries).map(\.name) == ["site2", "site10"])
    }

    @Test func suggestedNameIsTheFolderName() {
        #expect(ProjectFolderWords.suggestedName(folder: "/Users/sam/Projects/hermes-hq-native/") == "hermes-hq-native")
        #expect(ProjectFolderWords.suggestedName(folder: "/") == "")
    }

    @Test func reasons() {
        #expect(ProjectFolderWords.reason("permission-denied") == "Hermes isn’t allowed to open this folder.")
        #expect(ProjectFolderWords.reason("whatever") == "This folder couldn’t be opened.")
    }
}
