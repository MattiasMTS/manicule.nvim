# Architecture

## 0. Phased roadmap

manicule is being rewired around a URI-based record identity to unblock
cross-scope storage. The phases land incrementally so each drop keeps
the plugin usable end-to-end.

- **Phase 1 (complete).** Records key off `(scope, project_root, uri)`
  instead of `(project_root, project-relative-path)`. `scope` is always
  `"project"`; `BufFilePost` rewrites URIs when files are renamed via
  `:saveas` / `:file` and fires a `User ManiculeRenamed` autocmd.
- **Phase 2 (complete).** A diff-mode adapter (`lua/manicule/adapter.lua`)
  recognises `nvim -d` / `git difftool -t nvimdiff` pairs by matching
  buffer paths against a temp-prefix list (`/tmp`, `/var/folders/...`,
  `/private/...`). Comments anchor to the working-tree URI and `M.add`
  rejects the reference side with a notify. Plain `nvim -d a.lua b.lua`
  with two real paths leaves each buffer as its own identity.
- **Phase 3 (complete).** A session-scoped store (`session.<format>`
  under `stdpath('state')/manicule/`) for unrooted buffers and special
  buftypes (`term://`, scratch, `nofile`, `acwrite`, `help`, …).
  `persist_unrooted` defaults to `true`. Adds on quickfix, prompt, and
  cmdwin buffers still reject with a notify. Project and session
  records merge transparently in `store.all_for_uri` / `M.list`; the
  caller never branches on scope.

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
                                 ▲                        │
                                 │                        ▼
                          ┌──────┴───────┐       ┌────────────────┐
                          │ adapter.lua  │       │ ui/ submodules │
                          │  (identity)  │       │  editor.lua    │
                          └──────────────┘       │  render.lua    │
                                 ▲               │  quickfix.lua  │
                                 │               └────────────────┘
                          ┌──────┴───────┐
                          │  sinks/init  │
                          │  (registry)  │
                          │      │       │
                          │      ▼       │
                          │ clipboard.lua│
                          │ cmux.lua     │
                          │ helpers.lua  │
                          └──────────────┘

```

Identity flow (phase 2):

```
  bufnr ──► adapter.identify()
              │
              ├─ uri_mod.for_bufnr(bufnr)
              ├─ in_cmdwin()?        → reject (session, not writable)
              ├─ buftype == ""?      → resolve_diff_pair(bufnr)
              │     │
              │     ├─ reference side: return working URI,
              │     │                  is_writable=false, diff_side="reference"
              │     └─ working side / no pair: continue
              │
              ├─ vim.fs.root(bufnr, markers) matches? → scope="project", writable
              └─ fall through           → scope="session"
                                          (writable iff buftype policy allows)
