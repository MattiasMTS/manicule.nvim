# Review-mode performance

Measured with `scripts/bench-review` on macOS using Neovim 0.13.0-nightly and Git 2.55.0. The harness creates 2,000 changed files (667 modified, 666 added, 667 deleted) and 500 comments.

| Benchmark | Before | After | Speedup |
|---|---:|---:|---:|
| `sources.resolve({ "main" })` | 16,994.403 ms | 1,515.335 ms | 11.2x |
| `stage_baseline` | 17,672.247 ms | 1,110.764 ms | 15.9x |
| panel `build_files_items` | 79,774.292 ms | 41.888 ms | 1,904.4x |

The baseline now stages tracked files through chunked `git archive` and `tar` subprocesses instead of one `git show` process per file. Panel comment counts come from one filtered list call and a URI count map.

Review baseline staging requires the `tar` executable at runtime.
