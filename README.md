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
- Four comment display modes — end-of-line virtual text (default), floating
  popups, inline boxes, or hidden anchors — cycled live with
  `:ManiculeDisplay`.
- Diff-review sessions (`:ManiculeReview`) over uncommitted changes, a git
  ref, a GitHub PR, or two directories.
- Quickfix list for scanning, jumping, editing, and deleting comments.
- Project-scoped and session-scoped persistence.
- Pluggable sinks for sending comments elsewhere; clipboard, cmux, and
  GitHub sinks are built in.
- Native `User` autocmd events for lifecycle hooks.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the deeper implementation notes and
event payloads.

## Requirements

- Neovim >= 0.12.
- macOS or Linux (`git`, `tar`, and unix sockets at runtime); Windows is
  untested and unsupported.
- The default project store uses the local SQLite library through LuaJIT
  FFI; most Neovim builds can load `libsqlite3` already.

Run `:checkhealth manicule` after setup to verify the store directory, SQLite
support, clipboard support, and registered sinks.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MattiasMTS/manicule.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = {
    "ManiculeAdd",
    "ManiculeList",
    "ManiculeNext",
    "ManiculePrev",
    "ManiculeSend",
    "ManiculeReview",
    "ManiculeReviewNext",
    "ManiculeReviewPrev",
    "ManiculeReviewFinish",
    "ManiculeReviewStop",
  },
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
:ManiculeAdd            " add a comment on the current line or visual range
:ManiculeList           " open project comments in quickfix
:ManiculeEdit           " pick a comment to edit, or pass a list position
:ManiculeDelete         " pick a comment to delete, or pass a list position
:ManiculeResolve        " pick a comment to mark resolved
:ManiculeToggle         " hide or restore all comment visuals; during a review session, shows/hides the review panel
:ManiculeDisplay [mode] " set the comment display mode; bare command cycles
:ManiculeNext [count]   " jump to the next comment in the current buffer
:ManiculePrev [count]   " jump to the previous comment in the current buffer
:ManiculeSend [sink]    " send comments to a sink
```

`:ManiculeAdd` opens a small markdown buffer in insert mode. `<Esc>` then
`<CR>` submits, `q` in normal mode cancels, and moving focus out of the
floating editor discards the draft.

Default keymaps (set `vim.g.manicule_no_default_keymaps = 1` before loading
to opt out):

- `gca` / `gcd` edit / delete the comment at or covering the cursor.
- `]m` / `[m` jump to the next / previous comment in the current buffer.

Core actions are also exposed as `<Plug>` maps for your own bindings:
`(manicule-add)`, `(manicule-list)`, `(manicule-next)`, `(manicule-prev)`,
`(manicule-edit)`, `(manicule-delete)`, `(manicule-toggle)`,
`(manicule-display-cycle)`, `(manicule-review-next)`,
`(manicule-review-prev)`, and `(manicule-review-diff-mode)`.

### Display modes

- `eol` (default) — a collapsed end-of-line marker per comment showing the
  short id and first body line; the full popup expands while the cursor
  sits on the line.
- `float` — anchored floating popups with occlusion-aware placement, gated
  by the viewport (or always shown with `ui.sticky = true`).
- `inline` — a bordered virtual-line box below each commented line; code is
  pushed down, never covered.
- `hidden` — anchor extmarks and line-number tint only.

`:ManiculeDisplay <mode>` switches live; a bare `:ManiculeDisplay` cycles
`float → eol → inline → hidden`. The startup mode comes from `ui.display`;
runtime switches are in-memory and reset when Neovim restarts. Map
`<Plug>(manicule-display-cycle)` to cycle from a keymap.

The expanded comment card (shared by `eol` and `float`):

```
local sum = 0                      ┌ c4f2a1c 1/2 ───────────────────┐
for _, item in ipairs(items) do    │ handle the empty items case    │
end                                │ before summing                 │
                                   │ Aug 20 14:05 · edit gca | del… │
                                   └────────────────────────────────┘
```

A leading badge marks each comment's origin: `●` for local comments,
`[gh]` (or a Nerd Font glyph — see `ui.icons`) for comments imported from
a GitHub PR. `ui.expand = "rail"` renders `eol`'s expanded cards into a
real side window on the far right instead of popups, so cards can never
cover code (config-at-setup; no runtime command in v1). `gca`/`gcd` work
from the commented line in every mode.

## Quickfix

`:ManiculeList` opens a quickfix list titled `manicule (...)`.

- `<CR>` jumps to the anchored location.
- `dd` deletes the comment under the cursor.
- `ce` edits the comment under the cursor.
- `u` undoes the last comment deletion (multi-level; repeat to undo more).
- `<C-r>` redoes the last undone deletion (multi-level; a new deletion clears the redo branch).

The list refreshes in place when comments are added, edited, deleted,
restored, or resolved.

## Review mode

`:ManiculeReview` opens a diff-review session: baseline versions staged on
the left (read-only), your working tree on the right. Comment on the right
side as usual, then send the batch with `:ManiculeReviewFinish [sink]`.

    :ManiculeReview              " uncommitted changes (vs HEAD)
    :ManiculeReview main         " your branch vs merge-base with main
    :ManiculeReview pr 123       " a GitHub PR (requires gh CLI)
    :ManiculeReview <dirA> <dirB> " any two directories
    :ManiculeReviewNext          " next changed file
    :ManiculeReviewPrev          " previous changed file
    :ManiculeReviewFinish [sink] " send comments to a sink (optional arg)
    :ManiculeReviewStop          " close the session
    :ManiculeReviewDiffMode      " toggle split <-> unified (or name one)

`review.mode` picks how a pair renders; `:ManiculeReviewDiffMode` flips it
mid-session. `split` (default) is a side-by-side `:diffsplit` pair.
`unified` shows one window — the worktree file — with the diff painted on:
added lines highlighted, removed lines drawn as virtual text where they
used to sit, and unchanged regions folded away (tune with
`review.fold_unchanged` and `review.context`; `za`/`zR` behave as usual).
Comments anchor to true worktree line numbers in both modes, so
`:ManiculeSend github` posts them at the same lines either way; removed
lines and the read-only baseline side are not commentable. `]h` / `[h`
jump between hunks (wrapping).

A bottom panel opens automatically: a plain `manicule://panel` buffer
(filetype `manicule-panel`) in a fixed-height split, so the global
quickfix list stays free during the review. Each line shows one file with
its status and a live comment count (colored filetype icons when an icon
provider is installed — see `ui.icons`), and the pair on screen is marked
with `▸`, a highlighted line, and a bold filename.

Panel keymaps (buffer-local): `<CR>` on a commented file drills into a
comments view scoped to that file (`<CR>` jumps to a comment, `dd`
deletes, `ce` edits, `u`/`<C-r>` undo/redo a deletion, `<Esc>` goes
back); `<CR>` on a file without comments switches the diff to that pair,
and `o` always opens the pair. `<Tab>` toggles between files view and
comments view (from a scoped view it widens to all session comments).
`:ManiculeToggle` shows/hides the panel during a review. Running
`:ManiculeReview pr` with no number opens a picker over the repository's
open PRs.

When you review a PR with its head checked out, existing GitHub review
comments are imported as manicule records and render inline. They can be
edited or deleted locally (changes never sync back to GitHub) and are
excluded from `:ManiculeReviewFinish` and the `github` sink, so GitHub's
own comments are never echoed back as a new review; re-running
`:ManiculeReview pr N` never duplicates them. In the panel's comments
view, `r` replies to an imported comment's thread (the reply is stored
locally and posted by the next `github` send) and `gr` toggles the
thread's resolved state on GitHub; resolved threads are prefixed with `✓`.

