// [project-default-bot] Owner 2026-11-17 (a screenshot of New Chat inside a project, one bot under "In OpenClaw App"):
// "a project should be able to have a default bot and an easier way to start a new session once you are inside the
// project." A project's New Chat (the bar's Compose on its page) starts the chat with the project's default bot at
// once, with no sheet. The default is the bot chosen for the project (the page's ⋯ › Default Bot, or a hold on a bot
// in the chooser); with nothing chosen, the project's only bot. Ask Every Time, or a project several bots share with
// none chosen, keeps the chooser.

import Foundation

nonisolated enum ProjectDefaultBot {
    /// The stored word for Ask Every Time (a bot's profile is never this: `NewChatKeyBot.ask` is the same word).
    static let ask = "ask"

    /// The bot a project's New Chat starts with; nil asks.
    /// `stored`: what was chosen for the project (a profile, `ask`, or nil: nothing chosen).
    /// `own`: the bots that have the project and are offered (hidden ones left out), `bots`: every bot of the gateway.
    static func resolve(stored: String?, own: [String], bots: [String]) -> String? {
        if stored == ask { return nil }
        if let stored, bots.contains(stored) { return stored }
        // Nothing chosen, or the chosen bot is gone: a project with one bot has nothing to ask.
        return own.count == 1 ? own[0] : nil
    }
}
