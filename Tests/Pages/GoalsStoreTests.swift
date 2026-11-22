// [goals] TasksStore's goals (docs/goals.md, hermes-hq-push 0.9.65): read beside the list, added and changed at once
// and then as the gateway answers, a 409 sent again or given way to, a delete that leaves its tasks with no goal, and
// an older add-on that keeps none (nothing of Goals shows, and adding says why).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct GoalsStoreTests {
    private nonisolated static func task(_ id: String, goal: String? = nil, milestone: String? = nil, rev: Int = 2) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "rev": .number(Double(rev)), "title": .string(id), "who": "me", "status": "open",
                                      "created_at": "2026-11-02T08:00:00-06:00", "updated_at": "2026-11-02T08:00:00-06:00"]
        if let goal { o["goal"] = .string(goal) }
        if let milestone { o["milestone"] = .string(milestone) }
        return .object(o)
    }

    private nonisolated static func goal(_ id: String = "g_1", rev: Int = 3, title: String = "Run a 10K",
                                         milestones: [GoalMilestone] = [], measure: GoalMeasure? = nil) -> Goal {
        Goal(id: id, rev: rev, title: title, color: "orange", due: "2027-03-01", position: 10, measure: measure, milestones: milestones,
             createdAt: "2026-11-01T08:00:00-05:00", updatedAt: "2026-11-01T08:00:00-05:00")
    }

    private nonisolated static func wire(_ goal: Goal) -> JSONValue { try! JSONValue.parse(JSONEncoder().encode(goal)) }

    private nonisolated static func list(_ goals: [Goal]?, tasks: [JSONValue] = []) -> JSONValue {
        var o: [String: JSONValue] = ["rev": 4, "tasks": .array(tasks)]
        if let goals { o["goals"] = .array(goals.map(wire)) }
        return .object(o)
    }

    private nonisolated static func clash(_ goal: Goal) throws -> HTTPError {
        HTTPError(status: 409, body: String(decoding: try JSONValue.object(["detail": ["goal": wire(goal)]]).encoded(), as: UTF8.self))
    }

    private func store(_ client: PagesFakeClient) -> TasksStore {
        TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
    }

    private nonisolated static let milestones = [GoalMilestone(id: "ms_a", title: "Run 2 miles", done: true), GoalMilestone(id: "ms_b", title: "Run a 5K")]

    @Test func goalsAreReadBesideTheList() async {
        let client = PagesFakeClient { _ in Self.list([Self.goal()], tasks: [Self.task("t_1", goal: "g_1", milestone: "ms_b")]) }
        let s = store(client)
        await s.refresh()
        #expect(s.goalsSupported && s.goals.map(\.id) == ["g_1"])
        #expect(s.task("t_1")?.goal == "g_1")
        #expect(s.goal("g_1")?.title == "Run a 10K")
    }

    @Test func aNewGoalShowsAtOnceThenTakesTheGatewaysGoal() async throws {
        let client = PagesFakeClient { _ in Self.list([]) }
        let s = store(client)
        await s.refresh()
        let made = Self.goal("g_new", rev: 1, title: "1,000 public testers")
        client.respond { _ in
            try await Task.sleep(for: .milliseconds(80))
            return Self.wire(made)
        }
        let body = GoalWire.newGoal(title: "1,000 public testers", why: "A crowd at launch", due: "2027-01-31",
                                    measure: GoalMeasure(unit: "testers", start: 0, target: 1000))
        let adding = Task { await s.addGoal(body) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(s.goals.count == 1 && s.goals.first?.title == "1,000 public testers" && TodoIDs.isLocal(s.goals[0].id), "shown at once")
        #expect(s.goals.first?.measure?.target == 1000 && s.goals.first?.color != nil)
        let answer = await adding.value
        #expect(answer?.id == "g_new")
        #expect(s.goals.map(\.id) == ["g_new"], "the stand-in is gone")
        let sent = try #require(client.log.last)
        #expect(sent.method == "POST" && sent.path == "/api/plugins/hermes-hq-push/goals")
        #expect(sent.body?["title"]?.string == "1,000 public testers" && sent.body?["due"]?.string == "2027-01-31")
        #expect(sent.body?["measure"]?["target"]?.double == 1000 && sent.body?["why"]?.string == "A crowd at launch")
    }

    @Test func aFailedAddGoesBackAndSaysWhy() async {
        let client = PagesFakeClient { _ in Self.list([]) }
        let s = store(client)
        await s.refresh()
        client.respond { _ in throw httpError(500, "boom") }
        #expect(await s.addGoal(GoalWire.newGoal(title: "x")) == nil)
        #expect(s.goals.isEmpty && s.addGoalFailure != nil)
    }

    @Test func aChangeShowsAtOnceAndKeepsTheGatewaysAnswer() async throws {
        let client = PagesFakeClient { _ in Self.list([Self.goal(measure: GoalMeasure(unit: "km", start: 0, target: 10, now: 3))]) }
        let s = store(client)
        await s.refresh()
        var answer = Self.goal(rev: 4, measure: GoalMeasure(unit: "km", start: 0, target: 10, now: 5, at: "2026-11-18T08:00:00-06:00"))
        answer.updatedAt = "2026-11-18T08:00:00-06:00"
        let theirs = answer
        client.respond { _ in
            try await Task.sleep(for: .milliseconds(60))
            return Self.wire(theirs)
        }
        let saving = Task { await s.patchGoal("g_1", ["measure_now": 5]) }
        try await Task.sleep(for: .milliseconds(15))
        #expect(s.goal("g_1")?.measure?.now == 5, "the ring moves at once")
        #expect(await saving.value)
        #expect(s.goal("g_1")?.rev == 4)
        let sent = try #require(client.log.last)
        #expect(sent.method == "PATCH" && sent.path == "/api/plugins/hermes-hq-push/goals/g_1")
        #expect(ActivityJSON.int(sent.body?["rev"]) == 3 && sent.body?["measure_now"]?.double == 5)
    }

    @Test func aStaleRevIsSentAgainWhenNothingClashes() async throws {
        let base = Self.goal(milestones: Self.milestones)
        let client = PagesFakeClient { _ in Self.list([base]) }
        let s = store(client)
        await s.refresh()
        var renamed = base
        renamed.rev = 4
        renamed.title = "Run a 10K in spring"
        var finished = renamed
        finished.rev = 5
        finished.status = "paused"
        let current = renamed, done = finished
        client.respond { request in
            if ActivityJSON.int(request.body?["rev"]) == 3 { throw try Self.clash(current) }
            return Self.wire(done)
        }
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        #expect(await s.patchGoal("g_1", ["status": "paused"]))
        #expect(client.log.filter { $0.method == "PATCH" }.map { ActivityJSON.int($0.body?["rev"]) } == [3, 4])
        #expect(s.goal("g_1")?.title == "Run a 10K in spring" && s.goal("g_1")?.state == .paused && s.goal("g_1")?.rev == 5)
        #expect(notices.isEmpty)
    }

    @Test func aClashReReadsTheGoalAndShowsTheirs() async throws {
        let base = Self.goal()
        let client = PagesFakeClient { _ in Self.list([base]) }
        let s = store(client)
        await s.refresh()
        var theirs = base
        theirs.rev = 4
        theirs.title = "Run a half marathon"
        let current = theirs
        client.respond { _ in throw try Self.clash(current) }
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        #expect(await s.patchGoal("g_1", ["title": "Run a 10K by spring"]) == false)
        #expect(client.log.filter { $0.method == "PATCH" }.count == 1)
        #expect(s.goal("g_1")?.title == "Run a half marathon" && s.goal("g_1")?.rev == 4)
        #expect(notices == ["This goal changed somewhere else. Showing the latest."])
    }

    @Test func takingOutAMilestoneTakesItsTasksToNoMilestone() async {
        let client = PagesFakeClient { _ in
            Self.list([Self.goal(milestones: Self.milestones)], tasks: [Self.task("t_1", goal: "g_1", milestone: "ms_b"),
                                                                        Self.task("t_2", goal: "g_1", milestone: "ms_a")])
        }
        let s = store(client)
        await s.refresh()
        let kept = Self.goal(rev: 4, milestones: [Self.milestones[0]])
        client.respond { _ in Self.wire(kept) }
        #expect(await s.patchGoal("g_1", ["milestones": GoalWire.milestones([Self.milestones[0]])]))
        #expect(s.task("t_1")?.goal == "g_1" && s.task("t_1")?.milestone == nil, "still in the goal, under no milestone")
        #expect(s.task("t_2")?.milestone == "ms_a")
    }

    @Test func deletingAGoalLeavesItsTasksWithNoGoal() async throws {
        let client = PagesFakeClient { _ in
            Self.list([Self.goal(milestones: Self.milestones), Self.goal("g_2", title: "Other")],
                      tasks: [Self.task("t_1", goal: "g_1", milestone: "ms_b"), Self.task("t_2", goal: "g_2")])
        }
        let s = store(client)
        await s.refresh()
        client.respond { _ in ["ok": true] }
        #expect(await s.deleteGoal("g_1"))
        #expect(s.goals.map(\.id) == ["g_2"])
        #expect(s.tasks.count == 2, "its tasks stay")
        #expect(s.task("t_1")?.goal == nil && s.task("t_1")?.milestone == nil)
        #expect(s.task("t_2")?.goal == "g_2")
        let sent = try #require(client.log.last)
        #expect(sent.method == "DELETE" && sent.path == "/api/plugins/hermes-hq-push/goals/g_1")

        // A failed delete puts it all back.
        client.respond { _ in throw httpError(500, "boom") }
        #expect(await s.deleteGoal("g_2") == false)
        #expect(s.goals.map(\.id) == ["g_2"] && s.task("t_2")?.goal == "g_2")
    }

    @Test func movingATaskToAnotherGoalClearsItsMilestone() async throws {
        let client = PagesFakeClient { _ in
            Self.list([Self.goal(milestones: Self.milestones), Self.goal("g_2", title: "Other")],
                      tasks: [Self.task("t_1", goal: "g_1", milestone: "ms_b")])
        }
        let s = store(client)
        await s.refresh()
        client.respond { request in
            var o: [String: JSONValue] = ["id": "t_1", "rev": 3, "title": "t_1", "who": "me", "status": "open"]
            o["goal"] = request.body?["goal"] ?? .null
            o["milestone"] = request.body?["milestone"] ?? .null
            return .object(o)
        }
        #expect(await s.setGoal("t_1", goal: "g_2"))
        let sent = try #require(client.log.last)
        #expect(sent.body?["goal"]?.string == "g_2" && sent.body?["milestone"] == .null)
        #expect(s.task("t_1")?.goal == "g_2" && s.task("t_1")?.milestone == nil)
        // A plain PATCH that moves the goal and says nothing of the milestone sends the clearing too.
        #expect(await s.patch("t_1", ["goal": .null]))
        #expect(client.log.last?.body?["milestone"] == .null)
    }

    @Test func anOlderAddOnKeepsNoGoals() async {
        let client = PagesFakeClient { _ in Self.list(nil, tasks: [Self.task("t_1")]) }
        let s = store(client)
        await s.refresh()
        #expect(!s.goalsSupported && s.goals.isEmpty)
        #expect(s.goalsNeedAddOn, "[goals-addon] Tasks read, no goals: the Goals pill stays and offers the update")
        var notices: [String] = []
        s.onNotice = { notices.append($0) }
        #expect(await s.addGoal(GoalWire.newGoal(title: "Run a 10K")) == nil)
        #expect(s.addGoalFailure == "Goals need the newest HQ add-on on your computer (0.9.74 or later).")
        #expect(client.log.allSatisfy { $0.method == "GET" }, "nothing sent to an add-on that can't keep it")
        #expect(notices.count == 1)

        // The add-on is updated: goals arrive with the next read.
        client.respond { _ in Self.list([]) }
        await s.refresh(force: true)
        #expect(s.goalsSupported && s.goals.isEmpty && !s.goalsNeedAddOn)
        // …and an older add-on again (rolled back) takes them away.
        client.respond { _ in Self.list(nil) }
        await s.refresh(force: true)
        #expect(!s.goalsSupported && s.goalsNeedAddOn)
    }

    @Test func noGoalsUpdateOfferBeforeTheListIsRead() {
        let s = store(PagesFakeClient { _ in Self.list(nil) })
        #expect(!s.goalsNeedAddOn, "[goals-addon] nothing read yet: no Goals pill, no update offer on a guess")
    }
}
