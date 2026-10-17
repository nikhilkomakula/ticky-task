# Kanban — decision and review log

Each entry records what was decided, who raised it, Codex's position, and the outcome:
- **agreed** — Claude and Codex concur;
- **changed** — the design moved because of a review;
- **rejected** — considered and not adopted, with the reason;
- **needs owner** — waits for your confirmation at the Phase 0 + 1 checkpoint.

## Review rounds

| Round | Scope | Codex verdict | Outcome |
|---|---|---|---|
| R0 | Independent Phase 0 discovery (read-only, `57f9890e`) | Two blockers in the brief (B1 migration, B2 backup version); risks B11–B15 | Merged into 00 §11 and into 01 |
| R1 | 01-design + 02-metrics | **CHANGES REQUIRED** — 11 blockers; D2, D3, D6–D13 agreed; D1, D4, D5, D14 changed | All 11 blockers addressed in the docs (see the table below); D15 and D16 raised for you |
| R2 | Re-review of the R1 fixes | **CHANGES REQUIRED** — blockers 1, 3, 5, 6, 9, 10 and 11 resolved; 2, 4, 7 and 8 partial, leaving 4 issues | All 4 fixed (below) |
| R3 | Re-review of the R2 fixes | **CHANGES REQUIRED** — R2 #1, #2 and #4 resolved (#1 verified against `BackupStore`/`RecurrenceNormalizer`); #3 inconsistent: the preview baseline `L` was still total hours | Fixed: `L(r) = Σ v₀` is the single weekly baseline for the headline, segments, band and preview; `B(r) = Σ v` is used only for backlog coverage; test added |
| R4 | Confirm the R3 fix + final scan | **DESIGN: APPROVED** | Presented to you at the checkpoint |
| Owner | Checkpoint 1 (2026-10-17) | — | **Approved** D1, D8, D11 (keep boards), D13 (v0.2.0), D16 (full scope); **D15 → shared person directory** |
| R5 | Review of the person-directory extension (D15) | **CHANGES REQUIRED** — 4 blockers; `.deny` exists but runtime enforcement unverified | All fixed: (1) the rollup's count numerator is independent of board mode, and the band uses hours only when every board is in hours mode; (2) a person-archive coordinator with per-board informational activities and a conflict-checked group Undo archive; (3) membership-delete Revert preflights the person and uniqueness, and project payloads never carry person fields; (4) the resolved destination graph is validated after matching, with a reuse policy and reference rewrites. `.nullify` + service preflight replaces `.deny`; the gate covers eight models |
| R6 | Confirm the R5 fixes | **DESIGN: APPROVED** | The design is final; Phase 2 begins |

### R2 issues and how they were resolved

| # | Codex issue | Resolution |
|---|---|---|
| 1 | Restore deletes before its normalisation and link repair are prepared | 01 §7: every fallible step (decode, validate, checkpoint, fetches) runs first; after the deletions only non-throwing in-memory work runs (insert, `normalize(inserted)` — whose one fetch is `try?` — and link repair against the in-memory normalised set). 01 §1.2 states this rule for all paths. |
| 2 | Destructive payloads can't support both safe revert and replay | 01 §2.3: a column delete and a resource archive/delete record from/to transitions for every surviving task. Replay treats them as moves, and revert checks each `to`. A new `restoredGraph` kind carries the inverse's forward transitions. |
| 3 | Hours-mode stacks and preview mixed backlog hours with weekly hours | 02 §0–1: new `v₀(t)`, this week's share. The headline, segments and preview all use it; total hours appear only in backlog coverage. |
| 4 | Schedule-to-day has no inverse | 01 §2.3: an informational `scheduled` entry, not undoable (the planner owns the row and has no undo); you unschedule from the planner. The new non-saving `DataService.place(_:at:)` keeps `dropTask`'s day/list/unassigned and insertion-order behaviour. |

