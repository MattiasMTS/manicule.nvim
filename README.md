# manicule.nvim

Buffer-agnostic comments for Neovim, pipeable to anywhere.

> **Status:** early / pre-alpha — API will change.

## What it is

manicule.nvim lets you attach annotations to arbitrary ranges in any
buffer, anchored by extmarks so they survive edits and surface cleanly
when their anchor is destroyed. Comments are persisted per-project in a
local JSON store and dispatched to pluggable **sinks** — clipboard, PR
drafts, chat webhooks, whatever you plug in.

## Why the name

A *manicule* (☞) is the pointing-hand mark medieval readers drew in the
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
  opts = {},
}
```

## Usage

```vim
:ManiculeAdd          " add a comment on the current line (or :'<,'>ManiculeAdd)
:ManiculeList         " list comments for this project
:ManiculeSend clipboard
```

Or via `<Plug>` mappings (no defaults are installed):

```lua
vim.keymap.set({ "n", "x" }, "<leader>ca", "<Plug>(manicule-add)")
vim.keymap.set("n",          "<leader>cl", "<Plug>(manicule-list)")
```

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

## See also

- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) — the
  diff UI this was extracted from.
