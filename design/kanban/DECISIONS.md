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
| I1-a | Increment 1, partial (models, backup, moves, gate) | **CHANGES REQUIRED** — 4 blockers: duplicate ids, live card on an archived membership crashing planning, gate missing projects and reverse relations, gate baseline taken after migration | Fixed in e881e11c |
| I1-b | Increment 1, full (adds the service, change log, undo) | **CHANGES REQUIRED** — 12 blockers, mostly reverting old entries | Fixed in d582877d (I-D1 to I-D4 below) |
| I1-c | Increment 1 re-review | **CHANGES REQUIRED** — 7 blockers: redo of an added column; dependencies restored by undo; a kind-change revert on a filled column; reactivating a membership of an archived person; the ⌘Z exemption; recurrence and timestamps missing from the gate; fault-injection gaps | Fixed in 7a6a5a3e |
| I1-d | Round 3 | **CHANGES REQUIRED** — 4 blockers: an ⌘Z after an undo/redo cycle wrongly refused (stale markers); undoing a title edit after a person restore wrongly refused (row-level); recurrence weekdays, month days and end not in the gate; an archived card's archived assignment dropped on put-back | Fixed: chain markers, field-level conflicts, recurrence rules checked against each fixture's own backup, reinsertion keeps archived assignments. A plain `unarchivePerson` replaces empty archive groups |
| I1-e | Round 4 | **CHANGES REQUIRED** — 1 blocker: reverting a move into a column that later became Done would leave the card in Done with no completion date (per-field conflicts allowed it) | Fixed: the invariant simulation checks completion against the column kind for every card a revert places. Also fixed (not blocking): a person-archive undo is checked against the person's own memberships, and putting back a live card on an archived membership is modelled as Unassigned |
| I1-f | Round 5 (final adversarial pass) | **CHANGES REQUIRED** — 2 blockers: reverting an archive could bring a card back live in a column that became Done, with no completion date; `restoreTask` could leave a live card on an archived membership | Fixed: a card coming back counts as placed in the simulation (completion and active membership are checked), and `restoreTask` fits the card to the board as it is now (completes it in Done; Unassigned if its membership was archived), recording the change so ⌘Z reverses it |
| I1-g | Round 6 | **CHANGES REQUIRED** — 1 blocker: an edited backup could restore a live card in Done with no completion date | Fixed: the backup sanitiser repairs completion against the column (counted as `repairedCompletions`) |
| I1-h | Round 7 | **INCREMENT-1: APPROVED** | Merged to main via PR (no tag) |
| I2-a | Increment 2 (templates, board edits, metrics) | **CHANGES REQUESTED** — 1 blocker: count-mode load ignored cards dated after this week (§0 says `v₀ = v` in count mode); 5 should-fix: board edits accepted values of the wrong kind (unundoable), backlog groups counted cards in hours mode, view state saved without a change-log entry, an archived prerequisite hidden by other blockers, malformed Jira URLs passing hygiene | Fixed all but view state, which is exempt by design (I-D6) |
| I2-b | Round 2 | **CHANGES REQUESTED** — fixes 1, 2, 3, 5, 6 confirmed; **I-D6 accepted**; 2 should-fix: negative or non-finite board defaults accepted (a −4 h default estimate cancels real work), a zero-capacity member with work not counted as over capacity | Fixed: numeric board settings must be finite and ≥ 0; `.noCapacity` with load counts as over capacity |
| I2-c | Round 3 | **INCREMENT-2: APPROVED** — no findings | PR after increment 1 merges (no tag) |
| I3-a | Increment 3 (module switch, sidebar, board grid, overview) | **CHANGES REQUESTED** — 9 should-fix: membership date revert could end before start; membership sheet half-saved on a bad name; module keys differed from the backup's; planner search reveal stayed in Kanban; Attention missed the initial scroll and collapsed rows; restore kept a stale selection and sheets; sticky row backgrounds short on tall rows; cross-board badge missed loaded no-capacity; metrics recomputed on every scroll | All fixed (2cd64991): dates in `KanbanInvariants`, name precheck, backup keys, `reveal` sets the planner, `.task(id:)` reveal that expands the row, restore token remount + selection reconcile, full-height sticky headers, `isOverCapacity`, `KanbanMetricsCache` + an observed-only-by-sticky-views scroll offset |
| I3-b | Round 2 | **CHANGES REQUESTED** — 2 should-fix: archived memberships skipped the date check; the cache clock missed time-zone changes; nit: the rollup cache ignored a different set of boards | Fixed: dates checked on every membership; `kanbanClock` (day + time zone) refreshed by the timer, activation and `NSSystemTimeZoneDidChange`; rollup keyed by project ids |
| I3-c | Round 3 | **CHANGES REQUESTED** — round-2 fixes confirmed; 1 should-fix: Attention didn't observe the clock, so due-soon/overdue went stale across midnight | Fixed: Attention, cards (due colours) and row headers (roll-off badge) observe `kanbanClock` |

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
| D1 | Additive Kanban models under **automatic lightweight migration**, not a new `VersionedSchema` stage. The project rule forbids multi-`VersionedSchema` plans (duplicate checksums), and every release since v0.1.0 used automatic migration. **Gate:** increment 1 must open the real v0.1.1–v0.1.15 fixture stores and a new v0.1.17 fixture, then build, save and reopen the full eight-model graph with exact equality. | Claude (00 B1) | R0 agree; R1 **CHANGE**: "replace Verified with a required implementation gate" → applied | ✅ approved by owner |
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
| D15 | **Owner chose a shared person directory.** An app-wide `KanbanPerson`; `KanbanResource` becomes a per-board membership (allocation, assignment, dates, overrides). Board capacity stays per project. The People rollup (02 §1 (3b)) always computes a weighted task count. Its band uses hours only when every board is in hours mode. It warns when total allocation is above 100 %. | Codex (R1 blocker 9) → owner | R1: "define shared identity/allocation aggregation" → now defined; *R5* | owner-decided; R5 changes required → R6 approved |
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