```

`init.lua` lazy-requires everything it needs; users with a `cmd = {...}`
lazy spec pay no startup cost.

### UI layer

The `ui/` submodule hosts the floating-window comment editor, the
per-comment popup renderer, the quickfix formatter, and a small shared
float primitives module. The UI is intentionally buffer-agnostic: every
surface works from record identity and buffer URI rather than a diff-only
model.

- `ui/float.lua` — shared float primitives used by both the editor and
  the popup renderer: `create_scratch_buf`, `open_or_reconfigure`,
  `apply_title_footer`, `set_float_win_options`.
- `ui/editor.lua` — scratch-buffer floating window with a title,
  footer hint, configurable submit/cancel keys, and opacity. Entry
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
  that lived in `init.list`. Tags each item with its record id via
  `user_data`, caches the filter used so `refresh()` can regenerate
  the list in place, and exposes `record_id_at_cursor()` +
  `is_manicule_qf_open()` for the keymap and event wiring.
- `ui/quickfix_keymaps.lua` — buffer-local `dd` / `ce` for manicule
  quickfix buffers only. Attached by a `FileType qf` autocmd (and
  re-attached on every `:copen` to honour runtime flag toggles).
  Opt-out via `vim.g.manicule_no_default_keymaps = 1`.
- `ui/picker.lua` — `vim.ui.select` picker backing no-arg invocations
  of `:ManiculeEdit` / `:ManiculeDelete` / `:ManiculeResolve`. Formats
  each record as `<n> │ <path>:<line> │ <body…>`, consumes the same
  sorted output from `init.list` that `ui/quickfix` does so positional
  completion numbers and picker rows stay 1:1.

`lua/manicule/ui.lua` stays as a thin facade: `prompt` hands off to
`ui/editor`, and `select_sink` auto-selects a single sink or delegates
multiple choices to `ui.sink_picker` / `vim.ui.select`.

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
        ├─ adapter.identify(bufnr)       (URI + target-buffer project root)
        ├─ store.load(root)              (fills module-local cache[root])
        ├─ manicule.uri.for_bufnr(bufnr) (fs_realpath, passthrough, or ephemeral URI)
        │
        ├─ records = store.all_for_uri(uri, root)
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
stale popups don't leak across windows. `BufFilePost` triggers
`init.on_bufname_changed(bufnr)`, which rewrites every record anchored
in the buffer to the buffer's new URI, marks the store dirty, saves,
and fires a single `User ManiculeRenamed` autocmd (`{ bufnr, old_uri,
new_uri, record_count, ids }`). Every handler is wrapped in
`vim.schedule` so a burst of autocmds coalesces into one render pass.

Setup must run before the first `BufReadPost` you want rendered, so
users lazy-loading via `cmd`/`keys` alone will miss the initial attach
sweep; use `event = { "BufReadPost", "BufNewFile" }` as the trigger.

## 5. Data flow: send

```
  :ManiculeSend [clipboard]
         │
         ▼
   init.send(sink_name, filter, ctx)
         │
         ├─ no sink? ui.select_sink(cb)
         │     ├─ one sink       → cb(name)
         │     └─ multiple sinks → ui.sink_picker? / vim.ui.select
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

## 5a. Data flow: quickfix live refresh

The quickfix formatter does not drive any autocmds of its own. Instead
`init.setup` wires one `User Manicule*` autocmd that fires on add /
edit / delete / resolve / orphan, and a `FileType qf` autocmd that
attaches the buffer-local `dd` / `ce` keymaps. The refresh callback
checks whether a manicule-titled quickfix window is visible, and if so
calls `ui.quickfix.refresh`, which re-runs the cached filter through
`manicule.list(filter, _quiet=true)` and replaces the current list
with `setqflist({}, "r", ...)`. The title-prefix check (`"manicule"`)
runs again inside `refresh` so a user who swapped the qf to grep
results between event and refresh never gets their list clobbered.
The cursor row is captured before the replace and restored after
(clamped to the new list length) so `dd` lands the cursor on the next
entry naturally.

## 6. Persistence

The store lives under `stdpath("state") .. "/manicule/"` (overridable
via `store.dir`), one file per project root. The root is resolved with
`vim.fs.root(bufnr, store.root_markers)` — defaults to `{".git", ".hg",
"package.json"}`. The filename is the root path with `[\\/:]+` collapsed
to `%%` (same trick persistence.nvim uses), so `/Users/me/src/foo` →
`%Users%me%src%foo.mpack`. Keying by the git root rather than
`getcwd()` means comments survive `cd`'ing into subdirs.

### Record schema

```
{
  id           = "unique",                            -- id.new()
  uri          = "file:///abs/path.lua",              -- canonical URI
  scope        = "project",                           -- or "session"
  project_root = "/abs/path/to/root",                 -- nil for session records
  range        = { start = {row,col}, end_ = {row,col} },
  body         = "text",
  author       = "user@example.com",
  created_at   = 1731000000,
  updated_at   = 1731000000,
  resolved     = false,
  meta         = {},                                  -- free-form
}
```

`uri` is the canonical identity. `manicule.uri.for_bufnr` runs file
paths through `vim.uv.fs_realpath` before encoding so opening a file
via a symlink still matches records saved against the real path; set
`store.canonicalize_symlinks = false` to disable. Non-file URIs
(`term://`, `man://`, …) pass through untouched so the session-scoped
store can key off the same field directly.

### File layout

```
~/.local/state/nvim/manicule/
  ├─ <escaped-root>[%%<branch>].<format>   ← project-scope stores
  │   (one per project root)
  └─ session.<format>                      ← session-scope store
      (single file, shared across all unrooted / special buffers)
```

