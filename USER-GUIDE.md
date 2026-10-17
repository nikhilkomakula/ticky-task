# Kanban User Guide

TickyTask's **Kanban** module helps you track work across teams with visibility into who is doing what, who is overloaded, and what is waiting to be pulled. It sits alongside the Planner in the main window, sharing your local data store.

---

## Getting started

**Turn Kanban on.** Open **Settings › Kanban** and toggle **Show Kanban**. The module appears next to the Planner in the top bar.

**Switch between modules.** Press **⌘1** for Planner or **⌘2** for Kanban. Or click the **Planner | Kanban** segmented control at the top left of the window (it appears only when both modules are visible).

**Create your first board.** In the Kanban sidebar, click **New board**. Choose a template:
- **Default**: To Do → In Progress → Done.
- **Software**: Backlog → To Do → In Progress → In Review → Done.

Or load a saved template, or start blank and build your own columns.

**Set it up.** Right-click a column header to rename it, change its color, set a WIP limit, or move it left or right. Add people from the **People** tab in the sidebar (under **All projects**). Every new board starts with an **Unassigned** row pinned at the top.

---

## People and memberships

**People** are stored globally so you can add the same person to multiple boards. When you add someone to a board, you create a **membership** that defines how much of their time that board gets.

**Create a person.** In the sidebar's **All projects** section, click **People**, then click a board to see its members. Click **+ Add person** to create a new person or add an existing one to this board. A person has a name, initials, employment type (FTE or contractor), and optional skills.

**Set membership details on a board.**
- **Allocation %**: what portion of their time they spend on this board (e.g., 50 % for a half-time contractor).
- **Assignment**: full-time or part-time (used for display and filtering).
- **Start date** and **End date** (optional; the date they roll off the project).

The load target for each person—how many cards they should have open—is calculated from the board's **Open-task target per person** (default: 5) multiplied by their allocation %. A 50 % person on a board targeting 5 cards would have a target of 2.5 cards. You can override this per person or per board in **Settings › Kanban**.

**Archive a person.** In the People tab, right-click a person and choose **Archive**. Their tasks on every board move to **Unassigned**. You can undo this from each affected board's **Change Log**.

**Hard-delete a person.** A person with no memberships (archived ones included) can be permanently deleted. This cannot be undone.

---

## Cards

**Add a card.** Press **⌘N** or hover over a cell (column + person intersection) and click **+**. A new card starts in the backlog column, unassigned. It opens in the editor.

**Edit a card.** Click any card to open the editor. Fields include:

- **Title** and **Details** (rich-text notes with **⌘B / ⌘I / ⌘U** for bold, italic, underline; also strikethrough, links, and bulleted & numbered lists that continue on Enter and nest with Tab / Shift-Tab).
- **On the board**: column, assignee, and labels.
- **Priority** and **Critical** flag (the flag is independent and always shown in red).
- **Blocked** and optional reason.
- **Start date**, **Due date**, **Estimate** (hours, if the board measures load in hours).
- **Jira link** (validated; shows the key if recognized).
- **Depends on** (other cards in this project; the card shows a dependency glyph).
- **Subtasks** (per-card checklist; completed items sink to the bottom).
- **History** (the card's change log, newest first; each entry has a **Revert** button if it can be undone).

**Mark it blocked.** Toggle **Blocked** and enter a reason. The blocked glyph appears on the card and in dashboard charts.

**Assign it.** Use the **Assignee** picker in the editor, or drag the card to a row header to reassign it while keeping the column.

**Subtasks.** Add subtasks in the **Subtasks** section. They stay per-card, not per-project. When you finish the last one, the editor offers to move the card to **Done** (if **Offer to move a card to Done when its steps are done** is on in Settings).

**Schedule to the planner.** Click **Schedule to day…** in the editor. Pick a day and confirm. The card creates or updates a planner task with the same title, priority, Critical flag, and notes (notes are copied once only; later reschedules just move the day). The link is shown in both editors.

**Archive a card.** Click **Archive** in the editor. Archived cards can be shown with **Show Archived** on the board toolbar.

**Delete a card.** Click **Delete…** for confirmation. Deletion is permanent but can be undone from the **Change Log** for as long as the entry is there.

---

## Moving work

**Drag a card.** Drag to another cell, column header (keeps assignee), row header (keeps column), or Unassigned. A lifted preview and accent line show where it will land. If a column's WIP limit would be exceeded, the header turns red with "over limit" and a count; if set to block, the drop is refused.

**Capacity preview.** While you drag or move a card, the target row's **load gauge** shows the projected load (e.g., **4 → 6 / 5**, meaning it goes from 4 to 6 cards against a target of 5).

**Completion.** Moving a card into **Done** sets the completion date. Moving between done columns keeps it. Moving out clears it.

**Keyboard moves** (with a card focused on the board):
- **⌘← / ⌘→**: move to the previous or next column.
- **⌘↑ / ⌘↓**: reassign to the previous or next row.
- **⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓**: reorder within the cell or, with a header focused, reorder columns or rows.
- **M**: open the **Move** sheet to pick column and assignee.
- **⌃⌘↑ / ⌃⌘↓**: collapse or expand all rows.

**Select multiple cards.** **⌘-click** cards to add them to a selection. Dragging a selected card moves them all together. Right-click a selection to **Move**, **Assign**, **Label**, **Set Priority**, **Archive**, or **Restore** them all at once (each as one **Change Log** entry). Press **Esc** to clear.

**Reorder columns or rows.** Drag their headers left/right or up/down, or use **⌥⌘** arrows when focused.

---

## Finding work

**Search.** Press **⌘F** to search every task and card by title and notes. Results are grouped by module; click a card result to open the board with the card highlighted.

**Filter on the board.** Click the **Filter** icon (funnel) to filter by:
- **Title or notes** text.
- **Due** date (any, overdue, this week, next week).
- **Priority**, **Critical** flag, **Unassigned**, and **Open cards only**.
- **Blocked** cards, **Jira link** (has one or missing), **Estimate** (has one or missing).
- **Labels** and **People**.

Active filters appear as removable chips below the toolbar. Click **Clear** to reset all.

**Sort.** Click the **Sort** icon to sort by manual order, priority, due date, or title. The sort persists per board.

**Show Archived.** Click the archive icon to show or hide archived cards. This is remembered per board.

**List view.** Switch to **List** in the top toolbar to see a sortable table with multi-select. Use right-click to bulk move, assign, label, or change priority.

**Timeline.** Switch to **Timeline** to see dated cards as bars, grouped by person, with today marked.

---

## The dashboard

Switch to **Dashboard** to see your board's metrics. Each chart shows counts or hours depending on the board's **Measure load in** setting (Settings › Kanban › New boards). Charts include:

- **Load vs Capacity**: the number of open cards (or hours) each person has against their target.
- **Capacity Heatmap**: a 12-week heat map showing when people are busiest.
- **Tasks by Column**: how many cards are in each column.
- **Unassigned Backlog**: cards waiting to be assigned, sorted by ready-to-pull status.
- **Due Dates**: cards grouped by due date (overdue, this week, next week, later).
- **By Person**: open and done cards per person.
- **Team Composition**: employment types and allocation.
- **Blocked Cards**: cards marked as blocked and why.
- **Age in Progress**: how long cards have been in non-done columns.
- **Cumulative Flow**: card count over the past 90 days, showing new and completed work.
- **Finished Cards Per Week**: completed work per week (reopened work moves out).
- **Hygiene Checklist**: unassigned cards, dependencies, and old work.

Clicking any chart filters the board to show what the chart displays. The **All projects** dashboard rolls up these metrics across all boards, plus a **People** rollup that sums each person's load and allocation across all boards.

---

## Change log, undo and revert

**Undo and redo.** Press **⌘Z** to undo the last board change. Press **⇧⌘Z** to redo. These are scoped to the current project and cleared on relaunch.

**Change Log.** Click the **Change Log** button in the toolbar to see every board change, newest first. Each entry shows what changed and when. Click **Revert** to undo that specific entry, even if newer changes have been made (if there are conflicts, you'll see "This card changed after that entry. Revert the newer changes first.").

**What can't be reverted**: import, restore, and project hard-delete are irreversible. Entries before an import are also locked. Undoing a scheduled task link (Schedule to day…) is handled through the planner.

---

## Kanban Summary

**Write a status update.** Click the **Kanban Summary** button in the toolbar (next to **Weekly Summary**). Pick cards to include, then choose:
- **By person**: cards are summarized per person.
- **Whole board**: all selected cards are summed into one update.

Click **Select all with notes** to pre-select cards that have notes. Choose your AI connection (ChatGPT account, Codex config, or local model) and the model/effort, then click **Generate**. The update uses card titles, status, person, column, labels, priority, blocked state, Jira keys, subtasks, and notes—no ids or dates.

---

## Export, import and CSV

**Export a board.** Right-click a board in the sidebar and choose **Export board…** to save a `.tickytask-board` JSON file with the board's columns, labels, people and cards.

**Export as CSV.** Right-click a board and choose **Export as CSV…** to save a spreadsheet for spreadsheet tools or other systems.

**Import a board.** Click the import icon (arrow down) at the bottom of the sidebar, or right-click and paste a `.tickytask-board` file. A preview shows:
- **Boards**: create new or merge into an existing board.
- **People**: link to existing people or create new ones (by id first, then by name).
- **Repairs**: dropped dependency loops, unassigned cards from archived memberships, and completion mismatches.

Imported history is not included. Archived people arrive archived, with their cards Unassigned. **Undo** doesn't reach past an import.

---

## Menu bar's Kanban mode

In the menu bar, when both Planner and Kanban are visible, click the **Planner | Kanban** segmented control to switch modes.

**Kanban mode** lists cards due on the day you pick (or today). It shows:
- **Overdue** cards (only when viewing today).
- **Due today** (or the chosen day) across all your active boards.

Click any card to open the main window on that board with the card highlighted.

**Quick add.** At the bottom, add a card to your chosen quick-add board (set in **Settings › Kanban › Menu bar**). The card goes to the board's backlog, Unassigned, due on the shown day. If no boards exist, click **Create a project…** to switch to the Kanban tab.

The menu bar's calendar now marks days with due Kanban cards so you can see at a glance which days are busy.

---

## Settings › Kanban

**Modules**: toggle **Show the Planner** and **Show Kanban** (at least one stays on); choose which opens at launch.

**New boards** defaults:
- **Measure load in**: open tasks or hours. This affects all charts and capacity calculations.
- **Open-task target per person**: the default load target (e.g., 5 tasks per person).
- **Weight Critical and High cards**: if on, High and Critical cards count extra toward load (e.g., 2 or 1.5 × their count).
- **Over a WIP limit**: warn (show red but allow drop) or block the move.
- **Due soon: within N days**: the threshold for marking cards as due soon (default: 3 days).
- **Offer to move a card to Done when its steps are done**: when all subtasks are done, the editor asks if you want to move the card.

**Menu bar**: choose which board quick-add files into (last opened or a chosen board).

**Notifications**: toggle **Notify on Kanban due dates** and set the time.

**Archive**: toggle **Archive finished cards automatically** and set the delay (e.g., 30 days in Done).

**Templates**: view saved templates (from "Save as template…" on any board). Delete old ones here.

**Demo**: click **Load demo board** to load a sample project. Loading it again adds another copy.

---

## Backups and your data

Backups saved through **Settings › Data › Export** include your Kanban boards if you're running v0.2.0 or later. When you restore a backup:
- If it has a **kanban** section, your boards are replaced with what's in the file.
- If it doesn't (pre-Kanban backup), your existing boards stay.

Restoring a backup clears undo/redo for the board and imports. Everything is restored in one all-or-nothing transaction, so your data is safe.

**Data location** (Settings › Data): choose which folder holds your data. Changing it moves everything there. You can keep it in **iCloud Drive**, **Google Drive**, or **Dropbox** to carry tasks between Macs (use one Mac at a time and let the folder sync before opening elsewhere).

---

## Keyboard shortcuts

| Keys | Action |
|---|---|
| **Everywhere** | |
| ⌘F | Search tasks and cards |
| ⌘1 / ⌘2 | Switch to Planner / Kanban |
| ⌘/ | Show this shortcut list |
| **On the Kanban board** | |
| ⌘N | New card in the backlog |
| ⌘Z / ⇧⌘Z | Undo / redo a board change |
| ⌃⌘↑ / ⌃⌘↓ | Collapse / expand all rows |
| ⌘-click | Select multiple cards |
| Esc | Clear the selection |
| **With a card focused** | |
| ↑ ↓ ← → | Move focus between cards |
| ⌘← / ⌘→ | Previous / next column |
| ⌘↑ / ⌘↓ | Previous / next person |
| ⌥⌘ arrows | Reorder within the cell |
| Return | Open the card editor |
| Space | Quick look (preview) |
| M | Move sheet (column & assignee picker) |
| **With a header focused** | |
| ⌥⌘← / ⌥⌘→ | Reorder columns |
| ⌥⌘↑ / ⌥⌘↓ | Reorder rows |

---

## How cards flow through a board

```mermaid
flowchart TD
    A["New card<br/>Backlog, Unassigned"] --> B["Assign & move to<br/>To Do"]
    B --> C["Work begins<br/>In Progress"]
    C --> D{"Done?"}
    D -->|No| C
    D -->|Yes| E["Move to Done<br/>Completion date set"]
    E --> F["Finished"]
    F --> G["Archive manually<br/>or auto-archived<br/>after N days"]
    G --> H["Archived<br/>Hidden by default"]
    
    E --> I["Revert changes<br/>from Change Log"]
    I --> J["Restore to<br/>previous state"]
    
    H --> K["Show Archived<br/>to see it"]
    K --> L["Restore from<br/>archived"]
    L --> E
    
    M["Delete from editor<br/>or Change Log"] --> N["Deleted<br/>Permanent but<br/>reverts exist<br/>in Change Log"]
```

---

## How importing a board works

```mermaid
sequenceDiagram
    actor User
    participant App
    participant File
    participant Preview
    participant Store
    
    User->>App: Click import icon
    App->>File: Pick .tickytask-board file
    File-->>App: File selected
    App->>App: Decode & validate file
    App->>Preview: Show preview sheet
    Preview->>User: Display boards, people<br/>& repair choices
    User->>Preview: Choose new/merge,<br/>person links
    Preview->>Preview: Build resolution plan
    User->>Preview: Click Import
    Preview->>App: Validate choices
    App->>Store: Fetch existing data
    App->>Store: Begin transaction
    App->>Store: Insert/merge boards<br/>& people
    App->>Store: Repair references
    App->>Store: Commit transaction
    Store-->>App: Done
    App->>User: Open board<br/>Clear undo
    App->>User: Show success
```

---

## How the menu bar picks the quick-add board

```mermaid
flowchart TD
    A["Settings › Kanban<br/>chose a board?"] -->|Yes| B["Use chosen board"]
    A -->|No| C["Is there a<br/>last-opened board?"]
    C -->|Yes| D["Use last opened"]
    C -->|No| E["Use first active board"]
    B --> F["Quick add goes<br/>to backlog,<br/>Unassigned,<br/>due that day"]
    D --> F
    E --> F
    
    G["No active boards<br/>exist?"] -->|Yes| H["Show<br/>Create a project"]
    H --> I["Switch to Kanban"]
    G -->|No| F
```

---

## Card lifecycle diagram: backup reference

Every card goes through these states:

- **Backlog, Unassigned**: ready to be picked up.
- **Active** (To Do, In Progress, etc.): someone is working on it or about to.
- **Done**: moved to a done column; completion date is set.
- **Archived**: hidden; can be shown with **Show Archived**; auto-archives if enabled in Settings.

From any state except deleted, you can:
- **Revert** a change from the Change Log (if newer changes haven't made it impossible).
- **Restore** from archived back to Done.
- **Delete** it (permanent, but undoable via Change Log until the entry is gone).
- **Schedule to day** to link it with a planner task.

---

## Tips

- **Drag near column headers** to change a card's column while keeping its assignee.
- **Drag onto a row header** to reassign while keeping the column.
- **Drag onto Unassigned** to unassign immediately.
- **Collapse rows** (⌥-click a disclosure chevron or **⌃⌘↑**) to see counts and load gauges without scrolling through each person.
- **Capacity heatmap** shows 12 weeks; zoom in on calendar-specific dates in the Due Dates chart.
- **Multi-select + right-click** lets you move, assign, label, or change priority for many cards at once, recorded as one Change Log entry.
- **Undo and redo** are per-project and remembered until relaunch; redo clears when you make a new change.
- **Change Log Revert** works even after a relaunch and catches conflicts; undo doesn't.
- **Dependencies** don't block movement but show visually on the card.
- **Subtasks** sync automatically; finishing the last one can trigger a move-to-done offer.
- **Jira links** are validated when you save; the key is parsed from the URL.
- **Notes** can be rich text with formatting, links, and nested lists—just like in the planner.
