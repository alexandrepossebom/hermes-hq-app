# Goals (what your tasks are for)

Owner idea 2026-11-18: "On top of the tasks section, what if we had an area for goals. So I can organize things that I
want to achieve over time, and structure it in a way where whatever bots I add to it can work to help me achieve that
goal." He approved five boards and the build order below ("Go!").

Goals is part of Tasks (docs/tasks.md). The hermes-hq-push add-on keeps goals beside the list (`tasks.py`, tasks.db);
the app draws them. **Never touch Hermes's Kanban.**

## The rules behind every screen
1. **A goal** is a finish line, an optional date, a one-line why, milestones, and ordinary tasks under them.
2. **Take every bot away and it still works** (the Tasks rule). Steps 1 and 2 below have no bot in them at all.
3. **The ring never lies.** Progress is your number when the goal has one, else milestones done, else tasks done. A
   goal with none of those has an empty ring and says "No plan yet".
4. **Pace is said in words**, only when the goal has a date: on pace, ahead, a week behind. Red only once it is late.
5. **Nothing finishes by itself.** Ticking a milestone's last task offers to tick the milestone; ticking the last
   milestone offers Mark Achieved. Each is a question, never automatic.
6. **Pause and Let Go are real answers.** Both keep the goal (under Someday, and under Let Go).
7. **A task has at most one goal** (and one list). Lists and goals both stay: a list is an area that never ends, a
   goal ends.

