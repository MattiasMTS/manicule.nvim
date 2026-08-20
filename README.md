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
:ManiculeAdd           " add a comment on the current line or visual range
:ManiculeList          " open project comments in quickfix
:ManiculeEdit          " pick a comment to edit, or pass a list position
:ManiculeDelete        " pick a comment to delete, or pass a list position
:ManiculeResolve       " pick a comment to mark resolved
:ManiculeToggle        " hide or restore all comment visuals; during a review session, shows/hides the review panel
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

### Split and unified diffs

`review.mode` picks how a pair renders. `:ManiculeReviewDiffMode` flips
between the two mid-session and re-renders the file on screen.

`split` (default) is a side-by-side `:diffsplit` pair: read-only baseline
on the left, worktree file on the right.

`unified` shows one window — the worktree file — with the diff painted
onto it. Added lines are highlighted, removed lines appear as virtual
text where they used to sit, and unchanged regions fold away:

```
  4   local sum = 0
  5   for _, item in ipairs(items) do
    ▏    sum = sum + item.price          <- removed (virtual line, no number)
  6     sum = sum + (item.price * item.qty)   <- added (highlighted)
  7   end
 10   ⋯ 31 unchanged lines ⋯
```

Unified mode paints the *real* file rather than building a synthetic diff
buffer, so comments anchor to true worktree line numbers with no
translation layer — `:ManiculeSend github` posts them at the same lines it
would from split mode. The trade-off is that removed lines are virtual and
therefore not commentable, which matches split mode, where the baseline
side is read-only.

`]h` / `[h` jump between hunks (wrapping), and folds behave like any
other: `za` toggles, `zR` opens them all. Set `review.fold_unchanged =
false` to skip folding entirely, or `review.context` to change how much
code stays visible around each hunk.

A bottom panel opens automatically showing the file list
with live comment counts. Press `<Tab>` in the panel to toggle between
files view and comments view. `<CR>` on a commented file drills into a
comments view scoped to that file (`<CR>` jumps to a comment, `dd`
deletes, `ce` edits, `<Esc>` goes back to the file list); `<CR>` on a
file without comments switches the diff to that pair, and `o` always
opens the pair regardless of comment count. From a scoped comments view
`<Tab>` widens to all session comments. `:ManiculeToggle` shows/hides the
panel during a review (the session and panel view are preserved). Running
`:ManiculeReview pr` with no number opens a picker over the repository's
open PRs.

When you review a PR with its head checked out (`:ManiculeReview pr 123`
on the PR branch), existing GitHub review comments are imported as
manicule records and render inline during the review. Imported comments
are read-only-ish: they live in the normal project store, so you can edit
or delete them locally, but those changes never sync back to GitHub. They
are also excluded from `:ManiculeReviewFinish` and the `github` sink, so
GitHub's own comments are never echoed back as a new review; re-running
`:ManiculeReview pr N` never duplicates them. When the PR head is not
checked out (both sides staged from temp files), the import is skipped.

Imported comments support two GitHub interactions from the panel's
comments view: `r` replies to the comment's thread — it opens the normal
comment editor and stores the reply as a regular local record that the
next `github` send posts to the thread (instead of the review payload) —
and `gr` toggles the thread's resolved state on GitHub directly.
GitHub-resolved threads are prefixed with `✓` in the comments view.

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
- `github` posts the batch as a pull-request review via the `gh` CLI (options:
  `event`, `pre_text`, `clear_on_success`; PR taken from `ctx.pr` or the
  current branch). `:ManiculeSend github [comment|approve|request-changes]`
  picks the review verdict for that send, overriding the configured `event`.
  Records created with the review panel's `r` reply action are posted as
  thread replies instead of review comments.

`cmux.enabled` is boolean. When enabled, the integration registers only when a
cmux workspace and usable cmux executable are available. Agent discovery
supports Claude Code, Codex, Amp, and Pi through cmux metadata, titles, process
commands, and terminal contents.
`cmux.auto_submit` controls whether Manicule presses Enter after pasting the
review into the agent prompt. Set it to `false` if you want to inspect or edit
the prompt manually before submission. `cmux.submit_delay_ms` adds a delay
before that Enter key (default 120ms); values around 100-250ms can help large
pasted prompts settle before submission.
Large reviews are automatically split into chunks (`cmux.paste_chunk_bytes`,
default 1024) with a short delay between them (`cmux.paste_chunk_delay_ms`,
default 80ms) to avoid the receiving terminal dropping the middle of the
payload.
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
`ManiculeRestored`, `ManiculeResolved`, `ManiculeSent`, `ManiculeSynced`,
`ManiculeOrphaned`, `ManiculeRenamed`, and `ManiculeVisibility`.

## Notes

- Comments in git diff views are anchored to the working-tree side when the
  reference buffer can be identified.
- Quickfix, prompt, and command-line-window buffers reject new comments.
- Detailed edge cases and data flow are documented in
  [ARCHITECTURE.md](./ARCHITECTURE.md).