## Implementation decisions (Phase 2)

| ID | Decision | Why | Codex |
|---|---|---|---|
| I-D1 | Every revert — ⌘Z, ⇧⌘Z and Change Log alike — is refused while a newer entry that's still in effect changed a field this entry depends on. The comparison is per field: a title edit and a reassignment of the same card don't conflict; adding or removing a whole row conflicts with everything about it. A newer entry that reverts another newer entry is a cancelled pair and doesn't count, and neither do entries in this entry's own revert chain. On every revert, the "reverted by" markers are recomputed down the whole chain, so after any undo/redo sequence they say exactly which entries are in effect. | Reverting old entries otherwise drops later work (I1-b #3, #6, #7). Exempting ⌘Z was unsound because cross-board person archives aren't on a board's undo stack (I1-c #5). Row-level conflicts were too coarse (I1-d #2). | I1-b, I1-c, I1-d → *I1-e* |
| I-D2 | Every revert's inverse is simulated on `KanbanInvariants` first: one backlog, ≥ 1 Done, every live card in an existing column on an active membership, no person twice on a board, acyclic dependencies. | Historical inverses bypassed the service invariants (I1-b #6) | I1-b → *I1-c* |
| I-D3 | `KanbanProject.historyBoundarySeq` (additive, default 0) is set on restore; entries at or below it can't be reverted. | Restored rows are rebuilt from the backup, at millisecond precision (I1-b #10) | I1-b → *I1-c* |
| I-D4 | The service reads column cards, step assignments and memberships through forward links (`task.column`, `step.assignee`, `resource.person`), never through the inverse arrays. | SwiftData's in-memory inverse arrays can lag after a change in the same context (seen in tests) | — |
| I-D5 | Activity payload dates use the default JSON encoding (seconds as a Double), not the backup's ISO milliseconds. | Conflict checks compare them with live values exactly | — |
| I-D6 | View state (row collapse, `boardState`, sidebar order) is saved through the service but isn't a board change: no change-log entry, no undo, no Revert. | Logging it would make ⌘Z re-expand a row instead of undoing the last real change, and fill the Change Log with clicks; filters and sort already live in `boardState` as view state (01 §5) | I2-a #4 → ✅ *I2-b* |
