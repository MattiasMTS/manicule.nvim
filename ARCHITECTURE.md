# Architecture

manicule.nvim stores persistent review comments for Neovim buffers. A
comment is anchored by URI and range, rendered with extmarks and floating
popups, listed through quickfix, and optionally sent to an external sink.

The plugin is local-first. There is no hosted service or network broker.
Project comments use a local SQLite database in WAL mode; session comments
for unrooted and special buffers use a small file store under Neovim state.

## Design Principles

- URI identity is the source of truth. Buffers, quickfix entries, and sinks
  all resolve back to records keyed by `uri`.
- Rendering is disposable. Extmarks and popups are rebuilt from persisted
  records whenever needed.
- Storage is local and durable. Project records are transactionally written
  to SQLite; same-project Neovim sessions discover changes by polling the
  event log.
- External systems are sinks, not dependencies. Clipboard and cmux are
  integrations layered on top of the core record model.

## Module Map

```text
plugin/manicule.lua          commands and <Plug> maps
lua/manicule/init.lua        public API, autocmd wiring, lifecycle events
lua/manicule/config.lua      defaults and validation
lua/manicule/adapter.lua     buffer identity and diff/staged-buffer handling
lua/manicule/uri.lua         canonical URI helpers
lua/manicule/store.lua       project/session persistence facade
lua/manicule/sqlite.lua      minimal LuaJIT FFI SQLite wrapper
lua/manicule/anchor.lua      shared extmark namespace
lua/manicule/ui.lua          prompt and sink picker facade
lua/manicule/ui/editor.lua   floating comment editor
lua/manicule/ui/render.lua   extmarks, popups, viewport rendering
lua/manicule/ui/quickfix.lua quickfix formatting and refresh
lua/manicule/sinks/          sink registry and bundled sinks
```

`init.lua` lazy-requires most modules so command/key based lazy-loading has
minimal startup cost. Setup still needs to run early enough to register buffer
autocmds; README recommends `BufReadPost` / `BufNewFile`.

## Record Identity

The persisted record shape is:

```lua
{
  id = "unique",
  uri = "file:///abs/path.lua",
  scope = "project", -- or "session"
  project_root = "/abs/path/to/root", -- nil for session records
  range = { start = { row, col }, end_ = { row, col } },
  body = "text",
  author = "user@example.com",
  created_at = 1731000000,
  updated_at = 1731000000,
  resolved = false,
  meta = {},
}
```

`adapter.identify(bufnr)` owns the question "where should comments on this
buffer live?". It returns a URI, scope, project root, writability, and optional
diff-side metadata.

Important identity cases:

- Normal file in a project: `scope = "project"`, `project_root` from
  `vim.fs.root(bufnr, store.root_markers)`.
- Unrooted file or allowed special buffer: `scope = "session"`.
- Quickfix, prompt, and command-line-window buffers: rejected for adds.
- Diff views: comments are accepted only on the writable side when the pair can
  be identified.
- Runtime-staged paths under `stdpath("run")`: reverse-mapped back to the real
  project file when possible, otherwise rejected with a diagnostic notify.

`M.add` re-runs `adapter.identify` immediately before persisting and refuses to
write if the URI changed. That catches regressions where add-time and
reload-time identities would diverge.

## Rendering

`ui/render.lua` is the only module that owns visual state. For each visible
record it keeps one handle containing:

- a primary extmark for anchoring and line-number highlighting
- additional decoration extmarks for multi-line ranges
- an optional popup buffer/window

`render.reconcile(bufnr, records)` is idempotent. It creates or updates handles
for live records and clears handles whose record disappeared. Viewport mode
then calls `render.update_viewport_popups(bufnr, records)` to show popups only
for currently visible lines. Sticky mode renders every popup.

Popups are intentionally transient. `BufLeave` and `WinLeave` hide them to
avoid leaking floats across windows. The comment editor is a special case:
opening it moves focus into a manicule float, so the leave handler skips that
single transition to keep existing comment popups visible while typing.

Same-line comments stack vertically by popup height and show their stack
position in the title, for example `cabc 2/3`.

## Storage

All persistent files live under:

```text
stdpath("state")/manicule/
```

Project stores are named from the escaped project root:

```text
<escaped-root>[%%<branch>].sqlite3
```

Session stores use:

```text
session.<format>
```

`store.branch = true` appends the current git branch to the project store name
except for `main` and `master`. The default is `false` because comments are
treated as content annotations rather than branch-local editor state.

### Project SQLite

Project stores use two main tables:

```sql
records(root, id, data, deleted_at, updated_at)
events(id, root, record_id, kind, payload, client_id, created_at)
```

`records` is the current projection. `events` is an append-only local event log.
Writes run in `BEGIN IMMEDIATE` transactions with WAL enabled.

Each store client keeps a base snapshot from its last load. On save it diffs the
local record against that base and writes only locally changed fields. If
another Neovim session changed a different field first, the save reads the
current projection and applies only the local field patch. Deletes are
tombstones and take precedence over stale updates.

Clean caches poll `MAX(events.id)` and reload the projection when a newer event
appears. Dirty caches wait until their local save completes.

### Session Files

Session records use:

```lua
{ version = 1, records = { ... } }
```

The payload is encoded as `mpack` by default or JSON when
`store.format = "json"`.

## Main Flows

### Add

```text
M.add
  -> resolve range
  -> ui.prompt / ui.editor.open
  -> adapter.identify
  -> build record
  -> store.put_record + save
  -> render reconcile + viewport refresh
  -> User ManiculeAdded
```

### Reload / Attach

```text
BufReadPost / BufWinEnter
  -> adapter.identify
  -> store.load / store.session_load
  -> store.all_for_uri
  -> render.reconcile
  -> render.update_viewport_popups
```

### Edit / Delete / Resolve

Mutations find the record by explicit locator, current buffer project, loaded
project caches, then session store. After persistence, loaded buffers reconcile
from the store. Delete also refreshes viewports immediately so remaining popups
do not wait for cursor movement.

### Jump

`M.jump("next"|"prev")` is current-buffer scoped. It attaches the buffer,
collects records for the buffer URI, resolves live extmark positions when
available, and moves the cursor to the nearest matching comment without using
quickfix.

### Send

```text
M.send
  -> M.list(filter)
  -> sinks.dispatch(name, records, ctx, cb)
  -> User ManiculeSent
  -> optional clear_on_success deletes sent records
```

## Events

Events are native `User` autocmds.

| Pattern              | Data shape |
| -------------------- | ---------- |
| `ManiculeAdded`      | record |
| `ManiculeEdited`     | record |
| `ManiculeDeleted`    | `{ id, record }` |
| `ManiculeResolved`   | record with `resolved = true` |
| `ManiculeSent`       | `{ sink, count, ok, err }` |
| `ManiculeSynced`     | `{ roots }` |
| `ManiculeOrphaned`   | `{ id, record }` |
| `ManiculeRenamed`    | `{ bufnr, old_uri, new_uri, record_count, ids }` |
| `ManiculeVisibility` | `{ hidden = boolean }` |

## Extension Points

Sinks are the stable extension point:

```lua
require("manicule").register_sink({
  name = "tool",
  label = "Tool",
  pre_text = "Optional text before formatted comments.",
  post_text = "Optional text after formatted comments.",
  clear_on_success = false,
  validate = function(ctx) return true end,
  send = function(comments, ctx, cb) cb(true) end,
})
```

Sinks should use `lua/manicule/sinks/helpers.lua` for shared formatting where
possible, including the optional `pre_text` and `post_text` wrappers for text
payloads. Tests should exercise sinks with local fakes, not real network calls.

## Tests

`make test` runs the headless `mini.test` harness. The suite uses ephemeral
state directories and throwaway project roots with `.git` markers.

- `tests/manicule/`: module-level behavior, store persistence, adapter identity,
  picker routing, sink selection.
- `tests/integration/`: real workflows with buffers, floating windows, quickfix,
  render lifecycle, fake prompts, fake sinks, and lifecycle events.

The test policy is integration-first when behavior crosses Neovim surfaces.
Mocks are avoided except for costly or external systems.

## Non-Goals

- Hosted storage or network sync.
- Multi-user realtime collaboration.
- Threads, replies, or reactions.
- A pluggable render backend.
- Fuzzy re-anchoring by line text.
