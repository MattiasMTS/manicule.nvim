# manicule.nvim

Buffer-agnostic comments for Neovim, pipeable to anywhere.

> **Status:** Alpha — single-user, extmark-anchored, persisted under
> `stdpath('state')/manicule/` as mpack (opt-in JSON). API will change.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for a walkthrough of the
module layout, data flow, and event catalog.

## What it is

manicule.nvim lets you attach annotations to arbitrary ranges in any
buffer, anchored by extmarks so they survive edits and surface cleanly
when their anchor is destroyed. Comments are persisted per-project
under Neovim's state directory (`stdpath('state')/manicule/`) and
dispatched to pluggable **sinks** — clipboard, PR drafts, chat webhooks,
whatever you plug in.

## How it looks

Each comment tints its anchor line's number column via `ManiculeLineNr`
(default-linked to `DiagnosticSignInfo`, overridable) and is shown as a
small floating popup pinned to the anchor line, titled with the short
id (`c<6 chars>`) and footered with the edit/delete hint. Popup footers
show the last-touched timestamp (`updated_at` or `created_at`) followed
by the keymap hint. Multiple comments on the same line stack above one
another. By default popups only appear when the anchor line is in the
current viewport; set `ui.sticky = true` to keep every popup visible at
all times.

## Why the name

A *manicule* is the pointing-hand mark medieval readers drew in the
margins to flag a passage worth returning to.

## Motivation