Clarifications applied:
- A backlog swap needs both columns empty.
- Reverting a restore-from-archive re-archives (it isn't a deletion).
- `seq` orders the log, while `at` supplies replay's daily cutoffs and ages.
- Redo re-applies the recorded `completedAt`.
- The owner-decision framing was reworded as Codex suggested (D8, D11, D13).

### R1 blockers and how they were resolved

| # | Codex blocker | Resolution (doc §) |
|---|---|---|
| 1 | Relationship and ownership contract incomplete; sole-backlog deletion; dependency cycles | 01 §1.1: explicit table (optional `column` for nullify; nullify directions for labels, resources, assignees and dependency edges); same-project checks; cycles refused by the service and dropped-and-reported on import; the backlog can't be deleted, only swapped |
| 2 | Fail-closed handling for *every* physical deletion | 01 §1.2: every delete path listed, prepare → delete → save once, a fault-injection test per path |
| 3 | ⌘Z could redo its own undo | 01 §2.4: only original user operations go on `undo`; inverses never do; fresh changes clear `redo`; stacks change only after a successful save |
| 4 | Whole-DTO revert unsafe after later edits; column-delete reversal; project delete | 01 §2.3–2.4: per-field deltas with expected current values; conflicting reverts refused before mutation; a column delete stores the migrated placements; project hard-delete is irreversible (with confirmation) |
| 5 | Restore link semantics | 01 §7: absent `kanban` keeps boards and an empty section replaces them; one transaction; links repaired against the *normalised* planner set; revert revalidates links |
| 6 | Tokens miss restore and midnight | 01 §2.5 + 02 §5: a store generation bumped by service saves, rollback, restore and import; the clock key re-read on the timer, activation, time-zone and week-start changes; restore clears history |
| 7 | Replay contract (no `seq`, kind changes, Done→Done) | `seq` from `project.nextActivitySeq`; per-task transitions in grouped and inverse activities; a populated column's kind can't change; Done→Done keeps `completedAt` |
| 8 | Heatmap endpoints; open tasks only; hours units | 02 §1: `e_t = max(s0, e0, today)`, open tasks only; hours mode = this week's distributed hours ÷ capacity, plus a separate backlog-coverage figure |
| 9 | "Who" across projects | **D15** (needs owner): v0.2.0 capacity is per project; All-projects rollup is per project, not per person |
| 10 | Schedule-to-day atomic upsert | 01 §7: one coordinator, one save; a new non-saving `DataService.place(_:at:)`; recurring occurrences are marked modified first; later planner edits preserved |
| 11 | Explicit increment-1 data-safety gates; relaunch journeys need `-uitestStore` | 01 §9: an increment-1 gate modelled on `SeriesSignoffTests`; relaunch UI journeys on an isolated disk store |

Codex's non-blocking R1 points were also applied:
- shortcut routing when a text field has focus;
- drag and header feasibility checks;
- the popover seam (markers, drag cancellation, no-project quick-add);
- notification safeguards mirrored;
- Kanban Summary with its own prompt rules;
- the throughput label;
- archived dependencies no longer count as done;
- the "4/5 amber" walkthrough error;
- the history-size budget;
- cold performance measurement;
- a minimal Attention view and the load gauge moved up to increment 3.

## Decisions

| ID | Decision | Raised by | Codex | Status |
|---|---|---|---|---|
| D1 | Additive Kanban models under **automatic lightweight migration**, not a new `VersionedSchema` stage. The project rule forbids multi-`VersionedSchema` plans (duplicate checksums), and every release since v0.1.0 used automatic migration. **Gate:** increment 1 must open the real v0.1.1–v0.1.15 fixture stores and a new v0.1.17 fixture, then build, save and reopen the full seven-model graph with exact equality. | Claude (00 B1) | R0 agree; R1 **CHANGE**: "replace Verified with a required implementation gate" → applied | ✅ approved by owner |
| D2 | Module switch is a segmented control in the existing custom top bar (Planner `calendar` / Kanban `square.grid.3x2`, ⌘1/⌘2), not a native `TabView`. The bar isn't an `NSToolbar`, and the window shell must stay persistent. | Claude (00 B6) | R0 + R1 AGREE | agreed |
| D3 | The KanbanTask → planner link is a scalar `linkedPlannerTaskID: UUID?`, not a relationship. `TaskItem`'s schema stays untouched, matching the `templateID` pattern. Links are resolved after normalisation and never to a hidden definition; restore and revert repair them. | Claude | R0 + R1 AGREE | agreed |
| D4 | A separate `KanbanTaskEditor`. `RichNotesEditor` is reused as-is; the priority picker, Critical toggle and subtask row are private today, so they're **extracted** into small shared views (behaviour-neutral, covered by the planner UI tests). | Claude | R1 **CHANGE**: "describe them as small extractions … they are private implementation details" → applied | changed |
| D5 | Undo/redo built on `KanbanActivity` field-delta inverses (`KanbanHistory`), with the stack rules, conflict checks and irreversible operations of 01 §2.3–2.4. `ModelContext.undoManager` stays off. | Claude (00 B5) | R0 caution; R1 **CHANGE** (blockers 3–4) → applied | changed |
| D6 | Sticky headers come from one two-axis `ScrollView` whose headers are offset by `onScrollGeometryChange`. No "no lag" claim; geometry and hit-testing are validated in increments 3 and 5. | Claude | R1 AGREE (remove the unverified guarantee → done) | agreed |
| D7 | `collapsedRowKeys: [String]` (resource UUID strings + `"unassigned"`) instead of the brief's `expandedResourceIDs`. New rows start expanded with no bookkeeping, and Unassigned gets a key. | Claude | R1 AGREE | agreed |
| D8 | Backup: `schemaVersion` stays **2**; a new optional top-level `kanban` section carries its own `version: 1`. v0.1.17 restores the planner part and ignores the boards (but drops them if you re-export from it); v0.1.16 still rejects schema-2 files. **Alternative:** bump the outer `schemaVersion` to 3, so v0.1.17 refuses Kanban-era backups outright instead of importing their planner part. | Claude (00 B2) | R0 proposal; R1 AGREE | ✅ approved by owner |
| D9 | Expand all / Collapse all on ⌃⌘↓ / ⌃⌘↑, because ⌥⌘arrows are used for reordering; board-scoped, inactive while a text field has focus. | Claude | R1 AGREE | agreed |
| D10 | Card → planner-day drag is deferred; "Schedule to day…" (an atomic upsert) covers it for v0.2.0. | Claude | R1 AGREE | agreed |
| D11 | Restoring a **pre-Kanban** backup (no `kanban` key) **keeps the existing boards**; a present-but-empty section replaces them with none. Links are repaired against the normalised planner set in the same transaction. **Alternative:** replace-all, a true snapshot replacement in which a restore always mirrors the file exactly. It deletes every board when you restore a pre-Kanban backup. | Claude | R1 AGREE (distinguish absent from empty; repair atomically → done) | ✅ approved by owner |
| D12 | Opt-in per-project **auto-archive** of completed board tasks (never deletes); skipped in a recovery session. | Claude | R1 AGREE (call it auto-archive → done) | agreed |
| D13 | The release tag is **v0.2.0**, even though the upstream WeekToDo tags v2.0.0–v2.2.0 exist. None of those is a GitHub release on origin, and `git describe` resolves to the nearest tag. Confirm v0.2.0, or name a different tag (the brief's literal rule would give v2.3.0). | Claude (00 B3) | R0 confirm; R1 AGREE | ✅ approved by owner |
| D14 | Metric choices (02 §7): `max` weighting, fractional targets, exclusive Critical row. The heatmap window swaps on both endpoints and counts open tasks only; hours mode separates weekly utilisation from backlog coverage; archived dependencies still block (deleted ones drop out); throughput is labelled "by latest completion". | Plan agent | R1 **CHANGE** → applied | changed |
| D15 | **Owner chose a shared person directory.** An app-wide `KanbanPerson`; `KanbanResource` becomes a per-board membership (allocation, assignment, dates, overrides). Board capacity stays per project. The People rollup (02 §1 (3b)) always computes a weighted task count. Its band uses hours only when every board is in hours mode. It warns when total allocation is above 100 %. | Codex (R1 blocker 9) → owner | R1: "define shared identity/allocation aggregation" → now defined; *R5* | owner-decided; R5 pending |
| D16 | **Scope: the full brief** (owner). Codex's deferral list was declined. | Codex (R1 non-blocking) → owner | — | ✅ owner: full scope |

## Karavan elements (App Store id6754577196)

| Element | Adopted? | Why |
|---|---|---|
| Project sidebar with pinned, colour-coded projects and icons | **Yes** (SF Symbols instead of photo icons) | Fast switching between boards; no image storage |
| Two-tier toolbar: filter chips scroll + Clear | **Yes** | Active filters stay visible without crowding the bar |
| Sort / Show Archived buttons that light up when active | **Yes** | You can see the state at a glance |
| Sticky column headers | **Yes**, plus sticky row headers | The rows are people; their names must stay in view |
| Subtle priority dot | **Partly** | We reuse the planner's priority glyph and tint plus the Critical flag (settled decision 2), drawn at dot-like size |
| Configurable "finished" columns | **Yes** (`kind == .done`, one or more) | Dashboards key off `.done` |
| Subtasks sink when done + suggest Move to Done | **Yes** (can be turned off) | Settled decision 5 |
| Up Next (cross-project) | **Yes**, as **Attention** | It answers "what's pending" across projects |
| Change Log with one-tap revert | **Yes** | It is also the undo backbone (D5) |
| Search scrolls to the match and highlights it | **Yes** | Same mechanism as the planner's `reveal` |
| Shortcut tooltips + cheat sheet | **Yes** | New shortcuts overlay (⌘/) |
| iCloud sync, attachments, Pomodoro, custom task types, Eisenhower matrix | **No** | Out of scope per the brief (§2.2, §2.6) |
| Paste-to-checklist (one subtask per line) | **No** (for now) | Not in the brief; can be added later |
