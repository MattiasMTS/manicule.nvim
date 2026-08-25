# Architecture

manicule.nvim stores persistent review comments for Neovim buffers. A
comment is anchored by URI and range, rendered with extmarks in one of four
display modes (floating popups, eol virtual text, inline boxes, or hidden
anchors), listed through quickfix, and optionally sent to an external sink.

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
plugin/manicule.lua             commands and <Plug> maps
lua/manicule/init.lua           public API, autocmd wiring, lifecycle events
lua/manicule/config.lua         defaults and validation
lua/manicule/adapter.lua        buffer identity and diff/staged-buffer handling
lua/manicule/uri.lua            canonical URI helpers
lua/manicule/store.lua          project/session persistence facade
lua/manicule/sqlite.lua         minimal LuaJIT FFI SQLite wrapper
lua/manicule/anchor.lua         shared extmark namespace
lua/manicule/ui.lua             prompt and sink picker facade
lua/manicule/ui/editor.lua      floating comment editor
lua/manicule/ui/render.lua      extmarks, display modes, popups, viewport rendering
lua/manicule/ui/quickfix.lua    quickfix formatting and refresh
lua/manicule/review.lua         review session core (start/open/next/prev/finish/stop)
lua/manicule/review/git.lua     git plumbing (rev-parse, merge-base, changed files, staging)
lua/manicule/review/inline.lua  unified-mode diff paint (virtual lines, folds, hunk nav)
lua/manicule/review/sources.lua resolver registry (dirs, git ref, pr via gh CLI)
lua/manicule/sinks/             sink registry and bundled sinks (clipboard, cmux, github, socket)
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
- optional sibling decoration extmarks for the eol marker / inline box block
- an optional popup buffer/window

Both entry points dispatch on the display mode. `render.reconcile(bufnr,
records)` is idempotent: it creates or updates handles for live records,
clears handles whose record disappeared, and decides per mode what a record
gets beyond its anchor extmark. `render.update_viewport_popups(bufnr,
records)` owns the transient popups: under `float` it shows popups for
viewport lines (or every line when `ui.sticky`), under `eol` its visibility
test becomes the cursor line, and under `inline`/`hidden` it tears every
popup down.

The mode is split state: `config.get().ui.display` is only the startup
default (`"eol"`); runtime switches (`:ManiculeDisplay` /
`render.set_display_mode`, cycle order float → eol → inline → hidden) live
in module state, in-memory, reset on restart. A switch repaints every
loaded buffer through the same reconcile + viewport-refresh path `show()`
uses.

Per mode:

- `eol`: reconcile puts a sibling decoration extmark on each record's
  anchor line carrying the collapsed `● c<short-id> n/m · body` virt-text
  marker, truncated to the leftover window width (`n/m` = same-line stack
  position, omitted for singles). Markers render for every record —
  viewport/sticky gating is a float concern. The full popup expands while
  the cursor covers the record: `CursorMoved` feeds init.lua's coalesced
  viewport refresh, and the viewport pass renders popups for cursor-line
  records instead of viewport lines.
- `inline`: each commented line renders ONE `virt_lines` block of bordered
  boxes below the anchor, owned by the stack head's handle and ordered by
  `record_stack_less` — code is pushed down, never covered. No popups ever;
  the box already shows the full body and footer, and edit/delete stay
  reachable through `record_at_cursor`.
- `float`: anchored popups with occlusion-aware placement — the
  right-margin spot is used only when every buffer line the popup would
  span leaves it on genuinely empty cells (measured by `strdisplaywidth`),
  otherwise the whole same-line stack falls back below the anchor (above
  when the window bottom leaves no room), never split between placements.
  Eol's expanded popups reuse this path.
- `hidden`: anchor extmarks and line-number tint only.

Float popups and inline boxes share `build_popup_content` (title with short
id + counter, body fitted to a width cap, date/actions footer). Floats
ellipsis-truncate each body line; inline word-wraps instead, since there is
no expanded popup left to reveal the rest.

`config.ui.expand` picks where eol's cursor expansion renders (read at
dispatch time, config-at-setup): `"float"` (default) takes the popup path
above; `"rail"` makes the viewport pass hand the cursor-line records to
`ui/rail.lua` instead — a real `vertical botright` window on the far
right, so covering code is structurally impossible and the occlusion
placement never runs. The rail owns its window, scratch buffer
(`manicule://rail`, `bufhidden=wipe`), and lifecycle augroup; render.lua
owns the cards — `render._rail_card_rows` returns the inline box's
`[text, hl]` chunk rows, and the rail only materializes them into buffer
lines + highlight extmarks, aligned so the first card's top row sits at
the anchor line's screen row. An uncommented cursor line clears the cards
but keeps the window; the rail closes when the display mode leaves eol,
the buffer's records disappear, or the code window closes.

Popups are intentionally transient. `BufLeave` and `WinLeave` hide them to
avoid leaking floats across windows. The comment editor is a special case:
opening it moves focus into a manicule float, so the leave handler skips that
single transition (in every mode) to keep the record's popup visible while
typing.

Same-line comments stack vertically by popup height. The popup/box title
counter (for example `cabc 2/3`) is the record's position among its scope's
comments; the eol marker's `n/m` is the same-line stack position.

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

## Review Mode

`:ManiculeReview` opens a diff-review session over file pairs (baseline left,
worktree right). One active session at a time, in its own tab page.

