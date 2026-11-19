// [pr-manage] A coding project's ⋯ › Repository…: which git repository on the computer running Hermes this project's
// chats work in, so their marks can be read from its branches (owner 2026-11-19: "Should a project have a setup to
// integrate to a GitHub repo so that everything is linked that way?"). The folder a project is named for is often not
// the repository its chats commit to, so it is asked, with the project's own folder as the first guess.

import SwiftUI

struct ProjectRepositoryPage: View {
    let project: String
    let store: SessionStore
    @State private var folder = ""
    @State private var publicRepo = ""
    @State private var linked: SessionPRRepo?
    @State private var problem: String?
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        List { Group {
            Section {
                TextField("Folder", text: $folder, prompt: Text("/Users/you/Projects/app"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("project.repository.folder")
                if let problem {
                    Text(problem).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                        .accessibilityIdentifier("project.repository.error")
                }
            } header: { HQSectionLabel { Text("Folder") } } footer: { HQSectionFooter {
                Text("The git repository on the computer running Hermes that this project’s chats work in. Each chat’s mark is read from the branches it made there.")
            } }
            Section {
                TextField("Public Repository", text: $publicRepo, prompt: Text("owner/repo"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("project.repository.public")
            } header: { HQSectionLabel { Text("Public Repository") } } footer: { HQSectionFooter {
                Text("Optional. Fill it in when the code is published to a different GitHub repository than the folder’s own.")
            } }
            if let linked {
                Section {
                    row("Main Branch", linked.main, id: "main")
                    if let name = linked.publicRepo { row(linked.mirror ? "Publishes To" : "On GitHub", name, id: "github") }
                } header: { HQSectionLabel { Text("Linked") } }
            }
            Section {
                Button(linked == nil ? "Link Repository" : "Update Link") { link() }
                    .disabled(busy || folder.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("project.repository.link")
                if linked != nil {
                    Button("Unlink", role: .destructive) { unlink() }
                        .disabled(busy)
                        .accessibilityIdentifier("project.repository.unlink")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .task {
            guard !loaded else { return }
            loaded = true
            show(store.prRepo(forProject: project))
            await store.loadPRRepos()
            if linked == nil { show(store.prRepo(forProject: project)) }
        }
    }

    private func row(_ title: String, _ value: String, id: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.hqLabel)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Color.hqLabel2).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.repository.\(id)")
    }

    private func show(_ repo: SessionPRRepo?) {
        linked = repo
        if let repo {
            folder = repo.path
            publicRepo = repo.mirror ? (repo.publicRepo ?? "") : ""
        } else if folder.isEmpty, project.hasPrefix("/") {
            folder = project
        }
    }

    private func link() {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                show(try await store.linkPRRepo(project: project, path: folder, publicRepo: publicRepo))
                Haptics.play(.success)
            } catch SessionPRRepoError.notARepository {
                problem = "That folder isn’t a git repository on the computer running Hermes."
            } catch SessionPRRepoError.invalidPublicRepo {
                problem = "Write the public repository as owner/repo."
            } catch {
                problem = "Couldn’t link the repository. Check the folder and try again."
            }
        }
    }

    private func unlink() {
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                try await store.unlinkPRRepo(project: project)
                linked = nil
            } catch {
                problem = "Couldn’t unlink the repository. Try again."
            }
        }
    }
}
