# TodoPlanner

A **native macOS** weekly & monthly planner — a privacy-first, local-only rewrite of [WeekToDo](https://weektodo.me) in **SwiftUI + SwiftData**. All your data stays on your Mac; there is no account, server, or telemetry.

> Status: active rewrite on the `feature/native-macos-rewrite` branch. macOS 15+ (Sequoia and later), Apple Silicon & Intel. Distributed **unsigned** for now.

---

## Features

- **Week view** (the default) — configurable 1–12 day columns, Monday/Sunday start, previous/next/today navigation.
- **Month view** — a calendar grid showing every day's tasks, with a selected-day agenda panel; toggle between **Week** and **Month**.
- **Task editor** — title, **Markdown notes** (edit/preview), optional time (off by default), **priority** (Low/Medium/High/Critical) that color-codes the task (green → yellow → orange → red; a flag marks Critical), and **subtasks**.
- **Custom lists** — a renamable, date-independent lists row beneath the week (defaults: *Requires immediate attention*, *To be addressed*, *Weekend chores*) that persists across all weeks; resizable split.
- **Behaviors** — sort by manual order / time / priority, move completed tasks to the bottom, and automatically carry unfinished tasks forward to today.
- **Notifications** — optional per-task time reminders and a daily end-of-day "unfinished tasks" reminder.
- **Menu-bar app** — a menu-bar icon opens a mini calendar with the selected day's tasks and inline quick-add; open the main window or run menu-bar-only (no Dock icon).
- **Global shortcuts** — configurable hotkeys to open TodoPlanner and to capture a new task for today from any app.
- **Appearance** — System/Light/Dark theme, compact rows.
- Clean app icon; first-run sample data.

## How it works

TodoPlanner is a single SwiftUI app with three scenes sharing one local SwiftData store and one `AppState`:

1. **Main window** — the Week/Month planner.
2. **Menu-bar popover** — a compact calendar + today's agenda + quick-add.
3. **Quick-capture window** — a tiny "new task for today" box opened by a global shortcut.

Tasks live in an on-disk SwiftData store (`~/Library/Application Support/TodoPlanner/TodoPlanner.store`). Views read it with live `@Query`s; task creation and ordering go through a single `DataService` (timestamps, sort indices, and the "day XOR custom-list" rule), while lightweight edits save directly to the context. Pure logic (recurrence math, week/day-key math, sort & carry-forward behaviors) is isolated in `Services/` and unit-tested.

```mermaid
flowchart TD
    subgraph Scenes
        MW[Main Window\nWeek / Month] 
        MB[Menu-bar Popover]
        QC[Quick-capture Window]
        ST[Settings]
    end
    MW & MB & QC --> AS[AppState]
    MW & MB & QC --> DS[DataService]
    DS --> SD[(SwiftData store)]
    subgraph Services
        BEH[BehaviorService\nsort · carry-forward]
        NOT[NotificationService\nper-task · end-of-day]
        WM[WeekMath / RecurrenceEngine]
    end
    MW --> BEH
    MW --> NOT
    MW --> WM
    ST -->|@AppStorage| MW
```

## Build & run from source

Prerequisites: **macOS 15+**, **Xcode 26**, and **XcodeGen** (`brew install xcodegen`).

```bash
xcodegen generate            # generates TodoPlanner.xcodeproj from project.yml
open TodoPlanner.xcodeproj    # then Run (⌘R) — or build from the CLI:

xcodebuild -project TodoPlanner.xcodeproj -scheme TodoPlanner \
  -destination 'platform=macOS' build

# run the tests
xcodebuild test -project TodoPlanner.xcodeproj -scheme TodoPlanner \
  -destination 'platform=macOS'
```

The only third-party dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (resolved via Swift Package Manager).

### Opening the unsigned build

Because the app is not yet code-signed/notarized, Gatekeeper will warn on first launch. Right-click the app → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/TodoPlanner.app
```

Note: macOS delivers local notifications only for code-signed apps, so the reminder features require at least an ad-hoc/Developer-ID signed build to actually fire.

## Roadmap

- Recurring-tasks UI (daily/weekly/weekdays/monthly/yearly) — the model & engine are in place; the editor UI is next
- Import from legacy WeekToDo `.wtdb` exports; portable JSON export
- Encrypted backup **export/import** with restore preview
- Drag-and-drop reordering / moving tasks across days
- Localization (String Catalog)
- Signed & notarized **universal** DMG release; retire the legacy Electron sources

## Tech stack

SwiftUI · SwiftData · Swift Testing · XcodeGen · KeyboardShortcuts. macOS 15+ deployment, built against the macOS 26 SDK.

## Credits & license

A native macOS fork of **WeekToDo** by [Manuel Ernesto Garcia](https://manuelernestogr.bio.link/). Licensed under **GPL-3.0**, like the original.
