// [tile-widgets] Where a widget's tap takes the app: `<scheme>://widget/<what>`, handled by App/Widgets/WidgetRouter.swift
// before the app's other links (SceneDelegate.open).
//   widget/tile?id=<tile key>&account=<account key>   that tile, opened as a tap on it in Tiles opens it
//   widget/tiles                                      the Tiles page
//   widget/tasks                                      the Tasks page
//   widget/task?id=<task id>&account=<account key>    that task's sheet
//   widget/new-task                                   the New Task sheet
//   widget/open                                       the app, as it was

import Foundation

nonisolated enum WidgetLink: Equatable, Sendable {
    case tile(key: String, account: String)
    case tiles
    case tasks
    case task(id: String, account: String)
    case newTask
    case open

    /// A key or an id as a link carries it: letters, digits, `-`, `_` and `.`, at most 160.
    static func valid(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: "^[A-Za-z0-9_.-]{1,160}$", options: .regularExpression) != nil
    }

    func url(scheme: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "widget"
        switch self {
        case .tile(let key, let account):
            parts.path = "/tile"
            parts.queryItems = [URLQueryItem(name: "id", value: key), URLQueryItem(name: "account", value: account)]
        case .tiles: parts.path = "/tiles"
        case .tasks: parts.path = "/tasks"
        case .task(let id, let account):
            parts.path = "/task"
            parts.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "account", value: account)]
        case .newTask: parts.path = "/new-task"
        case .open: parts.path = "/open"
        }
        return parts.url
    }

    /// What a `widget` link asks for; nil: not one of ours (another scheme, another host, a bad id).
    static func parse(_ url: URL, scheme: String) -> WidgetLink? {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host?.lowercased() == "widget",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func item(_ name: String) -> String? { parts.queryItems?.first { $0.name == name }?.value }
        switch action {
        case "tile":
            guard valid(item("id")), valid(item("account")) else { return nil }
            return .tile(key: item("id")!, account: item("account")!)
        case "tiles": return .tiles
        case "tasks": return .tasks
        case "task":
            guard valid(item("id")), valid(item("account")) else { return nil }
            return .task(id: item("id")!, account: item("account")!)
        case "new-task": return .newTask
        case "open": return .open
        default: return nil
        }
    }
}
