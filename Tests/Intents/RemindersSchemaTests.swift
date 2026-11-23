// [reminders-schema] Messages' "Add to Reminders" (and Siri's, and Shortcuts') reminder, as a task of your own
// (DECISION I23).

import AppIntents
import Foundation
import Testing
@testable import HermesHQNative

@Suite struct RemindersSchemaTests {
    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    @Test func aRemindersWordsBecomeATaskOfYourOwn() throws {
        let body = try JSONValue.parse(JSONValue.object(ReminderTaskBody.make(
            title: "  Get the agreement signed  ", note: "Sam still has to review it", flagged: true,
            tags: ["legal", " "], urls: [URL(string: "https://example.com/agreement")!],
            due: DateComponents(year: 2026, month: 11, day: 25), repeatRule: nil, calendar: chicago)).encoded())
        #expect(body["title"]?.string == "Get the agreement signed")
        #expect(body["who"]?.string == "me")
        #expect(body["bot"] == .null)
        #expect(body["notes"]?.string == "Sam still has to review it\nhttps://example.com/agreement")
        #expect(body["due"]?.string == "2026-11-25")
        #expect(body["priority"]?.double == 1)
        #expect(body["tags"] == .array([.string("legal")]))
        #expect(body["source"]?["kind"]?.string == "app")
        #expect(body["prep"]?.bool == false)
    }

    @Test func aBareReminderSendsNoExtras() throws {
        let body = try JSONValue.parse(JSONValue.object(ReminderTaskBody.make(
            title: "Call back", note: nil, flagged: nil, tags: [], urls: [], due: nil, repeatRule: nil)).encoded())
        #expect(body["notes"]?.string == "")
        #expect(body["due"] == .null)
        #expect(body["priority"] == nil, "an older add-on never sees the key")
        #expect(body["tags"] == nil)
        #expect(body["repeat"] == .null)
    }

    @Test func aPlaceStaysInWordsAndAListIsKeptById() throws {
        let arrive = try JSONValue.parse(JSONValue.object(ReminderTaskBody.make(
            title: "Pick up milk", note: "2%", flagged: nil, tags: [], urls: [], due: nil, repeatRule: nil,
            place: " Costco ", arriving: true, section: "s-groceries")).encoded())
        #expect(arrive["notes"]?.string == "2%\nWhen arriving at Costco")
        #expect(arrive["section"]?.string == "s-groceries")
        let leave = try JSONValue.parse(JSONValue.object(ReminderTaskBody.make(
            title: "Lock up", note: nil, flagged: nil, tags: [], urls: [], due: nil, repeatRule: nil,
            place: "the office", arriving: false, section: "")).encoded())
        #expect(leave["notes"]?.string == "When leaving the office")
        #expect(leave["section"] == nil)
    }

    @Test func aDueTimeKeepsItsHourAndZone() {
        let moment = ReminderTaskBody.due(DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 0), calendar: chicago)
        #expect(moment == "2026-11-25T17:00:00-06:00")
        var zoned = DateComponents(year: 2026, month: 11, day: 25, hour: 9)
        zoned.timeZone = TimeZone(identifier: "America/New_York")
        #expect(ReminderTaskBody.due(zoned, calendar: chicago) == "2026-11-25T09:00:00-05:00")
        #expect(ReminderTaskBody.due(DateComponents(), calendar: chicago) == nil)
        #expect(ReminderTaskBody.due(nil, calendar: chicago) == nil)
    }

    @Test func aWeekdayWithoutADateIsTheNextOne() throws {
        let raw = try #require(ReminderTaskBody.due(DateComponents(weekday: 4), calendar: chicago))   // Wednesday
        let day = try #require(TodoDates.day(raw, calendar: chicago))
        #expect(raw.count == 10, "no hour: a day")
        #expect(chicago.component(.weekday, from: day) == 4)
        #expect(day > Date().addingTimeInterval(-86_400) && day < Date().addingTimeInterval(8 * 86_400))
    }

    @Test func aTasksDueReadsBackAsComponents() {
        #expect(ReminderTaskBody.components("2026-11-25", calendar: chicago) == DateComponents(year: 2026, month: 11, day: 25))
        #expect(ReminderTaskBody.components("2026-11-25T17:30:00-06:00", calendar: chicago)
                == DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 30))
        #expect(ReminderTaskBody.components(nil, calendar: chicago) == nil)
    }

    @Test func onlyRepeatsTheListKeepsCarryOver() {
        #expect(ReminderTaskBody.repeatRule("daily", interval: 1, weekdays: []) == "daily")
        #expect(ReminderTaskBody.repeatRule("weekly", interval: 1, weekdays: [2, 3, 4, 5, 6]) == "weekdays")
        #expect(ReminderTaskBody.repeatRule("weekly", interval: 1, weekdays: [2]) == "weekly")
        #expect(ReminderTaskBody.repeatRule("monthly", interval: 1, weekdays: []) == "monthly")
        #expect(ReminderTaskBody.repeatRule("yearly", interval: 1, weekdays: []) == "yearly")
        #expect(ReminderTaskBody.repeatRule("weekly", interval: 2, weekdays: []) == nil, "every other week: no such repeat")
        #expect(ReminderTaskBody.repeatRule("hourly", interval: 1, weekdays: []) == nil)
    }

    @Test func calendarRecurrenceMapsToTheListsRepeat() {
        guard #available(iOS 27.0, *) else { return }
        #expect(CreateHQReminderIntent.repeatRule(nil) == nil)
        #expect(CreateHQReminderIntent.repeatRule(.daily(calendar: chicago)) == "daily")
        #expect(CreateHQReminderIntent.repeatRule(.weekly(calendar: chicago, weekdays: [.every(.monday), .every(.tuesday),
            .every(.wednesday), .every(.thursday), .every(.friday)])) == "weekdays")
        #expect(CreateHQReminderIntent.repeatRule(.monthly(calendar: chicago)) == "monthly")
        #expect(CreateHQReminderIntent.repeatRule(.weekly(calendar: chicago, interval: 2)) == nil)
        #expect(CreateHQReminderIntent.repeatRule(.daily(calendar: chicago, end: .afterOccurrences(3))) == nil,
                "a repeat that ends: the list can't keep the end")
    }

    @Test func aTaskReadsAsAReminder() throws {
        guard #available(iOS 27.0, *) else { return }
        let json = #"{"id":"t1","rev":3,"title":"Sign it","notes":"before Wednesday","who":"me","status":"done","due":"2026-11-25","priority":1,"tags":["legal"],"created_at":"2026-11-23T13:00:00Z","done_at":"2026-11-24T15:00:00Z"}"#
        let task = try JSONDecoder().decode(TodoTask.self, from: Data(json.utf8))
        let reminder = HQReminder(task)
        #expect(reminder.id == "t1" && reminder.title == "Sign it")
        #expect(reminder.note.map { String($0.characters) } == "before Wednesday")
        #expect(reminder.isCompleted && reminder.isFlagged == true)
        #expect(reminder.tags == ["legal"])
        #expect(reminder.dueDate?.day == 25)
        #expect(reminder.creationDate != nil && reminder.completionDate != nil)
        #expect(reminder.list.id == HQReminderList.tasks.id)
    }
}
