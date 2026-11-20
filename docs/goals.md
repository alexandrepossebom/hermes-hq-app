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
- A task's `milestone` must be one of its goal's; otherwise it is cleared. Clearing `goal` clears `milestone`.
- Deleting a goal keeps its tasks (their `goal` and `milestone` are cleared). Removing a milestone keeps its tasks in
  the goal with no milestone.

## Routes (hermes-hq-push dashboard plugin_api, same sign-in as /tasks)
- `GET /tasks` gains `goals: [Goal…]` (every goal, any status, by `position`). The key being there says the add-on
  keeps goals; an older add-on leaves it out. Goals share the list's `rev`, so `?since=` hears of a goal's change.
- `POST /goals` `{title, why?, due?, color?, measure?: {unit, start, target, now?}, milestones?: [{title, due?}]}`
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
