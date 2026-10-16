# Legacy store and backup fixtures

One folder per historically distinct SwiftData schema TickyTask has shipped.
Each holds `TickyTask.store` (checkpointed into a single file), a plaintext and
an encrypted backup (passphrase `fixture-passphrase-1`), and `manifest.json`
mapping scenario roles to task ids.

| Folder | Schema it captures |
|---|---|
| `v0.1.1` | The first schema: no Critical flag, no completion date. |
| `v0.1.2` | Adds `needsImmediateAttention`. |
| `v0.1.8` | Renames it to `isCritical`; adds `completedAt`. |
| `v0.1.12` | Adds `notesRich`. Occurrences are virtual, with per-day override records, including an override and a skip for the same day. |
| `v0.1.15` | Adds `templateID`. Occurrences are materialized and include moved, listed, renamed, deleted, and orphaned ones, plus a series moved into a list. |

**How they were made.** Every fixture was written by a standalone command-line
tool built from byte-exact copies of that tag's model, backup, and recurrence
sources (`git show <tag>:<path>`). Each tool uses the release's own container
schema, its own `RecurrenceMaterializer`, and its own `BackupService`. None of the
tools ever open a user store. `LegacyFixtureMigrationTests` reads the ground
truth straight from these SQLite files.