### On-disk layout

The on-disk payload is a versioned envelope:

```lua
{ version = 1, records = { ... } }
```

It is encoded with `vim.mpack.encode` by default; `store.format =
"json"` switches to `vim.json.encode` for users who want a
human-readable file. mpack is the default because nothing human reads
these files anymore (they live under `stdpath('state')`, not the repo),
and mpack is smaller, faster, and handles Lua `nil`/array cases without
JSON's coercion quirks. Legacy bare record arrays still load and are
rewritten as the current envelope on the next save. If the decoded
payload is neither a list nor a supported envelope the loader logs a
`WARN` notification and starts from an empty record list rather than
crashing.

Writes go through a tmp-then-rename dance — `vim.uv.fs_write` to
`<path>.tmp`, then `vim.uv.fs_rename` into place — so a mid-write crash
never truncates the existing store. If the on-disk file is corrupt the
loader `pcall`s the decode, logs a `WARN` notification, and starts from
an empty record list rather than crashing.

**Unrooted buffers + special buftypes.** When `vim.fs.root` returns
nil (e.g. `/tmp/foo.txt` with no git ancestor) or the buffer has a
special buftype (`terminal`, `help`, `nofile`, `acwrite`, `nowrite`),
records route to the session store instead. `persist_unrooted`
defaults to `true`; setting it to `false` makes unrooted *file*
buffers reject adds with a notify — special buftypes still route to
session regardless. Quickfix, prompt, and cmdwin buffers reject
unconditionally.
Unnamed buffers get a current-session-only `manicule://buffer/...` URI.
Those records remain available for list/send while the buffer exists,
but are omitted from `session.<format>` until `:file` / `:saveas`
rewrites them to a stable URI.

**Runtime-staged buffers.** Plugins (a `:DiffTool` command, a stash-
blob viewer, a review buffer, …) sometimes write content to
`<stdpath('run')>/<N>/<project-relative-path>` via `vim.fn.tempname()`
so the buffer has a unique file-backed identity. That directory's
`<run-id>` rotates every nvim launch, so the URI is useless the moment
the user restarts — the record can never re-anchor. `adapter.identify`
detects the path shape (anything containing
`/nvim.<user>/<run-id>/<N>/<suffix>`) before project resolution and
*reverse-maps* it:

1. Peel the `/nvim.<user>/<run-id>/<N>/` triplet from the path.
2. Resolve the remaining `<suffix>` against, in order:
   - `vim.fs.root(0, store.root_markers)` — the current project root /
     cwd fallback used by the reverse-map heuristic.
   - `vim.fn.getcwd()`.
   - `$HOME`, only when the suffix starts with `.` (dotfile/config).
3. Zero candidates that exist on disk → reject with
   `buffer is a nvim-runtime-staged path (<abs>); could not map to a
   real file`. Multiple candidates → reject with `ambiguous reverse-map;
   open the real file directly`. Exactly one → use
   `vim.uri_from_fname(fs_realpath(candidate))` as the identity URI.

Reverse-map runs on any buffer whose path looks nvim-runtime-staged,
including diff-mode ones: DiffToolGit-style commands stage BOTH sides
of a diff under `stdpath('run')`, leaving the diff-pair heuristic
unable to pick a working side (it needs exactly one "real" buffer),
so each buffer's URI has to be resolved independently. Reverse-map
operates on URIs while diff-pair keys off bufnrs + raw paths, so the
two code paths don't interfere. The root for reverse-mapped records
is resolved from the mapped path, not the staged buffer, so they land
in the correct project store.

One acceptable limitation: comments added from a DiffToolGit view
anchor to the real file's URI using the line numbers shown in the
view — which represent the *staged* file's content. For plain "old
vs new" diffs the newer side's line numbers approximate the working
tree well enough; for three-way or unusual diff setups lines may
drift. The alternative is refusing all diff-view comments, which is
worse UX.

Reads route through `adapter.identify` so staged buffers (e.g.
DiffToolGit) find the real project store; writes use the record's
stored `project_root` directly.