## Build order (each one ships by itself)
1. **Goals with no bots** (this document's "Step 1"; hermes-hq-push 0.9.65).
2. The shelf on Today, the goal's mark on task rows everywhere, search.
3. A bot on a goal: a lead and helpers, the goal's own chat, the plan as an offer, bot tools.
4. The weekly check-in, a number a bot checks, where it stands, the stall question.
5. The Goal Page and the Mac's layout.

Steps 3 to 5 are hermes-hq-push 0.9.66 (the add-on's half is built; its report is the wire contract below). Everything
of them shows only when the add-on says so: `goal_bots: true` in `GET /tasks` (`TasksStore.goalBotsSupported`) and
`goal_pages: true` in `/status` (`TasksStore.goalPagesSupported`). With 0.9.65 (goals, no bots) the app is exactly
steps 1 and 2; with no goals at all, exactly Tasks.

## Data (JSON, as the routes send it)
```
Goal {
  id: str (uuid4 hex), rev: int (bumps on every change), title: str (200), why: str (300),
  status: "active" | "paused" | "achieved" | "let_go", status_at: ISO,
  color: "blue"|"green"|"orange"|"red"|"purple"|"pink"|"teal"|"yellow"|"gray",   # a list's colours
  due: "2027-01-31" | null (a day), position: number (smallest first; starts as the time it was added),
  measure: null | { unit: str (20, "testers", "lbs", "$"; may be ""), start: number, target: number, now: number,
                    at: ISO (when `now` last changed), source: "you",
                    history: [ {at: ISO, value: number} ] }   # every change of `now`, newest last, 60 at most
  milestones: [ {id, title (120), due: day | null, done: bool, done_at: ISO | null} ]   # in order, 30 at most
  created_at, updated_at: ISO,
  log: [ {at, by: "you", text} ]   # newest last, capped at 50
}
Task gains:  goal: <goal id> | null,  milestone: <milestone id> | null
```
**0.9.66 (steps 3 to 5) a Goal also carries** (the add-on's exact shapes):
```
lead: str | null                 helpers: [str] (≤5, never lead)       adds: "ask" | "auto"
review: {day: 0-6 (0 = Monday), time: "HH:MM"} | null     # the weekly check-in; Monday 08:00 when a lead is first
                                                          # given and none was set; null turns it off
known_to_all: bool (default true)
stands: {by, at, text (400), next (200)} | null           # the lead's "where it stands"
checkin: {at: ISO, offer: <offer id> | null, state: "offered" | "accepted" | "declined" | "none"} | null
chat: {profile, session_id} | {}  # the goal's own chat (hidden, title "Goal: <title> · <id prefix>")
page_at: "" | ISO                 # "" until its lead writes on its Goal Page
kept_at: ISO | null               # the stall question was answered "Keep Going"
offer: null | {kind: "done", what: <milestone id> | "goal", by: <profile>, text: str (160), at: ISO,
               kept?: true, kept_at?: ISO}                # the lead's "this looks done"
measure.source: "you" | {bot: <profile>, what: str (80)}    measure.checked_at: ISO | null
```
- Removing the lead (`lead: null`) keeps the helpers; the check-in stops until a lead is set.
- `checkin.state "none"`: the lead was handed the goal at its weekly look and no card is offered yet.
- `offer` (looks done) is shown only while it is set and not `kept`; it clears by itself when that milestone is ticked
  or removed, or the goal is no longer active.

**Goal offers** ride in `GET /tasks` `offers[]` beside list offers (a list offer has no `kind`, read as "list"):
```
{id, kind: "goal"|"plan"|"checkin"|"tasks", bot, session_id, at, goal: <id>|null (null only for "goal"), title,
 tasks: [{title, who: "me"|"bot", bot?, due?, notes?, milestone?}],   # 20 at most
 state: "new"|"accepted"|"declined"|"undone", answered_at?, held?: true,
 why, due, measure: {unit, start, target}|null, milestones: [{title, due?}]   # kind "goal"
 milestones: [{title, due?}]                                                   # kind "plan"
 summary                                                                       # kind "checkin" (what moved)
 added: [task ids], made_goal?: <goal id>, made_milestones?: [ids], plan?: bool, in_goal?: bool, kept?: [ids],
 list: <title>, section: null, new: false, move: []}   # the last four so a pre-0.9.66 app can decode it
```
- `tasks[].milestone` is the goal's milestone id when it matched one; on a goal or plan offer it may be one of the
  offer's own milestone titles (accepting turns it into the new milestone's id). `tasks[].due` is already resolved.
- Held offers (`held: true`: from a bot that is neither lead nor helper, or a run with no person in the chat) are never
  in `offers`; they go to the lead's next check-in. The app shows every offer it is sent.
- `kept` (after undo): what undo left in place because you had changed it since.
- A task's `milestone` must be one of its goal's; otherwise it is cleared. Clearing `goal` clears `milestone`.
- Deleting a goal keeps its tasks (their `goal` and `milestone` are cleared). Removing a milestone keeps its tasks in
  the goal with no milestone.

## Routes (hermes-hq-push dashboard plugin_api, same sign-in as /tasks)
- `GET /tasks` gains `goals: [Goal…]` (every goal, any status, by `position`). The key being there says the add-on
  keeps goals; an older add-on leaves it out. Goals share the list's `rev`, so `?since=` hears of a goal's change.
- `POST /goals` `{title, why?, due?, color?, measure?: {unit, start, target, now?}, milestones?: [{title, due?}]}`
  (Set-up: also `lead?, helpers?, adds?, review?`, one write and one "Added")
  returns the Goal. `color` left out takes the first colour no active goal uses.
- `PATCH /goals/{id}` `{rev, …changed fields}` returns the Goal. A stale rev is 409 `{goal: <current>}`.
  - `title`, `why`, `color`, `position`, `due` (null clears it), `status`.
  - `measure`: null removes it; an object replaces unit, start and target, and moves `now` when it is sent (the
    server stamps `at` and adds to `history`). `measure_now: number` alone is "Update".
  - `milestones`: the whole list in order. One with a known id keeps its `done_at`; one without an id gets one; one
    left out is removed.
- `DELETE /goals/{id}` returns `{ok: true}`.
- `POST /tasks`, `PATCH /tasks/{id}` take `goal` and `milestone` (ids; null clears). An unknown goal is a 400.
- `/status` gains `task_goals: true`.

**0.9.66** (steps 3 to 5):
- `GET /tasks` gains `goal_bots: true`; goal offers ride in `offers`.
- `PATCH /goals/{id}` also takes `lead: <profile> | null` (an invalid name is a 422; a lead set for the first time with
  no review gets Monday 08:00; null keeps the helpers), `helpers: [str]`, `adds: "ask" | "auto"`, `review: {day, time}
  | null` (out of range is a 422), `known_to_all: bool`, `chat: {profile, session_id}`, `keep: true` (stamps
  `kept_at`, logs "Kept going": the stall question's Keep Going), `offer_answer: "done" | "keep"` (done ticks the
  offered milestone or marks the goal achieved and clears `offer`; keep marks it `kept`; ignored with no unkept offer),
  and in `measure` a `source` (`"you"` or `{bot, what}`; `measure: {source}` alone changes only the source and clears
  `checked_at`; a bad one is a 400).
- `POST /tasks/offers/{id}` `{action: "accept" | "decline" | "undo", list?, plan?: bool = true, in_goal?: bool = true}`:
  - accept on `goal` makes the goal led by the offering bot (review Monday 08:00); `plan: false` ("Keep the Goal, No
    Plan") makes it with no milestones or tasks. On `plan` it adds the milestones and tasks; `plan: false` on a plan is
    a **decline** (the answer's `offer.state` is "declined"). On `checkin` / `tasks` it adds the tasks under the goal;
    `in_goal: false` ("Just Tasks") adds them with no goal.
  - decline changes nothing (a declined `goal` of that name isn't offered again; a declined `checkin` not until next
    week's slot; a declined `plan` only when you ask). undo (accepted only) takes back the tasks, the milestones and a
    goal it made, except what you have changed since.
  - On a goal offer move and leave are a 400. Answer: `{rev, offer, sections, goals}` (list offers carry `goals` too);
    404 unknown, 409 already answered.
- `/status` gains `goal_bots: true`, `goal_pages: true`.
- `GET /goals/{id}/page?names={"default":"Hermes",…}`: the Goal Page as HTML (`Cache-Control: no-store`), 404 `{detail:
  "No such goal."}`. The bot writes words, never HTML; the page's words never go into logs.
- Tasks settings gain `goals: bool` (default true). Off removes the bots' tools, notes and check-in jobs; goals stay.
- The push for a check-in: `kind "task"`, `about "checkin"`, `request "goal:<goal id>"`, title the bot, body "Check-in
  for <goal>" (never at night). A push whose `request` starts with `goal:` opens that goal.

## Step 1: Goals with no bots
Boards 1 (right phone) and 2. The pictures are in the owner's share folder, not in this repo.

### The Goals view (`GoalViews`, `GoalsListViews`)
- **Goals is the first pill** in Tasks' views row, with the count of active goals. The page still opens on Today.
  With an add-on that keeps no goals the pill is not there.
- **Active** goals come first, in your order (drag). Each is a card: the ring, the name, one grey line ("340 of 1,000
  · by Jan 31", "1 of 4 milestones · by Apr 11", "4 of 6 tasks", "No plan yet") with the pace after it when the goal
  has a date, and under a hairline the goal's next task (the first open task under it: its current milestone's first,
  else the first with no milestone), with its circle. A tap on the circle ticks that task, as on a task's row.
- **Someday** (paused), **Achieved** and **Let Go** are groups under it, each shown only when it has a goal. Someday's
  cards are quieter. Achieved and Let Go are folded to a heading with the count; a tap opens them.
- **+ New Goal** is the last row, and the bar's + makes a goal while this view is on show.
- With no goals at all the view says what a goal is in two lines, with New Goal.
- Hold a card: Edit Goal…, Pause / Resume, Mark Achieved, Let It Go, Delete Goal… (asks first; its tasks are kept).
- Cards are `GoalCard` (`GoalCardModel`), drawn in `TasksViewController`'s list under the views row; the data is
  `Goal`, `GoalMilestone`, `GoalMeasure`, `GoalState` (HermesKit `GoalModel`), kept by `TasksStore` (`goals`,
  `goalsSupported`, `addGoal`, `patchGoal`, `deleteGoal`, `setGoal`) over `GoalsAPI`. Guards: `GoalsStoreTests`,
  `PagesTests.testTasks_Goals`, `PagesTests.testTasks_GoalsNeedTheAddOn` (UITests/pages/TasksGoalsUITests.swift).

### A goal's page (`GoalPage`, `GoalPlainView`)
Built from a task's page's rows (`TaskPlainView`), top to bottom:
- The bar: back, a "Goal" capsule with the goal's mark, ⋯ (the hold menu's rows).
- The title, led by the ring. A tap writes.
- **The number row**, only with a measure: "340 of 1,000 testers" with **Update** at its end (a small sheet with one
  number field). The row's menu edits unit, start and target, or removes the number.
- **The date row**: "By Sun, Jan 31" with what is left at its end ("48 days left", "17 weeks left", "3 days late").
- **The why row**. A tap writes.
- **The bar**, in the goal's colour, with a tick where an even pace would be today (only with a date). Under it one
  line: "25% · an even pace would be 35% today", or "1 of 4 milestones · on pace".
- **Quiet words** for what is not set, one line: + Number, + Date, + Why.
- **Milestones n of m** with + at the heading's end. Each is one line with a square box (a task's is round): its name
  and, at the end, its date and "1 of 4". The first one not done is **open**, with its tasks under it (indented, a
  task's ordinary rows: tick, open, hold). Done and later ones are one line; a tap opens or closes one. A tick on the
  box marks it done. Hold a milestone: Rename…, Set Date…, Move Up / Down, Delete Milestone… (its tasks are kept).
  "Add a task" is the last row under an open milestone.
- **No Milestone n**: the goal's tasks with no milestone, then "Add a task". When the goal has no milestones the
  heading is plain **Tasks n of m**.
- **Offers** (rule 5), as one soft card under the bar: "That was the last task in Launch week. Mark it done?" with
  Mark Done / Not Yet; "Every milestone is done. Mark this goal achieved?" with Mark Achieved / Not Yet. Not Yet is
  remembered on this device for that milestone or goal until something under it changes.
- An achieved goal says "Achieved Dec 20" under its title; a let-go one "Let go Dec 20"; a paused one "Paused Nov 30"
  with Resume.
- `GoalPageModel` + `GoalPageHost` (the bar, ⋯ = `GoalMenu`), `GoalRing`, `GoalProgressBar`, `GoalNotYet` (Not Yet
  on this device). Update is `GoalUpdateSheet`; the number's menu opens `GoalNumberSheet`. Pictures:
  `PagesTests.testTasks_GoalsShots` (UITests/pages/TasksGoalsShots.swift).

### Progress and pace (`GoalViews`, pure functions with unit tests)
- **Fraction:** a measure: `(now - start) / (target - start)`, held to 0…1 (a target below the start counts down).
  Else milestones done / milestones. Else tasks done / tasks under the goal. Else nil ("No plan yet").
- **Even pace today:** `(today - created day) / (due day - created day)`, held to 0…1; nil with no date.
- **Words:** within 5 points of even: "on pace". Behind: the gap in days at the even rate, said as "N days behind"
  under a week, "a week behind", "N weeks behind". Ahead: "ahead". Past its date and not achieved: "N days late"
  (red). An achieved or paused goal says no pace.
- **Next task:** the first open task of the first milestone not done, in the tasks' own `position` order; else the
  first open task with no milestone; else none.
- Guards: `GoalViewsTests` (fraction, count-down, even pace, every pace word, late, next task, groups, offers, a
  task's milestone cleared when its goal changes, decoding with and without `goals`).

### A task in a goal
- A task's page gains a **goal row** under who: the goal's mark, its name, and at the end its milestone with ›. Its
  menu: each active goal (then that goal's milestones), No Goal, and Open Goal. With no goal, "+ Goal" waits with
  the quiet words (only once you have a goal).
- Hold a task's row › **Add to Goal** (the same menu) beside Move To.
- A task added on a goal's page starts in that goal (and the milestone it was added under). It is an ordinary task:
  it shows in Today, Upcoming, Inbox or its list as any task does.
- A paused goal's tasks stay out of Today's "Next in <List>" groups; a dated one still shows on its day.
- The goal row is `TaskPlainView.goalRow`; its menu and Add to Goal are `GoalChoices` (App/Pages/Goals/GoalShared.swift).
  The fixture keeps goals with `--task-goals` (scripts/pages-fixture-gateway.py). Guard: `PagesTests.testTasks_NewGoal`.

### New Goal and Edit Goal
- **New Goal** is the quick-add sheet (`NewTodoSheet`'s shape): one line for the goal, a line for why, and one row
  of buttons: the date (read from the words by `TodoQuickParse`: "by Jan 31"), **Number** (unit, from, to) and Add.
  It closes on Add and opens the new goal's page.
- **Edit Goal…**: name, colour, and Pause Goal / Delete Goal…. Each change saves as you make it.
- `NewGoalSheet` (`NewGoalModel`, `NewGoalView`) and `GoalEditSheet` (`GoalEditModel`, `GoalEditView`).

### Not in step 1
The shelf on Today and the goal's mark on rows (step 2); anything with a bot (steps 3 to 5): a lead, a plan offer, a
check-in, a number a bot reads, the stall question, the Goal Page; the Mac's own layout (the Mac shows these same
views in the Tasks pane).

## Step 2: the shelf on Today, the goal's mark, search
Board 1, the left and middle phones. App only; the add-on is step 1's.

### The shelf (`GoalShelf`)
- **Today leads with a Goals shelf** when you have an active goal: the heading "Goals" with "All N ›" at its end
  (opens the Goals view), then one row of small cards that scrolls sideways. Each card: the ring, the name (one
  line), a grey line ("340 · by Jan 31", "1 of 4 · by Apr 11", "4 of 6 · Dec 27": `GoalViews.shortLine`), and under
  them "Next: <the goal's next task>" (or "No plan yet", or "Nothing next" when every task is done). A tap opens
  the goal. The cards are the active goals in your order; a paused, achieved or let-go goal has no card.
- **A tap on the heading "Goals" folds the shelf** to that one line (the heading then says how many: "Goals 3").
  Folded or not is kept on this device.
- The shelf is only on Today (not Upcoming, Inbox or a list), stays out of a search, and follows the bots filter the
  way Today's rows do only in that it stays when the filter is All Bots or Me; with one bot picked it is hidden.
- With no active goal, or an add-on that keeps no goals, there is no shelf and no heading.
- VoiceOver: a card is one element, read as the Goals view's card is; the shelf's heading is a button that says
  "Goals, 3, shown" / "hidden".
- At the accessibility text sizes the cards stack one under another (two at most, then "All N ›").
- Rules: HermesKit `GoalShelf` (`shows`, `cards`, `card`, `drawn`, `headingValue`), `GoalShelfCard`, `GoalShelfNext`,
  `GoalViews.shortLine`; drawn by `GoalShelfView` / `GoalShelfCardView` (App/Pages/Goals/GoalShelfViews.swift) in one
  cell (`Section.shelf`) at the top of `TasksViewController`'s Today; the fold is `GoalShelfFold`. Guards:
  `GoalShelfTests`, `PagesTests.testTasks_GoalsShelf`, `testTasks_GoalsShelfLargestText`
  (UITests/pages/TasksGoalsMoreUITests.swift).

### The goal's mark on a task's row (`GoalMark`)
- A task in an active or paused goal carries the **goal's mark** (the small target in the goal's colour) before its
  date, **in the place of its list's dot**, in Today, Upcoming, Inbox, a search and under Bots. Inside a list the row
  shows the mark too (the list's own dot is not drawn there, as now). On the goal's own page there is no mark.
- VoiceOver adds "for <goal>" to the row, as it says "in <list>".
- A task in an achieved or let-go goal shows its list's dot again.
- At the largest text sizes the mark is not drawn (as the list's dot isn't); the spoken words stay.
- Rule: `GoalViews.markGoal`; drawn by `TodoRowView` (`TodoRowModel.goalMark`, `goalName`), set in
  `TasksViewController.rowModel`. Guards: `GoalShelfTests.theMarkIsForAnActiveOrPausedGoal`,
  `PagesTests.testTasks_GoalMarks`, `testTasks_GoalMarksNeedGoals`.

### Search
- A search in Tasks finds **goals** by name and why: a "Goals" group first (the Goals view's cards, any status),
  then To Do and Done as now.
- A task is found by its goal's name ("launch" finds the tasks under "Launch week"'s goal) and by its milestone's
  name.
- Rules: `GoalViews.found`, `GoalViews.searchWords` (read by `TodoSections.filtered(_:scope:query:goals:)`); the group
  is `TasksViewController.appendFoundGoals` (`GoalGroupKey.found`). Guards: `GoalShelfTests`,
  `PagesTests.testTasks_GoalsSearch`.

### Loose ends from step 1, closed here
- **Update is a small sheet** over the keyboard, as tall as its content (the quick add's shape), not a half page.
- UI tests that drive what step 1 built and did not test: dragging a goal's card to reorder (the order survives a
  relaunch), Delete Goal… (its tasks are still in Tasks, with no goal row), Let It Go and Make Active Again, a
  milestone's Rename… / Set Date… / Move Up / Delete Milestone…, the number's menu (edit, remove), the empty Goals
  view, and the Goals view and a goal's page at the largest accessibility text size (nothing cut to nothing, nothing
  overlapping), and on an iPad.
- `testTasks_QuickAdd` fails on main at its second `typeText` (the keyboard goes down after the first Add). Find out
  whether that is the app (the sheet says it stays open with its line ready for the next task: docs/tasks.md step 4)
  or the test, and fix the one that is wrong. New Goal shares that sheet.
- Update: `GoalUpdateHost` / `GoalUpdateView` (App/Pages/Goals/GoalSheets.swift) on `QuickAddSheet`. Guards, in
  UITests/pages/TasksGoalsMoreUITests.swift: `testTasks_GoalUpdateSheet`, `testTasks_GoalsReorder`,
  `testTasks_GoalDelete`, `testTasks_GoalLetGoAndBack`, `testTasks_GoalMilestoneMenu`, `testTasks_GoalNumberMenu`,
  `testTasks_GoalsEmpty`, `testTasks_GoalsLargestText`, `testTasks_GoalsOnIPad`. The quick add's line takes the
  focus back after each Add (`NewTodoModel.addedCount`); guard: `testTasks_QuickAdd`.

### Not in step 2
Anything with a bot (steps 3 to 5).

## The rules every bot on a goal works under (the add-on enforces them; the app shows them)
1. **One lead per goal.** It plans, runs the check-in, writes where the goal stands and keeps its page.
2. **Helpers take tasks, not the plan.** Only the lead may offer a plan or a check-in.
3. **Every bot knows your active goals by name and why** (Tell My Other Bots, a switch per goal, on by default). Only the
   goal's lead and helpers read its tasks, milestones, number and page.
4. **Offers, not edits.** A bot may put its own task in a goal it leads or helps; anything for you, any milestone, any
   date, a new goal is an offer card you tap. New Tasks › Add Without Asking (`adds: "auto"`) lets its lead and
   helpers add a task for you without the card; nothing else loosens.
5. **A bot never ticks your task, a milestone, or the goal.** It may say "this looks done" (an offer).
6. **A bot never moves the number by guessing.** The number has one source, you or one bot and what it reads; the row
   always names it.
7. **Research and drafts only**: never send, book, buy, pay, post or delete for a goal.
8. **Off is off.** Tasks off, or Goals off in Tasks settings, removes the tools, the notes to bots and the check-in jobs.
   Goals themselves are kept.

## Step 3: a bot on a goal (boards 3 and 5; hermes-hq-push 0.9.66)
### Edit Goal (`GoalEditSheet`, `GoalTeamRows`)
- **Edit Goal** gains, only with `goal_bots`: **Led By** (a bot, or No One), **Helpers** (bots, not the lead; step 6 puts
  one **Bots** row, the team sheet, in place of these two), **Check-in**
  (Off, or a weekday and time), **New Tasks** (Ask First / Add Without Asking), **Number From** (You, or a bot and what it
  reads; only with a number), **Tell My Other Bots**. Under Led By: "The lead plans, checks in and keeps the goal's page.
  Helpers take tasks." Under Tell My Other Bots: "Other bots know this goal's name and why, so they can point things to
  it." Each change saves as you make it (`lead`, `helpers`, `review`, `adds`, `measure.source`, `known_to_all`).
- Words: `GoalBots.reviewWords` ("Mondays 8 AM", "Off"), `GoalBots.numberFromWords` ("TestFlight · Hermes", "You").

### New Goal with a bot (`NewGoalSheet`, `GoalChats`)
- **New Goal** gained a "Plan With <Bot>" button in its row: a menu of your bots and No One, off by default (step 6
  puts a Who's helping? row in its place, below). With a bot, Add makes the goal led by that bot, opens the goal's
  page with its chat, and sends the plan request as a hidden first turn (the goal's details for the bot,
  `GoalBots.planRequest`; your bubble shows nothing you didn't type), as New Task with a bot does.

### A goal with a lead (`GoalPage`, `GoalChatPage`, `GoalTeamViews`)
- **A goal with a lead is a goal's page with a teammate on it**, exactly as a task with a bot (docs/tasks.md step 2):
  - a **who row**: "Led by Hermes" with the faces of the lead and helpers, the check-in day at its end ("Mondays 8 AM");
  - the lead's **where it stands** card under the bar: its face and name, since when, "Page ›", its words, **Next:**;
  - a one-line **Message <Bot>** box at the foot (`TaskMessageLine`) that gives the screen to the goal's own chat.
- The goal's chat: hidden from Sessions, made on the first message, titled `Goal: <title> · <id prefix>`
  (`GoalChats.sessionTitle`); the link is saved on the goal (`PATCH chat`) and on this device. The chat's page is the
  goal's page laid over it (`ChatViewController.setTopAccessory`, as `TaskPage`); a tap on the message line, writing,
  sending or Find gives the chat the screen under the goal's bar; the bar or the title brings the goal back.
- A goal with no bot has none of it. A bot's own task under a milestone carries its face and dot, as on any row.
- **Faces on the Goals view's cards and the shelf's**: the lead and helpers at the card's end (`GoalBots.team`); the
  lead's dot is orange when an offer for that goal waits for you (`GoalBots.waitsForYou`). A face means the bot is on
  the goal; nothing else draws one.

### Offer cards (`GoalOfferCard`, `GoalOfferCell`, `GoalOffers`)
Built from `TaskOfferCard`: one height in every state, the live state from the store (`TodoOfferStates`), a card
answered elsewhere says so, "Answered" after a day.
- **goal**: the name, why, date, then "5 milestones" (the first three, "2 more ›") and "This week · 4 tasks" (three, each
  with who, "1 more ›"): **Make This Goal** / **Not Now**, and the quiet "Keep the Goal, No Plan".
- **plan**: the same without making a goal: **Use This Plan** / **Change It** (puts the cursor in the chat's box) and
  "Keep the Goal, No Plan" (declines the plan).
- **tasks** (board 5): the goal's mark and name, "add 2 tasks?", the rows with who: **Add to Goal** / **Just Tasks** /
  **No**; from a bot that is not on the goal, a quiet line under them says who leads it ("Hermes leads this goal").
- Answered: one line with what happened and **Undo**.
- Where they show (`ToolCard.goalOffer` from the `goals_offer` tool's answer, `GoalOffers.today`, `GoalOffers.onGoal`): in the chat they were made in, at the
  top of Today (one at a time, the oldest first, under any list offer) and on the goal's own page.
- The number row says its source when a bot reads it: "TestFlight · 8:02 AM" in place of Update (`GoalBots.sourceWords`);
  a tap still lets you set it by hand, and that makes the source you, after asking.

## Step 4: the check-in and the stall question (board 4)
- **The check-in card** (kind `checkin`) leads Today on its day and sits on the goal's page and in its chat: the bot's
  face, "<Bot> · Monday check-in" (`GoalOffers.checkinHead`), the goal's ring and name, the summary, "This week" with
  the tasks and who, **Add These N** / **Change** (opens the goal's chat) / **Not Now**. Answered: one line with Undo.
- **A looks-done offer** from the lead (`goal.offer`, `GoalBots.looksDone`) is the same soft card as step 1's own offers:
  its words, then **Mark Done** / **Not Yet** (`PATCH offer_answer: "done" | "keep"`).
- **The stall question**, bot or no bot (`GoalViews.stalled`): an active goal with at least one open task, nothing under
  it ticked, no number change and no milestone ticked for 14 days (and created, resumed and `kept_at` all more than 14
  days ago) asks on its page and as an orange second line on its card ("Nothing has moved in 16 days"): "The next task,
  “…”, has been open since Nov 28. Still want this one?" **Smaller Step** (opens New Task under the goal, or with a lead
  asks the bot for one in the goal's chat) / **Pause** / **Let It Go**, and a quiet "Keep Going" that sends `keep: true`.
  With 0.9.65 Keep Going is kept on this device only (`GoalKeptHere`).
- One push per check-in. The push opens the goal (`request` "goal:<id>", `TasksHub.openGoal`).
- The Goal check-in job is the add-on's; the app's Jobs list hides it by name, as Task prep (`TodoRunnerJobs`).

## Step 5: the Goal Page and the Mac
- "Page ›" on the stands card and ⋯ › Goal Page open the add-on's page in the page sheet (`HTMLPageSheet`), drawn again
  when the goal changes while it is open; Share sends "<title>.html"; **Ask for an Update** asks the lead in the goal's
  chat as a hidden turn (`GoalBots.updateRequest`). Only with `goal_pages`.
- **The Mac's two panes**: a goal with a lead opens with the goal in the centre and its chat as the right-hand pane
  (`MacInspector.followTask`'s pattern, ◨ and ⌘I close it, its own open state `HQMacGoalChatShown`); a goal with no bot
  has no pane.

## Step 6: a goal gets a bot planning it, and bots are one tap away (2026-11-19)
Only with an add-on that says `goal_bots`; without it nothing here shows. The owner made a first real goal on the
shipped build, a number and no date, and said nothing happened: they had expected a bot to start planning it. Plan With
was off and easy to miss, and nothing else offered a plan. After that build: there was no easy way to add a bot, or a
team of bots, to a goal (it was three levels down: hold the card › Edit Goal › Led By, then Helpers).
- **New Goal asks who is helping, in the sheet itself** (`NewGoalView.whoRow`). The owner, next: you should also be
  asked which bot you want when you make the goal. Under the why line, headed **Who's helping?**: one chip per bot of
  yours with its face and name (the row scrolls sideways when they don't fit), and a last chip **Just Me**. A tap puts a
  bot on the goal (a ticked chip is filled); the first ticked leads and its chip says "Leads" under the name; a
  helper's chip has a small menu (and a hold) with **Make Lead**, and the two swap. Just Me unticks them all. Under the
  row one quiet line says what Add will do (`GoalPlanWith.note`): "Hermes asks up to three questions, then offers a
  plan." (was "Hermes will offer a plan when you add this."; see Set-up) / "Hermes leads. Research helps." / "No bot.
  You can add one later." Add makes the goal with that lead and those helpers (in the POST since Set-up; one PATCH
  after it before) and, with a lead, opens its chat and asks for the plan. The old Plan With button
  in the buttons row is gone (the date and Number stay there).
- **It starts on** (`GoalPlanWith.start`): the root bot (profile `default`) leading the first time, else your first
  bot; after that what was picked last on this device (`GoalPlanWithMemory`), the whole team, Just Me included, so
  someone who wants plain goals says so once and the question is always answered on screen before Add. A remembered bot
  that is gone drops out; with none left it is the first time again.
- **The Bots row** on every goal's page, right under the date row, always there (with at least one bot of yours):
  "Just Me" with **Add Bots** at its end in the accent colour; with bots, the "Led by Hermes" row with the faces and
  the check-in's slot. A tap opens the team sheet. It is also the first row of the card's hold menu and of ⋯ ("Add
  Bots…" / "Bots…"), and Edit Goal has one **Bots** row (the same sheet) in place of Led By and Helpers.
- **The team sheet** (`GoalTeamSheet`, the quick add's shape): every bot of yours as a row with its face, name and a
  tick. The first ticked leads ("Leads" at its row's end); any other ticked bot has **Make Lead** (the two swap);
  unticking the lead makes the next ticked bot the lead (`GoalTeamPick`). Under the list: "The lead plans and checks in
  each week. The others take tasks." Then the check-in's day and time (with a lead), and **Done**. Each change saves as
  you make it (`lead`, `helpers`), one PATCH after another so quick ticks never meet a 409. VoiceOver: "Hermes, on
  this goal, leads" / "Research, on this goal" / "Finance, not on this goal", with Make Lead as an action.
- **A new first lead on a goal with no plan is asked for one** (`GoalPlanAsk.asksNewLead`): no milestones, no open task
  under it, no plan offer waiting, active. When the team sheet or Edit Goal closes on such a goal that had no lead when
  it opened, the goal reopens on its chat (`TasksHub.openGoal(_:chat:plan:)`) and the lead is sent the same hidden
  `GoalBots.planRequest` as New Goal's, your bubble the goal's name. A goal that has a plan is not asked; the team
  sheet opened over Edit Goal leaves the asking to Edit Goal's close.
- **A goal with a lead and no plan says so** (`GoalPlanAsk.showsAsk`): where the milestones would be, "No plan yet" and
  one button, **Ask <Bot> for a Plan**, which gives the chat the screen and sends the same request. Hidden while a plan
  offer for the goal waits; gone once it has a milestone or a task.
- **Never twice in a minute** (`GoalPlanGuard`, `GoalPlanAsks`): the same ask for one goal is not sent again within 60
  seconds (a double tap, Edit Goal then the button); the button says "Already asked Hermes for a plan."
- Guards: unit `GoalTeamTests`; UI (UITests/pages/TasksGoalTeamUITests.swift, the stand-in's `plain_goals`):
  `testTasks_GoalBotsRow`, `testTasks_NewGoalWhosHelping`, `testTasks_GoalEditGivesALead`,
  `testTasks_GoalAskForAPlan`; and `testTasks_GoalEditTeam` / `testTasks_GoalPlanWithBot` moved to the team sheet and
  the Who's helping? row that starts on the root bot.

## Set-up: a plan that builds on what you have and tidies the goal (2026-11-20)
The owner's first real goal was a sentence with a number in it. The lead asked three questions in 13 seconds and
offered a plan built on guesses, never asking what they already had (notes from a course they meant to follow). After
Add on the plan nothing visible happened: the lead wasn't told, where it stands stayed empty, and the lead's own tasks
waited for the next Task prep run. The goal's name stayed the sentence, with no why and no number.
- **The plan request** (`GoalBots.planRequest`, `planQuestions`, `planSteps`): look first for what you already have
  (notes and files, memory, earlier tries, a course or method); then at most three questions on one question card, each
  with choices, skipping what the looking or the goal already answers, in this order: what done looks like (a number or
  a date), what you already have or want to follow, how much time a week; then `goals_offer` kind "plan" with the
  milestones, the first week's tasks, and `name`, `why`, `measure {unit, start, target}` or `due`, and `built_on` (up to
  three lines). `planRequestStart`, the words wrapper and `planBubble` are unchanged.
- **Data** (the add-on's contract): a plan offer carries `setup` {name?, why?, due?, measure?} with only the keys the
  add-on kept (a name that differs from the goal's, case aside, and no other active or paused goal has; a why when the
  goal has none; a date when it has none; a number when it has none), absent when none; and `built_on` (one line each,
  90 characters at most, three at most), absent when none. A plan is valid with milestones, tasks or set-up fields.
  Accepting applies the set-up in the same write: the name becomes the title (and the old title the why, when the goal
  has none and the plan sends none), the number starts at its start; `made.setup` keeps what each changed key was; one
  "Plan added". Undo puts each back unless it was changed since. `GoalPlanSetup`, `TodoOffer.setup`, `.builtOn`.
- **The card** (page, Today, chat cell `GoalOfferCell`, the whole-offer sheet `GoalOfferAllView`): under the title,
  "Built on" with its lines in the quiet ink (`GoalOffers.builtOn`), then "Also sets" with one row per kept key in this
  order: **Name**, **Why**, **Number** ("0 of 100 drawings"), **By** ("Wed, Mar 31, 2027", as the page's date row
  without "By") (`GoalOffers.setupRows`). Each row is one VoiceOver element ("Name: Draw every day"), read before the
  milestones. A plan with neither looks as before.
- **One height in every state**: the rows are the offer's own words and never change after an answer; only their ink
  does (struck through once undone or declined). On the page and Today the answered line now stands in the room the
  buttons took (it was about 20 pt shorter), as the chat card already did.
- **Taking a plan tells the lead, once** (`GoalBots.planTakenRequest`, `GoalPlanTold`, `GoalPlanTaken`): when this
  device's tap is the one the gateway accepts (`TasksStore.onPlanTaken`), the lead gets a hidden turn in the goal's chat:
  "I took your plan for “Draw every day”: 4 milestones and 2 tasks are on it now. Start your own tasks under it now,
  then tell me where it stands in one line (goals_update with stands)." Never twice for one offer (kept per gateway on
  this device over relaunches; another device's accept is a 409 there), never on Undo, never without a lead. With the
  goal's page open it goes through that chat, so the reply shows as it comes; else through a chat of its own.
- **New Goal**: placeholder "What do you want to reach?"; the lead-only line above; the team goes in the POST
  (`GoalWire.createBody`; `GoalWire.teamLeft` PATCHes what an older add-on's answer doesn't carry).
- **A waiting plan says so**: with no next task, the shelf card's and the Goals view card's next-step line reads "Plan to
  look at" (`GoalShelfNext.planWaits`); before, only the lead's orange dot said it and the line said "No plan yet".
- Guards: unit `GoalSetupTests`; UI `testTasks_GoalPlanSetUp` (UITests/pages/TasksGoalSetupUITests.swift); the
  contract check's set-up steps (scripts/fixture-support/goals_contract_check.py).

### Guards (steps 3 to 5)
- Unit: `GoalBotsTests` (decoding every new field and a 0.9.65 goal, every offer kind, the stall rule from each side,
  where each offer card shows, the check-in card's words, the number's source words, faces and the waiting dot, the
  review words, the store's offer answers: accept, decline, undo, answered on another device, a 409).
- UI (UITests/pages/TasksGoalBotsUITests.swift, against the stand-in's `--task-goal-bots`): `testTasks_GoalEditTeam`,
  `testTasks_GoalPlanWithBot`, `testTasks_GoalTasksOfferFromAnotherBot`, `testTasks_GoalCheckin`,
  `testTasks_GoalLooksDone`, `testTasks_GoalStall`, `testTasks_GoalNumberFromBot`, `testTasks_GoalPage`,
  `testTasks_GoalBotsNeedTheAddOn`.
- The contract: `scripts/fixture-support/goals_contract_check.py` sends one sequence of requests to the stand-in and to
  the real add-on's router and prints every difference.
