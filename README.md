# TickyTask

A **native macOS** weekly & monthly planner — a privacy-first, local-only rewrite of [WeekToDo](https://weektodo.me) in **SwiftUI + SwiftData**. All your data stays on your Mac; there is no account, server, or telemetry.

> **v0.1.7** (pre-release) · **macOS 15+** (Sequoia and later) · **Apple Silicon** · distributed **unsigned** (see install note below).

---

## Download & install

1. Download **`TickyTask-0.1.7-arm64.dmg`** from the [Releases page](https://github.com/nikhilkomakula/ticky-task/releases).
2. Open the DMG and drag **TickyTask** into **Applications**.
3. The app is **unsigned**, so macOS Gatekeeper blocks it on first launch — **right-click TickyTask → Open** and confirm, or clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TickyTask.app
   ```

Requires **macOS 15+** on **Apple Silicon**. Because the build isn't signed/notarized, launch-at-login and local notifications won't fire until a signed build is produced.

## Features

- **Week view** (the default) — configurable 1–12 day columns, Monday/Sunday start, an optional **show weekends** toggle (off by default, so weekends are hidden and the columns show only weekdays — **Settings › Appearance**), and previous/next/today navigation.
- **Month view** — a calendar grid showing every day's tasks, with a selected-day agenda panel; toggle between **Week** and **Month**.
- **Task editor** — title, **Markdown notes** (edit/preview), optional time (off by default), **priority** (Low/Medium/High) that color-codes the task (green → orange → red), an optional **Critical** flag (off by default) that adds a red flag *before* the priority — independent of the priority level — and **subtasks**.
- **Custom lists** — a renamable, date-independent lists row beneath the week (defaults: *Requires immediate attention*, *To be addressed*, *Weekend tasks*, *Miscellaneous*) that persists across all weeks; resizable split.
- **Drag & drop** — smooth, cursor-tracking reordering: drag a task to reorder it within a day or list, or move it **across days and across lists**, in the **Week** and **Month** views *and* the menu-bar popover — a lifted preview follows the cursor and an accent line shows exactly where it will land. Drop a task onto any day in the calendar grid (or the menu-bar mini-calendar) to move it there, and reorder the custom-list cards by dragging a card's grip handle.
- **Behaviors** — sort by manual order / time / priority, move completed tasks to the bottom, automatically carry unfinished tasks forward to today, and optionally **auto-delete tasks completed more than N days ago** (off by default; N defaults to 7 and is configurable — **Settings › Behavior**).
- **Notifications** — optional per-task time reminders and a daily end-of-day "unfinished tasks" reminder.
- **Menu-bar app** — a menu-bar icon opens a mini calendar (Sunday-first, weekends highlighted) that **always opens on today** and lists the **full day without scrolling**, plus inline quick-add; open the main window, reach Settings via the gear, or run menu-bar-only (no Dock icon).
- **Global shortcuts** — configurable hotkeys to open TickyTask, capture a new task for today, and **toggle the menu-bar popover** — from any app (**Settings › Shortcuts**).
- **Search** — press **⌘F** (or click the toolbar's magnifying glass) to search every task by title and notes, then pick a result to jump straight to it.
- **Backup & restore** — export your entire store **and app settings** to a portable `.tickytask` JSON file (optionally passphrase-encrypted with **AES-256-GCM**, key derived via PBKDF2) and restore it later, with a change preview before anything is replaced. **Settings › Data**.
- **Data location** — choose which folder holds your data (**Settings › Data**); changing it **moves everything there** and relaunches (or, if the folder already has a TickyTask store, adopts it). You can keep it in an **iCloud Drive / Google Drive / Dropbox** folder to carry your tasks between Macs — it's a live database, not real-time sync, so use one Mac at a time and let the folder finish syncing before opening it elsewhere.
- **Appearance** — System/Light/Dark theme, compact rows.
- **Launch at login** — starts TickyTask automatically when you log in (**Settings › General**, on by default; also manageable in System Settings › General › Login Items).
- **Software updates** — checks the project's GitHub Releases (latest stable **or pre-release**) for a newer version, manually or automatically (**Settings › General**).
- **About & Help** — app version, GitHub/issue links, license, and quick tips (**Settings › About**).
- **Polished native UI** — material day/list cards (custom lists align under the day columns), hover affordances, and refined typography; task titles **wrap to the available width** (in week columns and custom lists); opens **maximized** with a single toolbar: Week/Month switcher (left), the current date range (center), and ‹ Today › navigation (right).
- Clean gradient calendar app icon; first-run sample data.

## How it works

TickyTask is a single SwiftUI app with three scenes sharing one local SwiftData store and one `AppState`:

1. **Main window** — the Week/Month planner.
2. **Menu-bar popover** — a compact calendar + today's agenda + quick-add.
3. **Quick-capture window** — a tiny "new task for today" box opened by a global shortcut.

Tasks live in an on-disk SwiftData store (`~/Library/Application Support/TickyTask/TickyTask.store`). Views read it with live `@Query`s; task creation and ordering go through a single `DataService` (timestamps, sort indices, and the "day XOR custom-list" rule), while lightweight edits save directly to the context. Drag-and-drop reordering and cross-day/-list moves route through the same `DataService`, which re-derives sort indices and preserves the day-XOR-list rule. Pure logic (recurrence math, week/day-key math, sort & carry-forward behaviors) is isolated in `Services/` and unit-tested.

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
xcodegen generate            # generates TickyTask.xcodeproj from project.yml
open TickyTask.xcodeproj    # then Run (⌘R) — or build from the CLI:

xcodebuild -project TickyTask.xcodeproj -scheme TickyTask \
  -destination 'platform=macOS' build

# run the tests
xcodebuild test -project TickyTask.xcodeproj -scheme TickyTask \
  -destination 'platform=macOS'
```

The only third-party dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (resolved via Swift Package Manager).

### Opening the unsigned build

Because the app is not yet code-signed/notarized, Gatekeeper will warn on first launch. Right-click the app → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/TickyTask.app
```

Note: macOS delivers local notifications only for code-signed apps, so the reminder features require at least an ad-hoc/Developer-ID signed build to actually fire.

### Releasing

Pushing a **`vX.Y.Z`** tag triggers the [`Release` workflow](.github/workflows/release.yml): it builds the arm64 Release app (the version is stamped from the tag), packages `TickyTask-X.Y.Z-arm64.dmg`, and publishes it as a GitHub pre-release — releases are no longer built by hand.

```bash
git tag v0.1.7 && git push origin v0.1.7   # → CI builds the DMG and creates the release
```

## Roadmap

- Recurring-tasks UI (daily/weekly/weekdays/monthly/yearly) — the model & engine are in place; the editor UI is next
- Import from legacy WeekToDo `.wtdb` exports
- Localization (String Catalog)
- Signed & notarized **universal** DMG release (the app is currently unsigned/arm64)

## Tech stack

SwiftUI · SwiftData · Swift Testing · CryptoKit · XcodeGen · KeyboardShortcuts. macOS 15+ deployment, built against the macOS 26 SDK.

## Credits & license

A native macOS fork of **WeekToDo** by [Manuel Ernesto Garcia](https://manuelernestogr.bio.link/). Licensed under **GPL-3.0**, like the original.
