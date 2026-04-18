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

## Configuration

All keys are optional — the snippet below is the full default set.

```lua
require("manicule").setup({
  store = {
    dir = vim.fn.stdpath("state") .. "/manicule/", -- per-user state dir
    format = "mpack",                              -- "mpack" | "json"
    branch = false,                                -- branch-scope the filename
    persist_unrooted = false,                      -- key unrooted bufs by cwd
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
`ManiculeResolved`, `ManiculeSent`, `ManiculeOrphaned`. Payload shapes
are documented in
[`ARCHITECTURE.md`](./ARCHITECTURE.md#event-catalog) and
`:help manicule-events`.

## See also

- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) — the
  diff UI this was extracted from.