**Session core** (`lua/manicule/review.lua`):
- Right side: real worktree file where it exists; comments anchor natively.
- Left side: read-only staged baseline copy (modifiable=false, readonly=true,
  bufhidden=wipe, swapfile=false).
- Diff rendering is chosen by `review.mode`; `:ManiculeReviewDiffMode`
  flips it and re-opens the current index.
  - `split` (default): `:diffsplit` pairs (left split beside right).
  - `unified`: one window on the worktree file, diff painted inline (below).
- Deleted files: left-only display, notify that comments are file-level notes.
- Navigation: `next()`/`prev()` wrap around.
- Panel (`lua/manicule/review/panel.lua`): auto-opens bottom quickfix window
  on session start. Files view (default) shows `[status] path  (N comments)`
  with live counts refreshing on `User Manicule*` events; `<CR>` calls
  `review.open(idx)` to switch pairs. `<Tab>` toggles to comments view
  (session-scoped `M.list` with standard quickfix formatting/mappings). Panel
  closed on `stop()`, autocmds cleaned up.
- `finish()`: collects session comments via URI filter, dispatches to
  configured sink; auto-flushes on `VimLeavePre` when sink is configured and
  comments exist.

**Unified mode** (`lua/manicule/review/inline.lua`):
- Paints the diff ONTO the real worktree buffer instead of building a
  synthetic `git diff` document. That choice is load-bearing: records are
  keyed by worktree URI and store ranges in worktree line coordinates
  (`adapter.identify`, `sinks/helpers.line_span`), so a separate diff
  buffer would need a diff↔file mapping at four seams — `finalize_add`,
  `render_extmark`, `capture_position_patches`, and the `record.range`
  fallback in `comment_position` — where one miss silently persists a
  comment against the wrong line. Painting the file keeps all four exact.
- `vim.diff(..., { result_type = "indices" })` against the staged
  baseline. Added lines get `line_hl_group = ManiculeDiffAdd`; removed
  lines become `virt_lines` (above their replacement, or below the line
  they followed for a pure deletion). Empty baseline/buffer content is
  normalised to `""` so an added file diffs as a clean all-add.
- Own namespace (`manicule_review_inline`), separate from `anchor.ns`, and
  priority 100 so comment anchors (220) still tint their line number.
- Unchanged regions fold via a `foldexpr` over the kept-row set
  (`review.context` lines around each hunk). Window options are saved
  before the first change and restored by `clear()`, since the worktree
  buffer outlives the session tab.
- Removed lines are virtual, so they are not commentable — the same
  restriction split mode has on its read-only baseline side.
- `]h` / `[h` navigate hunks; both maps are buffer-local and removed on
  `clear()`. `review.open()`/`stop()` call `clear_all()`.

**Resolver registry** (`lua/manicule/review/sources.lua`):
- Turns `:ManiculeReview` arguments into staged file pairs.
- Builtin resolvers: `<dirL> <dirR>` (walks dirR, pairs by rel-path, content
  diff), `<git-ref>` (merge-base vs HEAD, shows only your changes), bare
  (defaults to `HEAD`), `pr <n>` (via `gh pr view --json`, shells to gh CLI).
- `register(resolver)` prepends to registry → user resolvers shadow builtins.
- All resolvers return `{files: [{left, right, status, path}], label}`.
- `pr <n>` with the head checked out also imports existing PR review comments
  (`lua/manicule/review/import.lua`): `gh api .../pulls/<n>/comments --paginate`
  → project records with `meta.github = {id, url, imported = true}`. Best-effort
  (failure → WARN, review still opens), deduped on `meta.github.id`, skipped
  entirely on the both-sides-staged path. Imported records are excluded from
  `finish()` (`M.list`'s `exclude_imported` filter) and skipped by the github
  sink so GitHub's own comments are never echoed back.

**GitHub sink** (`lua/manicule/sinks/github.lua`): posts the batch as a PR
review via `gh api` (PR from `ctx.pr` or `gh pr view`, repo from
`gh repo view`; argv-only, JSON body via `--input` temp file; registers only
when `gh` is executable; `clear_on_success = false` by default).

**Socket sink** (`lua/manicule/sinks/socket.lua`):
- Generic JSONL-over-unix-socket transport; bundled, enabled by default.
- Protocol: `hello` (pid, job id) → `submit` (label, comments array) ← `ack`.
- Comments serialized as `{path, lnum, end_lnum, body, side: "working"}`;
  paths project-relative when `project_root` present, line numbers 1-based.
- Timeout: 2000ms default for ack; on connect/write/ack failure, writes
  `submit.json` fallback next to socket path so comments are never lost.
- `clear_on_success = true` (records deleted after consumer acks).

**Driver contract** (`start_from_job`):
- External tools (coding-agent extensions, scripts) write a job JSON file:
  `{id, label, return_socket, files: [{left, right, status, path}]}`.
- `require("manicule.review").start_from_job(path)` reads it, starts the
  session, wires the socket sink.
- Comments flow back via the socket; the driver composes feedback however it
  wants (insert into editor, post to PR, etc).

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
- Threads, replies, or reactions in the core record model. GitHub thread
  interactions (replies, resolve/unresolve) exist, but they live entirely in
  the sink/meta layer (`meta.github`, `meta.github_reply`) — the record
  schema itself stays flat and host-agnostic.
- A pluggable render backend.
- Fuzzy re-anchoring by line text.
