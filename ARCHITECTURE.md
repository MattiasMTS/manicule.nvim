# Architecture

## 1. Overview

manicule.nvim pins free-form comments to arbitrary buffer ranges via
Neovim extmarks, persists them to a per-project file under Neovim's
state directory, and dispatches them to pluggable **sinks** (clipboard,
PR drafts, chat webhooks, …). The core is intentionally lightweight:
zero background work, every state transition is user-action or autocmd
driven.

The extmark anchors the comment and tints the line number via
`ManiculeLineNr` (default-linked to `DiagnosticSignInfo`). All other UI
(per-comment floating popups, the editor) lives in `lua/manicule/ui/`.
Popups are rendered either **sticky** (always shown for every record in
the buffer) or **viewport-driven** (only shown for records whose line is
currently on screen). The behaviour is selected by the `ui.sticky` config
knob and defaults to viewport-driven.

## 2. Module map

```
                        ┌──────────────────┐
                        │ plugin/manicule  │  ← commands + <Plug> maps
                        └────────┬─────────┘
                                 │
                                 ▼
   ┌───────────┐          ┌──────────────┐          ┌───────────┐
   │ config.lua│◄─────────┤  init.lua    ├─────────►│  id.lua   │
   └───────────┘          │ (public API) │          └───────────┘
                          └──┬────┬────┬─┘
                             │    │    │
          ┌──────────────────┘    │    └──────────────────┐
          ▼                       ▼                       ▼
   ┌────────────┐          ┌────────────┐          ┌─────────────┐
   │ anchor.lua │          │  store.lua │          │   ui.lua    │
   │ (extmarks) │          │ (mpack I/O)│          │ (facade)    │
   └────────────┘          └────────────┘          └──────┬──────┘
                                 │                        │
                                 ▼                        ▼
                          ┌──────────────┐       ┌────────────────┐
                          │  sinks/init  │       │ ui/ submodules │
                          │  (registry)  │       │  editor.lua    │
                          │      │       │       │  render.lua    │
                          │      ▼       │       │  quickfix.lua  │
                          │ clipboard.lua│       └────────────────┘
                          └──────────────┘

                  handlers.lua  ← STUB (v2 render handlers)
```

`init.lua` lazy-requires everything it needs; users with a `cmd = {...}`
lazy spec pay no startup cost.

### UI layer

