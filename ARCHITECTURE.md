# Architecture

## 1. Overview

manicule.nvim pins free-form comments to arbitrary buffer ranges via
Neovim extmarks, persists them to a per-project JSON file, and
dispatches them to pluggable **sinks** (clipboard, PR drafts, chat
webhooks, …). The core is intentionally lightweight: zero background
work, every state transition is user-action or autocmd driven, and the
extmark itself carries the display layer (sign + highlight) so v1 has
no parallel render pipeline.

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
   │ (extmarks) │          │ (JSON I/O) │          │ (vim.ui.*)  │
   └────────────┘          └────────────┘          └─────────────┘
                                 │
                                 ▼
                          ┌──────────────┐
                          │  sinks/init  │─► sinks/clipboard.lua
                          │  (registry)  │   (reference adapter)
                          └──────────────┘

                  handlers.lua  ← STUB (v2 render handlers)
```

`init.lua` lazy-requires everything it needs; users with a `cmd = {...}`
lazy spec pay no startup cost.

## 3. Data flow: add comment

```
  user
   │  :ManiculeAdd   (or <Plug>(manicule-add))
   ▼
plugin/manicule ──► init.add(opts)
                      │
                      ├─ resolve_range() ──────► {start, end_}
                      │
                      ├─ ui.prompt() ──────────► body (async cb)
                      │
                      ▼
                    finalize_add(body, bufnr, range)
                      │
                      ├─ anchor.create(bufnr, range) ──► mark_id
                      ├─ id.new() ─────────────────────► record.id
                      ├─ store.put(root, record)
                      ├─ store.save(root)  (atomic tmp+rename)
                      │
                      └─ nvim_exec_autocmds("User",
                           { pattern = "ManiculeAdded", data = record })
```

## 4. Data flow: reload

```
  BufReadPost / BufEnter
         │
         ▼
   init.attach_buffer(bufnr)
         │
         ├─ store.root()        (vim.fs.root(".git"|".hg"|"package.json"))
         ├─ store.load(root)    (fills module-local cache[root])
         ├─ relpath_for_buf()   (vim.fs.relpath, fallback prefix strip)
         │
         ├─ for each record matching relpath:
         │     anchor.create(bufnr, range) ──► mark_id
         │     anchor.resolve(bufnr, mark_id)
         │         └─ if invalid:
         │              nvim_exec_autocmds("User",
         │                { pattern = "ManiculeOrphaned",
         │                  data = { id, record } })
         │
         └─ buffer_marks[bufnr][record.id] = mark_id
```

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

The store lives at `<project-root>/.manicule.json`, where the root is
resolved with `vim.fs.root(0, {".git",".hg","package.json"})`. Writes go
through a tmp-then-rename dance — `vim.uv.fs_write` to
`<path>.tmp`, then `vim.uv.fs_rename` into place — so a mid-write crash
never truncates the existing store. JSON was chosen over SQLite because
the payload is small (one record per commented range, one file per
project), the format is trivial for users to inspect and hand-edit, and
Neovim ships `vim.json` without any external dependency.

## 7. Anchoring strategy

Each record owns exactly one extmark in the shared namespace
`manicule`, created with `invalidate = true` and `undo_restore = false`.
When the anchor line(s) are deleted, Neovim flags the extmark as
`invalid` for us for free — we do not maintain a parallel liveness
table. On buffer reload, records for the buffer's project-relative path
are re-anchored to their stored `range`; if the re-attached mark comes
back `invalid` immediately (e.g. the file has been truncated below the
stored row), a `User ManiculeOrphaned` autocmd is fired with the
record. Display (sign + highlight) is carried on the extmark directly
via `sign_text = "☞"` and `sign_hl_group = "ManiculeSign"`.

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
- A display-handler system beyond the extmark-carried sign. Virtual
  text, floats, and custom gutter glyphs are sketched in
  `handlers.lua` but intentionally unwired.
- Multi-line comment prompts. v1 uses single-line `vim.ui.input`; a
  scratch-buffer flow is a v2 item (TODO in `lua/manicule/ui.lua`).
- Matching saved records by line text. v1 re-anchors by saved
  row/col and lets `invalidate` flag orphans.