External tools can drive a review session by writing a JSON job file and
calling `require("manicule.review").start_from_job(path)`; comments return
through the bundled `socket` sink as JSONL over a unix socket.

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
      submit_delay_ms = 120, -- delay before Enter, lets a large paste settle first
      paste_chunk_bytes = 1024, -- max bytes per paste chunk (large reviews are split to avoid PTY truncation)
      paste_chunk_delay_ms = 80, -- delay between paste chunks so the agent's terminal can drain
      clear_on_success = false, -- keep comments until you verify and resolve them
      pre_text = "Optional instructions inserted before the comments.",
      post_text = "Optional follow-up instructions inserted after the comments.",
    },
  },
  review = {
    mode = "split", -- "split" (side-by-side) or "unified" (inline)
    fold_unchanged = true, -- unified: collapse everything outside a hunk
    context = 3, -- unified: lines kept visible around each hunk
  },
  ui = {
    width = 72,
    height = 6,
    editor_mode = "insert",
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0.0, -- float transparency: 0.0 opaque, 1.0 fully transparent
    sticky = false,
    display = "eol", -- startup display mode: "float", "eol", "inline", "hidden"
    expand = "float", -- eol expansion surface: "float" popups or the side "rail"
    icons = "auto", -- Nerd Font badges + filetype icons: "auto", true, false
  },
})
```

`ui.icons` controls icon rendering: `"auto"` (default) turns icons on only
when [mini.icons](https://github.com/echasnovski/mini.icons) or
[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) is
installed (both are optional; neither is a dependency), `true` forces the
Nerd Font badges on without a provider, and `false` keeps everything plain
text (`[gh]`, `●`, `✓`).

## Storage

Project comments are stored in one SQLite database per project root (WAL
mode, a current `records` projection plus an append-only `events` log), so
separate Neovim sessions in the same project observe each other's changes.
Session comments for unrooted or special buffers share a `session.<format>`
file. Stores live under `store.dir`; by default that is:

```vim
:echo stdpath("state") . "/manicule/"
```

## Sinks

Sinks receive comment batches from `:ManiculeSend`.

Built-ins:

- `clipboard` copies formatted comments to the `+` register.
- `cmux` sends a markdown review batch to a cmux coding-agent surface
  (Claude Code, Codex, Amp, and Pi are discovered through cmux metadata)
  and keeps comments in Manicule by default so you can verify fixes before
  resolving them. Pasting and submission behavior is tuned with the `cmux`
  options shown in the configuration example above.
- `github` posts the batch as a pull-request review via the `gh` CLI
  (options: `event`, `pre_text`, `clear_on_success`; PR taken from `ctx.pr`
  or the current branch). `:ManiculeSend github
  [comment|approve|request-changes]` picks the review verdict for that
  send, overriding the configured `event`. Records created with the review
  panel's `r` reply action are posted as thread replies instead of review
  comments.

The bundled text sinks (`clipboard`, `cmux`) also accept `pre_text` and
`post_text` strings inserted before and after the formatted comments.

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
`ManiculeRestored`, `ManiculeResolved`, `ManiculeSent`, `ManiculeSynced`,
`ManiculeOrphaned`, `ManiculeRenamed`, and `ManiculeVisibility`.

## Notes

- Comments in git diff views are anchored to the working-tree side when the
  reference buffer can be identified.
- Quickfix, prompt, and command-line-window buffers reject new comments.
- Detailed edge cases and data flow are documented in
  [ARCHITECTURE.md](./ARCHITECTURE.md).
