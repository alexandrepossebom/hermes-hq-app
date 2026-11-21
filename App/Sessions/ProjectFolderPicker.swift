// [new-project-folder] New Project › Choose Folder…: a browser of the folders on the gateway's computer, so a
// project's folder is picked rather than typed (owner 2026-11-21: making a project "isn't easy to do"; the alert
// wanted a whole path typed on a phone). It lists `GET /api/fs/list` for the project's bot, opens in the gateway
// user's Projects folder when there is one, and hands back the folder it is showing.

import SwiftUI
import UIKit

@MainActor @Observable final class ProjectFolderBrowser {
    enum Phase: Equatable { case loading, listed, failed(String) }

    @ObservationIgnored let workspace: ChatWorkspace
    @ObservationIgnored private let typed: String
    private(set) var path: String?
    private(set) var folders: [WorkspaceEntry] = []
    private(set) var phase: Phase = .loading
    private(set) var home: String?
    @ObservationIgnored private var visit = 0

    init(workspace: ChatWorkspace, typed: String) {
        self.workspace = workspace
        self.typed = typed
    }

    var parent: String? { path.flatMap(ProjectFolderWords.parent(of:)) }
    var shownPath: String { path.map { MoreWorkspaceRoot.display($0, home: home) } ?? "" }

    /// The first open: the home (for "~" and the Projects folder) and the gateway's default folder, then the first
    /// start that lists.
    func start() async {
        guard path == nil else { return }
        let client = workspace.client
        let profile = workspace.profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        async let profiles = try? client.rest("GET", "/api/profiles", query: [], body: nil)
        async let cwd = try? client.rest("GET", "/api/fs/default-cwd", query: profile, body: nil)
        let (profilesData, cwdData) = await (profiles, cwd)
        home = profilesData.flatMap { try? JSONValue.parse($0) }.flatMap(MoreWorkspaceRoot.gatewayHome(profiles:))
        let defaultFolder = cwdData.flatMap { try? JSONValue.parse($0) }?["cwd"]?.nonEmptyString
        let starts = ProjectFolderWords.starts(typed: typed, home: home, defaultFolder: defaultFolder)
        for candidate in starts {
            if let listed = try? await workspace.list(candidate) {
                show(candidate, listed)
                return
            }
        }
        path = starts.last
        phase = .failed(ProjectFolderWords.reason(""))
    }

    func open(_ next: String) {
        visit += 1
        let mine = visit
        path = ProjectFolderWords.normalized(next)
        folders = []
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let listed = try await self.workspace.list(next)
                guard mine == self.visit else { return }
                self.show(next, listed)
            } catch {
                guard mine == self.visit else { return }
                let said = (error as? MenusError)?.message
                self.phase = .failed(said.map(ProjectFolderWords.reason) ?? SessionActionText.reason(error))
            }
        }
    }

    private func show(_ shown: String, _ listed: [WorkspaceEntry]) {
        path = ProjectFolderWords.normalized(shown)
        folders = ProjectFolderWords.folders(listed)
        phase = .listed
    }
}

struct ProjectFolderPickerView: View {
    @State var browser: ProjectFolderBrowser
    var choose: (String) -> Void

    private static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)

    var body: some View {
        List {
            Section {
                if let parent = browser.parent {
                    row(icon: "arrow.turn.left.up", title: (parent as NSString).lastPathComponent == "/" ? "Up" : "Up to \(name(parent))",
                        tint: Color.hqLabel2, chevron: false) { browser.open(parent) }
                        .accessibilityIdentifier("project-folder-up")
                }
                switch browser.phase {
                case .loading:
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: HQFont.scaled(44))
                        .accessibilityIdentifier("project-folder-loading")
                case .failed(let reason):
                    Text(reason).foregroundStyle(Color.hqLabel2)
                        .frame(minHeight: HQFont.scaled(44))
                        .accessibilityIdentifier("project-folder-error")
                case .listed:
                    if browser.folders.isEmpty {
                        Text("No folders in here.").foregroundStyle(Color.hqLabel2)
                            .frame(minHeight: HQFont.scaled(44))
                            .accessibilityIdentifier("project-folder-empty")
                    }
                    ForEach(browser.folders, id: \.path) { folder in
                        row(icon: "folder", title: folder.name, tint: Color.hqLabel, chevron: true) { browser.open(folder.path) }
                            .accessibilityIdentifier("project-folder-\(folder.name)")
                    }
                }
            } header: {
                // The whole path, cut in the middle when long: the end (the folder being shown) always reads.
                HQSectionLabel { Text(browser.shownPath).lineLimit(1).truncationMode(.middle) }
                    .accessibilityIdentifier("project-folder-path")
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Button {
                if let path = browser.path { choose(path) }
            } label: {
                Text(browser.path.map { "Use “\(name($0))”" } ?? "Use This Folder")
                    .font(Font.hq(.body).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: HQFont.scaled(30))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.hqTint)
            .disabled(browser.path == nil || browser.phase != .listed)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityIdentifier("project-folder-use")
        }
        .task { await browser.start() }
    }

    private func name(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "/" : last
    }

    private func row(icon: String, title: String, tint: Color, chevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Color.hqLabel2).frame(width: HQFont.scaled(24))
                Text(title).foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if chevron {
                    Image(systemName: "chevron.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
                }
            }
            .frame(height: HQFont.scaled(44))
            .contentShape(Rectangle())
        }
        .listRowInsets(Self.rowInsets)
    }
}

/// The sheet's page: tells its presenter when it went away without a folder (✕, a swipe down), so New Project comes
/// back with what was typed.
final class ProjectFolderPickerHost: UIHostingController<ProjectFolderPickerView> {
    var closed: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard navigationController?.isBeingDismissed ?? isBeingDismissed else { return }
        let done = closed
        closed = nil
        done?()
    }
}
