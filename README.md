# manicule.nvim

Persistent review comments for Neovim.

manicule.nvim lets you attach notes to lines or ranges in any buffer, keep
them anchored with extmarks as text moves, review them in quickfix, and send
them to a sink such as the clipboard or a running coding-agent surface.

It is meant for local code review and follow-up work: leave comments while
reading code, collect them across files, then resolve them or hand them off as
a review batch.

> Status: alpha.

## Features

- Anchored comments on normal files, unrooted files, scratch buffers,
  terminals, and help buffers.
- Floating popups on commented lines, with optional sticky display.
- Quickfix list for scanning, jumping, editing, and deleting comments.
- Project-scoped and session-scoped persistence.
- Pluggable sinks for sending comments elsewhere.
- Built-in clipboard sink and cmux integration.
- Native `User` autocmd events for lifecycle hooks.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the deeper implementation notes and
event payloads.

## Requirements

Neovim >= 0.10.

The default project store uses the local SQLite library through LuaJIT FFI.
Most Neovim builds on macOS and Linux can load `libsqlite3` already; run
`:checkhealth manicule` to confirm.

Run `:checkhealth manicule` after setup to verify the store directory, SQLite
support, Neovim API support, clipboard support, and registered sinks.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MattiasMTS/manicule.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = { "ManiculeAdd", "ManiculeList", "ManiculeNext", "ManiculePrev", "ManiculeSend" },
  keys = {
    { "<leader>ma", "<Plug>(manicule-add)", mode = { "n", "x" }, desc = "Manicule: add comment" },
    { "<leader>ml", "<Plug>(manicule-list)", desc = "Manicule: list comments" },
  },
  opts = {},
}
```

Use an event trigger because setup registers the autocmds that attach existing
records to loaded buffers.

## Usage

```vim
:ManiculeAdd           " add a comment on the current line or visual range
:ManiculeList          " open project comments in quickfix
:ManiculeEdit          " pick a comment to edit, or pass a list position
:ManiculeDelete        " pick a comment to delete, or pass a list position
:ManiculeResolve       " pick a comment to mark resolved
:ManiculeToggle        " hide or restore all comment visuals
:ManiculeNext [count]  " jump to the next comment in the current buffer
:ManiculePrev [count]  " jump to the previous comment in the current buffer
:ManiculeSend [sink]   " send comments to a sink
```

`:ManiculeAdd` opens a small markdown buffer in insert mode. Press `<CR>` to
insert a newline, `<Esc>` then `<CR>` to submit, or `q` in normal mode to
cancel. Moving focus out of the floating editor, including clicking back into
the main buffer, also cancels and discards the draft.

Default keymaps:

- `gca` edits the comment at or covering the cursor.
- `gcd` deletes the comment at or covering the cursor.
- `]m` jumps to the next comment in the current buffer.
- `[m` jumps to the previous comment in the current buffer.

Set `vim.g.manicule_no_default_keymaps = 1` before loading the plugin to opt
out. Core actions are exposed as `<Plug>` maps so you can choose your own
leader bindings:

```lua
vim.keymap.set({ "n", "x" }, "<leader>ca", "<Plug>(manicule-add)")
vim.keymap.set("n", "<leader>cl", "<Plug>(manicule-list)")
vim.keymap.set("n", "]c", "<Plug>(manicule-next)")
vim.keymap.set("n", "[c", "<Plug>(manicule-prev)")
```

## Quickfix

`:ManiculeList` opens a quickfix list titled `manicule (...)`.

- `<CR>` jumps to the anchored location.
- `dd` deletes the comment under the cursor.
- `ce` edits the comment under the cursor.

The list refreshes in place when comments are added, edited, deleted, or
resolved.

## Configuration

All keys are optional.

```lua
require("manicule").setup({
  store = {
    dir = vim.fn.stdpath("state") .. "/manicule/",
    format = "mpack", -- session store: "mpack" or "json"
    branch = false,
    persist_unrooted = true,
    canonicalize_symlinks = true,
    root_markers = { ".git", ".hg", "package.json" },
    poll_interval_ms = 750,
  },
  sinks = {
    clipboard = true,
    cmux = {
      enabled = true,
      auto_submit = true, -- set false to paste and wait for manual Enter
      submit_delay_ms = 0, -- increase if large pasted prompts need a beat before Enter
      clear_on_success = false, -- keep comments until you verify and resolve them
      pre_text = "Optional instructions inserted before the comments.",
      post_text = "Optional follow-up instructions inserted after the comments.",
    },
  },
  ui = {
    width = 72,
    height = 6,
    editor_mode = "insert",
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0.0, -- float transparency: 0.0 opaque, 1.0 fully transparent
    sticky = false,
  },
})
```

`ui.opacity` is fractional float transparency: `0` is opaque, `0.5` is
half transparent, `0.99` is 99% transparent, and `1` is fully transparent.

## Storage

Project comments are stored in one SQLite database per project root. The
database uses WAL mode and keeps both a current `records` projection and an
append-only `events` log, so separate Neovim sessions in the same project can
observe each other's changes without rewriting one whole store file.

Session comments share a `session.<format>` file for unrooted or special
buffers. Stores live under `store.dir`; by default that is:

```vim
:echo stdpath("state") . "/manicule/"
```

The session file schema is:

```lua
{ version = 1, records = { ... } }
```


## Sinks

Sinks receive comment batches from `:ManiculeSend`.

Built-ins:

- `clipboard` copies formatted comments to the `+` register.
- `cmux` sends a markdown review batch to a cmux coding-agent surface and keeps
  comments in Manicule by default so you can verify fixes before resolving them.

`cmux.enabled` is boolean. When enabled, the integration registers only when a
cmux workspace and usable cmux executable are available.
`cmux.auto_submit` controls whether Manicule presses Enter after pasting the
review into the agent prompt. Set it to `false` if you want to inspect or edit
the prompt manually before submission. `cmux.submit_delay_ms` adds a delay
before that Enter key; values around 100-250ms can help large pasted prompts
settle before submission.
Set `cmux.clear_on_success = true` if you want a successful cmux handoff to
delete the sent comments immediately.
The bundled text sinks, currently `clipboard` and `cmux`, also accept
`pre_text` and `post_text` strings. These are inserted before and after the
formatted comments while Manicule still owns comment IDs and file/range
formatting.

Register a custom sink:

```lua
require("manicule").register_sink({
  name = "mytool",
  label = "My Tool",
  pre_text = "Optional text before formatted comments.",
  post_text = "Optional text after formatted comments.",
  clear_on_success = false,
  validate = function(ctx)
    if not ctx.token then
      return false, "missing token"
    end
    return true
  end,
  send = function(comments, ctx, cb)
    -- send comments somewhere
    cb(true)
  end,
})
```

Set `clear_on_success = true` only for sinks that consume the review, because
successful dispatch deletes the sent comments.

## Events

manicule emits native `User` autocmds:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ManiculeAdded",
  callback = function(ev)
    vim.print(ev.data)
  end,
})
```

Events: `ManiculeAdded`, `ManiculeEdited`, `ManiculeDeleted`,
`ManiculeResolved`, `ManiculeSent`, `ManiculeSynced`, `ManiculeOrphaned`,
`ManiculeRenamed`, and `ManiculeVisibility`.

## Notes

- Comments in git diff views are anchored to the working-tree side when the
  reference buffer can be identified.
- Quickfix, prompt, and command-line-window buffers reject new comments.
- Detailed edge cases and data flow are documented in
  [ARCHITECTURE.md](./ARCHITECTURE.md).