**`M.add` invariant canary.** After building a record, `M.add` re-runs
`adapter.identify(bufnr)` and refuses to persist when the returned URI
doesn't match the record's URI. Any divergence triggers an ERROR
notify (`manicule: URI invariant violated (expected <a>, got <b>:
<err>)`) and leaves the store untouched. Catches future regressions
where build-time and reload-time URIs drift apart.

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
record id. `number_hl_group` only tints the start line; additional decoration
extmarks tint the rest of a multi-line range.

## 8. Event catalog

All events are native `User` autocmds — subscribe with
`nvim_create_autocmd`, inspect `ev.data`.

| Pattern              | Fired when                                 | `ev.data` shape                     |
| -------------------- | ------------------------------------------ | ----------------------------------- |
| `ManiculeAdded`      | `M.add` finishes persisting a new record   | full record                         |
| `ManiculeEdited`     | `M.edit` updates a body                    | full updated record                 |
| `ManiculeDeleted`    | `M.delete` removes a record                | `{ id, record }`                    |
| `ManiculeResolved`   | `M.resolve` marks a record resolved        | record (with `resolved = true`)     |
| `ManiculeSent`       | `M.send` sink dispatch settles             | `{ sink, count, ok, err }`          |
| `ManiculeOrphaned`   | reload detects an extmark is invalid       | `{ id, record }`                    |
| `ManiculeRenamed`    | `BufFilePost` rewrote record URIs for a buffer | `{ bufnr, old_uri, new_uri, record_count, ids }` |
| `ManiculeVisibility` | `:ManiculeToggle` flips the visibility flag | `{ hidden = <bool> }`              |

## 9. Extension points

- **Sinks** (primary, stable): register via `require("manicule").register_sink(spec)`.
  A spec is `{ name, type?, label?, description?, send(comments, ctx, cb), format?, validate?, health?, clear_on_success? }`.
  Opt in with `clear_on_success = true` to have the core auto-delete
  every record in the batch after the sink's callback returns `ok = true`
  (`ManiculeSent` fires first, then one `ManiculeDeleted` per record).
  Built-ins are loaded by `manicule.sinks.setup`: `clipboard` is the
  generic sink, and `cmux` is an auto-enabled integration when the user
  is inside cmux. Community integrations should expose `setup(opts)`
  and use `lua/manicule/sinks/helpers.lua` for shared formatting so
  tests can exercise dispatch without real external services.

## 10. Test strategy

`make test` is the publishing gate. It runs `tests/minit.lua`, a direct
`mini.test` harness that bootstraps `mini.test` into `.tests/`, collects
all `tests/**/*_spec.lua` files, and executes them synchronously in
headless Neovim. The runner does not load the user's config, does not
depend on manual UI, and does not replace core Neovim APIs such as
`vim.fs.root`, `vim.fs.normalize`, or `vim.system`.

- Unit specs under `tests/manicule/` exercise module-level behavior:
  adapter identity, URI reverse-map, store persistence, picker routing,
  and sink selection.
- Integration specs under `tests/integration/` exercise user workflows:
  add → list → send, command dispatch, fake prompt input, fake sinks,
  sink `clear_on_success`, render visibility, real floating-window
  lifecycle, and `User Manicule*` events.
- `make test-unit` and `make test-integration` keep the two layers
  runnable independently when debugging failures.

Each helper setup creates one OS-temp artifact root containing both the
state dir and a throwaway project with a `.git` marker, then deletes the
whole tree during teardown. External integrations such as cmux should
stay behind local sink specs or ephemeral fake CLIs in tests; the suite
should not make network calls or depend on real external services. The
core contract to validate is that manicule selects the right comments,
passes the right context, emits the right events, and clears comments
only when the sink declares that policy.

## 11. Non-goals (for now)

- Multi-user / real-time sync.
- Threading, replies, or reactions.
- SQLite or any structured-storage backend.
- A pluggable display-handler system. Rendering lives in
  `ui/render.lua` and is opinionated around floating popups.
- (Done — see UI layer above.) The floating-window comment editor has
  replaced the v0 single-line `vim.ui.input` prompt.
- Matching saved records by line text. v1 re-anchors by saved
  row/col and lets `invalidate` flag orphans.
- Multi-line comment prompts are now available via the floating
  editor at `lua/manicule/ui/editor.lua` — the old note about
  single-line-only has been resolved.