The `ui/` submodule hosts the floating-window comment editor, the
per-comment popup renderer, the quickfix formatter, and a small shared
float primitives module — all ported from `codediff.nvim` (PR #332) and
trimmed to fit manicule's buffer-agnostic model.

- `ui/float.lua` — shared float primitives used by both the editor and
  the popup renderer: `create_scratch_buf`, `open_or_reconfigure`,
  `apply_title_footer`, `set_float_win_options`.
- `ui/editor.lua` — scratch-buffer floating window with a title,
  footer hint, configurable submit/cancel keys, and winblend. Entry
  point is `editor.open({ title, default, anchor_pos, cfg }, cb)`.
  Only one editor is live at a time.
- `ui/render.lua` — per-comment floating popups anchored to each
  commented line. `reconcile(bufnr, records)` is idempotent: it
  creates / updates / tears down an anchor extmark + popup per record,
  stack-offsetting multiple comments on the same line. Sticky mode
  (`ui.sticky = true`) keeps popups up for every record; viewport mode
  (`ui.sticky = false`, the default) shows popups only for records
  whose line is currently visible, via `update_viewport_popups`.
  Public API: `setup`, `refresh_highlights`, `reconcile`,
  `update_viewport_popups`, `hide_all_popups`,
  `capture_position_patches`, `clear_buffer`, `clear_all`,
  `winhighlight`, `mark_ids_for_buffer`.
- `ui/quickfix.lua` — formats records into quickfix items
  (`[ ]`/`[x]` + line range + truncated first line of the body) and
  delegates to `setqflist` + `copen`. Replaces the raw quickfix call
  that lived in `init.list`.

`lua/manicule/ui.lua` stays as a thin facade: `prompt` hands off to
`ui/editor`, `select_sink` still uses `vim.ui.select`.

## 3. Data flow: add comment

```
  user
   │  :ManiculeAdd   (or <Plug>(manicule-add))
   ▼
plugin/manicule ──► init.add(opts)
                      │
                      ├─ resolve_range() ──────► {start, end_}
                      │
                      ├─ ui.prompt() ──► ui.editor.open(cfg) ──► body (async cb)
                      │
                      ▼
                    finalize_add(body, bufnr, range)
                      │
                      ├─ id.new() ─────────────────────► record.id
                      ├─ store.put(root, record)
                      ├─ store.save(root)  (atomic tmp+rename)
                      ├─ ui.render.reconcile(bufnr, records) ──► extmark + popup
                      │
                      └─ nvim_exec_autocmds("User",
                           { pattern = "ManiculeAdded", data = record })
```

## 4. Data flow: reload

```
  BufReadPost / BufWinEnter
         │
         ▼
   init.reconcile_buffer(bufnr)
         │
         ├─ store.root()        (vim.fs.root(store.root_markers) || cwd fallback)
         ├─ store.load(root)    (fills module-local cache[root])
         ├─ relpath_for_buf()   (vim.fs.relpath, fallback prefix strip)
         │
         ├─ records = store.for_path(root, relpath)
         ├─ ui.render.reconcile(bufnr, records)
         │     └─ for each record: create/refresh anchor extmark and
         │        (sticky) popup, prune handles that no longer appear
         │        in `records`.
         │
         └─ for any extmark that came back invalid:
              nvim_exec_autocmds("User",
                { pattern = "ManiculeOrphaned",
                  data = { id, record } })
```

Viewport / scroll / resize events fan out to
`render.update_viewport_popups(bufnr, records)` when `ui.sticky` is
false. `BufLeave` / `WinLeave` call `render.hide_all_popups(bufnr)` so
stale popups don't leak across windows. Every handler is wrapped in
`vim.schedule` so a burst of autocmds coalesces into one render pass.

Setup must run before the first `BufReadPost` you want rendered, so
users lazy-loading via `cmd`/`keys` alone will miss the initial attach
sweep; use `event = { "BufReadPost", "BufNewFile" }` as the trigger.

## 5. Data flow: send

```
  :ManiculeSend clipboard
         │
         ▼
   init.send(sink_name, filter, ctx)
         │
         ├─ list(filter)  (vim.iter over store.all(root); _quiet = true)
         │
         ├─ sinks.dispatch(sink_name, records, ctx, cb)
         │     └─ sinks[name].validate?(ctx)
         │     └─ sinks[name].send(records, ctx, cb)
         │            └─ (e.g. clipboard.send → vim.fn.setreg("+", ...))
         │
         └─ cb(ok, err)
              └─ nvim_exec_autocmds("User",
                   { pattern = "ManiculeSent",
                     data = { sink, count, ok, err } })
```

## 6. Persistence

The store lives under `stdpath("state") .. "/manicule/"` (overridable
via `store.dir`), one file per project root. The root is resolved with
`vim.fs.root(0, store.root_markers)` — defaults to `{".git", ".hg",
"package.json"}`. The filename is the root path with `[\\/:]+` collapsed
to `%%` (same trick persistence.nvim uses), so
`/Users/me/src/foo`  → `%Users%me%src%foo.mpack`. Keying by the git root
rather than `getcwd()` means comments survive `cd`'ing into subdirs.

The on-disk payload is a bare array of record tables — no wrapper
envelope — encoded with `vim.mpack.encode` by default; `store.format =
"json"` switches to `vim.json.encode` for users who want a human-readable
file. mpack is the default because nothing human reads these files
anymore (they live under `stdpath('state')`, not the repo), and mpack
is smaller, faster, and handles Lua `nil`/array cases without JSON's
coercion quirks.

Writes go through a tmp-then-rename dance — `vim.uv.fs_write` to
`<path>.tmp`, then `vim.uv.fs_rename` into place — so a mid-write crash
never truncates the existing store. If the on-disk file is corrupt the
loader `pcall`s the decode, logs a `WARN` notification, and starts from
an empty record list rather than crashing.

**Unrooted buffers.** If `vim.fs.root` returns nil (e.g. a scratch
`/tmp/foo.txt`) `store.root()` returns nil and every write no-ops. Users
who *do* want to persist notes in unrooted contexts can set
`store.persist_unrooted = true`, which falls back to `vim.fn.getcwd()`
as the key. The default is off to avoid scattering files under
`stdpath('state')/manicule/` for every random file opened outside a
project.

**Branch scoping (opt-in).** `store.branch = true` appends the current
git branch to the filename (`<escaped-root>%%<escaped-branch>.mpack`) so
notes are scoped per-branch. `main` and `master` collapse back to the
unsuffixed filename — the common case doesn't fragment and branch
creation doesn't suddenly hide existing notes. Branch lookup runs
`git -C <root> branch --show-current`, guarded by `uv.fs_stat(root ..
"/.git")`. The default is `false` because annotations are content
anchors, not editing state; users who want them to follow branches can
opt in.

## 7. Anchoring strategy

Each record owns exactly one extmark in the shared namespace
`manicule`, created with `invalidate = true` and `undo_restore = false`.
When the anchor line(s) are deleted, Neovim flags the extmark as
`invalid` for us for free — we do not maintain a parallel liveness
table. On buffer reload, records for the buffer's project-relative path
are re-anchored to their stored `range` by `ui/render.lua`; if the
re-attached mark comes back `invalid` immediately (e.g. the file has
been truncated below the stored row), a `User ManiculeOrphaned` autocmd
is fired with the record.

The extmark tints the line number via `ManiculeLineNr` so commented
lines are visually distinct; everything else is drawn by `ui/render.lua`.
Each extmark is paired with a floating popup positioned against the
anchor window, titled `c<short-id>` and footered with the edit/delete
hint. Multiple popups on the same line stack vertically, ordered by
record id. `number_hl_group` only tints the start line — multi-line
ranges do not tint intermediate line numbers, matching codediff.

## 8. Event catalog

All events are native `User` autocmds — subscribe with
`nvim_create_autocmd`, inspect `ev.data`.

| Pattern            | Fired when                                 | `ev.data` shape                     |
| ------------------ | ------------------------------------------ | ----------------------------------- |
| `ManiculeAdded`    | `M.add` finishes persisting a new record   | full record                         |
| `ManiculeEdited`   | `M.edit` updates a body                    | full updated record                 |
| `ManiculeDeleted`  | `M.delete` removes a record                | `{ id, record }`                    |
| `ManiculeResolved` | `M.resolve` marks a record resolved        | record (with `resolved = true`)     |
| `ManiculeSent`     | `M.send` sink dispatch settles             | `{ sink, count, ok, err }`          |
| `ManiculeOrphaned` | reload detects an extmark is invalid       | `{ id, record }`                    |

## 9. Extension points

- **Sinks** (primary, stable): register via `require("manicule").register_sink(spec)`.
  A spec is `{ name, send(comments, ctx, cb), format?, validate? }`.
  See `lua/manicule/sinks/clipboard.lua` for a reference adapter.
- **handlers.* (v2)**: `lua/manicule/handlers.lua` sketches
  `signs` / `virtual_text` / `float` entries shaped like
  `vim.diagnostic.handlers`. Wiring them into a real render pass is a
  v2 item.

## 10. Non-goals (for now)

- Multi-user / real-time sync.
- Threading, replies, or reactions.
- SQLite or any structured-storage backend.
- A pluggable display-handler system. Rendering lives in
  `ui/render.lua` and is opinionated around floating popups; the
  `handlers.lua` stub is kept as a sketch of where a user-facing
  handler API could land, but it is not wired.
- (Done — see UI layer above.) The floating-window comment editor has
  replaced the v0 single-line `vim.ui.input` prompt.
- Matching saved records by line text. v1 re-anchors by saved
  row/col and lets `invalidate` flag orphans.
- Multi-line comment prompts are now available via the floating
  editor at `lua/manicule/ui/editor.lua` — the old note about
  single-line-only has been resolved.