Extracted from [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
(specifically PR [#332](https://github.com/esmuellert/codediff.nvim/pull/332)),
and inspired by [Conductor](https://www.conductor.build/) which ships
native cross-buffer commenting.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MattiasMTS/manicule.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = { "ManiculeAdd", "ManiculeList", "ManiculeSend" },
  keys = {
    { "<leader>ma", "<Plug>(manicule-add)", mode = { "n", "x" }, desc = "Manicule: add comment" },
    { "<leader>ml", "<Plug>(manicule-list)", desc = "Manicule: list comments" },
  },
  opts = {},
}
```

The `event` trigger matters: manicule attaches to buffers via autocmds
registered in `setup`. A `cmd`/`keys`-only lazy load means existing
buffers opened at startup won't render their saved comments until you
invoke a `:Manicule*` command or keymap for the first time, so include
`BufReadPost`/`BufNewFile` to trigger the initial attach sweep.

## Usage

```vim
:ManiculeAdd           " add a comment on the current line (or :'<,'>ManiculeAdd)
:ManiculeList          " list comments for this project (quickfix)
:ManiculeEdit          " picker → edit (or :ManiculeEdit 3 to jump straight to position 3)
:ManiculeDelete        " picker → delete (or :ManiculeDelete 3)
:ManiculeResolve       " picker → resolve (or :ManiculeResolve 3)
:ManiculeToggle        " hide/restore all visuals without touching the store
:ManiculeSend clipboard
```

`:ManiculeAdd` opens a floating markdown scratch buffer. Type your
comment (it can span multiple lines), then press `<CR>` in normal mode
to submit or `q` to cancel — both keys are configurable (see below).

### Picker commands

`:ManiculeEdit`, `:ManiculeDelete`, and `:ManiculeResolve` accept a
single positional number matching the same 1-indexed order as
`:ManiculeList`. Tab-completion returns the valid positions as raw
numbers (`1`, `2`, …, `N`) — command-line completion can't render
descriptive text. With no argument the command opens a `vim.ui.select`
picker showing every record in the same order, formatted so both the
location and the body stay legible at a glance:

```
 1 │ src/foo.lua:42        │ fix this validation to handle nil
 2 │ README.md:10-12       │ rephrase this paragraph so it reads…
 3 │ src/bar.lua:7         │ [✓] already addressed in review
```

The cursor-based `gca` / `gcd` keymaps are unchanged — they remain the
fast at-cursor path. Picker commands are the "pick from a list" path.

### Quickfix

`:ManiculeList` pushes every comment for the current project into the
quickfix list (title prefixed with `manicule`). While the cursor sits
on an entry:

| Key    | Action                                            |
| ------ | ------------------------------------------------- |
| `<CR>` | Jump to the anchored location (native qf behaviour) |
| `dd`   | Delete the comment under the cursor               |
| `ce`   | Edit the comment under the cursor                 |

The list auto-refreshes in place while it stays open: adding, editing,
deleting, or resolving a comment from any surface (keymap, command,
API, floating editor) updates the qf list without closing it, and the
cursor stays on the same row. The title-prefix check makes sure grep
results, diagnostic lists, and other plugins' quickfix lists are never
overwritten.

The `dd`/`ce` bindings are buffer-local to manicule quickfix buffers
only — native `dd`/`ce` behaviour elsewhere is unaffected. Opt out
with the same `vim.g.manicule_no_default_keymaps = 1` flag used for
`gca`/`gcd`.

### Keymaps

Default normal-mode keymaps (matching the popup footer hint):

| Key   | Action                                 |
| ----- | -------------------------------------- |
| `gca` | Edit the comment at/covering the cursor   |
| `gcd` | Delete the comment at/covering the cursor |

Opt out by setting `vim.g.manicule_no_default_keymaps = 1` before the
plugin loads.

All keymaps are available as `<Plug>` mappings — no `<leader>`
bindings are installed for add/list so you can pick your own:

```lua
vim.keymap.set({ "n", "x" }, "<leader>ca", "<Plug>(manicule-add)")
vim.keymap.set("n",          "<leader>cl", "<Plug>(manicule-list)")
vim.keymap.set("n",          "<leader>ce", "<Plug>(manicule-edit)")
vim.keymap.set("n",          "<leader>cd", "<Plug>(manicule-delete)")
```

### Scopes

manicule owns two persistence scopes:

- **Project scope** (`scope = "project"`): records live in a per-root
  file named after the project root. Used whenever a buffer resolves
  to a project (via `vim.fs.root` on `store.root_markers`). Project
  records carry a `project_root` field.
- **Session scope** (`scope = "session"`): records live in a single
  `session.<format>` file under `stdpath('state')/manicule/`, keyed
  purely by URI. Used for unrooted file buffers, `:terminal`, help
  buffers, scratch / nofile / acwrite buffers — anything without a
  project root or without a plain-file backing. `project_root` is nil.

The caller never branches on scope — `:ManiculeAdd`, `:ManiculeList`,
and the render layer all dispatch through the store automatically.
Comments you add on an unrooted file follow you into the session
store; comments on a terminal buffer persist across nvim restarts as
long as the `term://` URI is stable. `persist_unrooted` defaults to
**true** so "works anywhere" is the honest default; set it to
`false` to refuse adds on unrooted file buffers with a notify.

If you `:saveas` a scratch-session comment into a project directory,
the record's scope stays `session` with the new file URI. Delete and
re-add it if you want project-scope ownership.

Quickfix, prompt, and cmdwin buffers reject adds unconditionally with
a notify — there's no sensible per-line anchoring in those buftypes.

### Troubleshooting

#### My comments aren't persisting from a diff tool / staged buffer

Some plugins (custom `:DiffTool` commands, stash-blob viewers, a few
review integrations) stage buffer contents under Neovim's per-session
runtime dir (`:echo stdpath('run')`). That directory's `<run-id>`
rotates every launch, so a URI pointing at it can never re-anchor on
reload. manicule detects the staged-path shape and tries to
*reverse-map* it to the real file under your project root, cwd, or
`$HOME` (for dotfile suffixes).

If the mapping fails you'll see one of:

- `manicule: buffer is a nvim-runtime-staged path (<abs>); could not
  map to a real file` — no candidate existed anywhere we looked.
- `manicule: ambiguous reverse-map; open the real file directly` — the
  same path suffix resolves to multiple files (e.g. under both the
  project root and `$HOME`).

Open the real file directly and retry.

Comments added from `:DiffToolGit` anchor to the real file's line
numbers from the view — for plain one-way diffs this approximates the
working tree, but lines may drift if the staged view differs
significantly from the working tree (three-way / unusual diff setups).

### Diff mode

manicule works inside `nvim -d` and `git difftool -t nvimdiff` views.
When two diff-mode windows live in the same tab, the reference side is
detected by its path: a buffer under `/tmp/`, `/var/folders/…/T/`, or
the `/private/...` aliases (the typical location for git's temporary
blob extractions) is treated as the *reference* view of the other
buffer, which is assumed to be the working-tree file. Plain `nvim -d
a.lua b.lua` with two real paths and no temp file leaves the
heuristic ambiguous — each side is treated as its own identity and
each allows adds against its own URI.

Comments always anchor to the working-tree URI. Attempting
`:ManiculeAdd` from the reference side produces a WARN notify directing
you to the working-tree buffer; edit/delete still work on either side
because they route by record id rather than identity. The reference
buffer shows no visuals by default (the working-tree file owns the
popups); switch to the working-tree window to interact with comments.

## Configuration

All keys are optional — the snippet below is the full default set.

```lua
require("manicule").setup({
  store = {
    dir = vim.fn.stdpath("state") .. "/manicule/", -- per-user state dir
    format = "mpack",                              -- "mpack" | "json"
    branch = false,                                -- branch-scope the filename
    persist_unrooted = true,                       -- route unrooted adds to the session store
    canonicalize_symlinks = true,                  -- resolve symlinks before encoding URIs
    root_markers = { ".git", ".hg", "package.json" },
  },
  ui = {
    width = 72,            -- floating editor width (columns)
    height = 6,            -- floating editor height (lines)
    editor_mode = "insert",-- "insert" or "normal"
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0,           -- winblend (0 = opaque, 100 = transparent)
    sticky = false,        -- true = always show popups; false = viewport only
  },
})
```

### Where are my notes stored?

Run `:echo stdpath('state').'/manicule/'` — that is the default
`store.dir`. One file per project root, named after the root with path
separators escaped as `%%`, e.g. `%Users%me%src%foo.mpack`. Switch to
`store.format = "json"` if you want the files to be human-readable.

With `store.branch = true` the filename is scoped per-branch
(`<root>%%<branch>.<ext>`), except for `main`/`master` which collapse to
the unsuffixed filename so the common case doesn't fragment.

## Registering a custom sink

```lua
require("manicule").register_sink({
  name = "gist",
  clear_on_success = false,  -- set true to auto-delete records after cb(true)
  validate = function(ctx)
    if not ctx.token then return false, "missing GitHub token" end
    return true
  end,
  format = function(c)
    return ("- `%s:%d` %s"):format(c.path, c.range.start[1] + 1, c.body)
  end,
  send = function(comments, ctx, cb)
    -- POST to https://api.github.com/gists …
    cb(true)
  end,
})
```

Then: `:ManiculeSend gist`.

Set `clear_on_success = true` when the sink semantically *consumes* the
records (e.g. handing a review off to an external reviewer) — the core
will call `M.delete` on every record in the batch once the sink's
callback reports `ok = true`, firing one `ManiculeDeleted` per record.
Default is `false`, i.e. records persist after dispatch.

## Events

Lifecycle events are fired as native `User` autocmds — there is no
`on()` helper. Subscribe directly:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ManiculeAdded",
  callback = function(ev)
    vim.print(ev.data) -- the newly-created record
  end,
})
```

Patterns: `ManiculeAdded`, `ManiculeEdited`, `ManiculeDeleted`,
`ManiculeResolved`, `ManiculeSent`, `ManiculeOrphaned`,
`ManiculeRenamed`, `ManiculeVisibility`. Payload shapes are documented in
[`ARCHITECTURE.md`](./ARCHITECTURE.md#event-catalog) and
`:help manicule-events`.

## See also

- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) — the
  diff UI this was extracted from.
