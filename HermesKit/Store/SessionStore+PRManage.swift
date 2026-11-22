// [pr-manage] What the owner says about a coding project's chats from the app (add-on 0.9.70): which repository a
// project's branches live in, and that a chat's changes are closed. Owner 2026-11-19: "Should a project have a setup to
// integrate to a GitHub repo so that everything is linked that way?" and "How do I mark a PR as closed". A gateway
// without the add-on's routes answers 404 to the first read, `prRepos` stays nil and nothing of this shows.

import Foundation

/// A repository on the computer running Hermes that chats' branches are looked for in.
nonisolated struct SessionPRRepo: Hashable, Sendable {
    /// The project it was linked from (the app's project key); nil for one listed by hand on that computer.
    var project: String?
    var path: String
    var main: String
    var publicRepo: String?
    /// Its main is published to another repository (a publisher's marker is kept in it).
    var mirror: Bool

    init?(_ value: JSONValue?) {
        guard let path = value?["path"]?.string, !path.isEmpty else { return nil }
        project = value?["project"]?.string
        self.path = path
        main = value?["main"]?.string ?? "main"
        publicRepo = value?["public_repo"]?.string
        mirror = value?["mirror"]?.bool ?? false
    }
}

nonisolated enum SessionPRRepoError: Error, Equatable {
    /// The folder is not a git repository on the computer running Hermes.
    case notARepository
    /// The public repository isn't written as owner/repo.
    case invalidPublicRepo
    case invalid
}

extension SessionStore {
    nonisolated static let prReposPath = "/api/plugins/hermes-hq-push/sessions/pr-repos"
    nonisolated static let prMarkPath = "/api/plugins/hermes-hq-push/sessions/pr-mark"

    /// The gateway takes links and marks (its list of repositories was read).
    var prManage: Bool { prRepos != nil }

    func prRepo(forProject key: String) -> SessionPRRepo? { prRepos?.first { $0.project == key } }

    /// Reads the linked repositories. A failed read keeps what was known (nothing, the first time).
    func loadPRRepos() async {
        guard !stopped, let data = try? await client.rest("GET", Self.prReposPath, query: [], body: nil),
              let rows = (try? JSONValue.parse(data))?["repos"]?.array else { return }
        let repos = rows.compactMap { SessionPRRepo($0) }
        guard repos != prRepos else { return }
        prRepos = repos
        onChange?()
    }

    @discardableResult
    func linkPRRepo(project: String, path: String, publicRepo: String?) async throws -> SessionPRRepo {
        let named = publicRepo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: JSONValue = ["project": .string(project), "path": .string(path.trimmingCharacters(in: .whitespacesAndNewlines)),
                               "public_repo": named.isEmpty ? .null : .string(named)]
        let data: Data
        do {
            data = try await client.rest("PUT", Self.prReposPath, query: [], body: body.encoded())
        } catch let error as HTTPError where error.status == 422 {
            let detail = error.body ?? ""
            throw detail.contains("not_a_repository") ? SessionPRRepoError.notARepository
                : detail.contains("invalid_public_repo") ? SessionPRRepoError.invalidPublicRepo : SessionPRRepoError.invalid
        }
        guard let repo = SessionPRRepo(try JSONValue.parse(data)["repo"]) else { throw SessionPRRepoError.invalid }
        prRepos = (prRepos ?? []).filter { $0.project != project } + [repo]
        codingProjectsChanged()   // the labels are read again against the new repository
        onChange?()
        return repo
    }

    func unlinkPRRepo(project: String) async throws {
        _ = try await client.rest("DELETE", Self.prReposPath, query: [URLQueryItem(name: "project", value: project)], body: nil)
        prRepos = (prRepos ?? []).filter { $0.project != project }
        codingProjectsChanged()
        onChange?()
    }

    /// The owner's own label on a chat (nothing in any repository changes), then the chat's status read again.
    func setPRClosed(_ session: SessionSummary, _ closed: Bool) async throws {
        let body: JSONValue = ["profile": .string(session.profile), "id": .string(session.id), "closed": .bool(closed)]
        _ = try await client.rest("PUT", Self.prMarkPath, query: [], body: body.encoded())
        await refreshPullRequests(for: [session], force: true)
    }

    /// Turning Coding Project on for a project whose key is a folder: that folder is tried as its repository, quietly.
    func linkOwnFolderIfUnlinked(_ key: String) {
        guard prManage, key.hasPrefix("/"), prRepo(forProject: key) == nil else { return }
        Task { [weak self] in _ = try? await self?.linkPRRepo(project: key, path: key, publicRepo: nil) }
    }
}
