// [project-default-bot] The bot a project's New Chat starts with.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ProjectDefaultBotTests {
    private let bots = ["default", "research", "deploys"]

    @Test func theChosenBotStartsTheChat() {
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default"], bots: bots) == "research")
        #expect(ProjectDefaultBot.resolve(stored: "research", own: ["default", "deploys"], bots: bots) == "research")
    }

    @Test func askEveryTimeAsksEvenWithOneBot() {
        #expect(ProjectDefaultBot.resolve(stored: ProjectDefaultBot.ask, own: ["default"], bots: bots) == nil)
    }

    @Test func nothingChosenUsesTheProjectsOnlyBot() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["research"], bots: bots) == "research")
    }

    @Test func nothingChosenAsksWhenSeveralBotsShareTheProjectOrNoneHasIt() {
        #expect(ProjectDefaultBot.resolve(stored: nil, own: ["default", "research"], bots: bots) == nil)
        #expect(ProjectDefaultBot.resolve(stored: nil, own: [], bots: bots) == nil)
    }

    @Test func aChosenBotThatIsGoneFallsBack() {
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default"], bots: bots) == "default")
        #expect(ProjectDefaultBot.resolve(stored: "gone", own: ["default", "research"], bots: bots) == nil)
    }
}
